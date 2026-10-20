//! Audio I/O for the loopback and the call: the mic (or a test tone) as a
//! source of 20 ms, 48 kHz mono frames, and the speaker (or a WAV file, or
//! nothing) as a sink for them. Device rate, channel layout, and resampling
//! stay in here.
//!
//! Threads: the cpal callbacks only copy samples into or out of lock-free
//! rings and bump atomic counters (no allocation, locks, or I/O). `Capture`
//! and `Playback` are used from one worker thread, which does the rest.
//! The cpal `Stream`s are returned separately: they must stay alive (and on
//! the thread that opened them) for as long as the devices should run.

use std::fs::File;
use std::io::BufWriter;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait};
use cpal::{SampleFormat, Stream, StreamConfig, SupportedStreamConfig, SupportedStreamConfigRange};
use ringbuf::traits::{Consumer, Observer, Producer, Split};
use ringbuf::{HeapCons, HeapProd, HeapRb};

use crate::Error;
use crate::codec::{FRAME, SAMPLE_RATE, Sine};
use crate::protocol::Event;
use crate::resample::{self, FrameResampler};

/// Where audio code reports failures (and the loopback its stats). Called
/// from worker threads and cpal's error callbacks, never from the real-time
/// data callbacks.
pub type Notify = Arc<dyn Fn(Event) + Send + Sync>;

/// Playback may queue at most this much (two frames); beyond it, frames are
/// dropped. That sheds the startup burst and any clock drift between the
/// mic and speaker, so latency can't creep up.
const MAX_PLAYBACK_QUEUE: Duration = Duration::from_millis(40);

const FRAME_TIME: Duration = Duration::from_millis(20);

pub enum Input {
    Device,
    Sine,
}

pub enum Output {
    Device,
    Null,
    Wav(PathBuf),
}

impl FromStr for Input {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "device" => Ok(Input::Device),
            "sine" => Ok(Input::Sine),
            other => Err(format!("unknown input {other:?} (device|sine)")),
        }
    }
}

impl FromStr for Output {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "device" => Ok(Output::Device),
            "null" => Ok(Output::Null),
            other => match other.strip_prefix("wav:") {
                Some(path) if !path.is_empty() => Ok(Output::Wav(PathBuf::from(path))),
                _ => Err(format!("unknown output {other:?} (device|null|wav:PATH)")),
            },
        }
    }
}

/// Counters the real-time callbacks update, read by the stats reports.
#[derive(Default)]
pub struct DeviceStats {
    pub capture_overruns: AtomicU64,
    pub playback_underruns: AtomicU64,
    pub capture_device_us: AtomicU64,
    pub playback_device_us: AtomicU64,
}

impl DeviceStats {
    pub fn capture_device_ms(&self) -> f64 {
        self.capture_device_us.load(Relaxed) as f64 / 1000.0
    }

    pub fn playback_device_ms(&self) -> f64 {
        self.playback_device_us.load(Relaxed) as f64 / 1000.0
    }
}

/// A device side: its ring, layout, and the resampler between its rate and
/// Opus's 48 kHz (a copy when it already runs at 48 kHz).
pub struct DeviceEnd<R> {
    ring: R,
    channels: usize,
    rate: u32,
    resampler: FrameResampler,
    /// One 20 ms mono frame at the device rate.
    mono: Vec<f32>,
    /// One 20 ms interleaved frame at the device rate.
    interleaved: Vec<f32>,
}

impl<R: Observer> DeviceEnd<R> {
    fn new(
        ring: R,
        channels: usize,
        rate: u32,
        resampler: FrameResampler,
        mono_len: usize,
    ) -> Box<Self> {
        Box::new(Self {
            ring,
            channels,
            rate,
            resampler,
            mono: vec![0.0; mono_len],
            interleaved: vec![0.0; mono_len * channels],
        })
    }

    fn queued_ms(&self) -> f64 {
        (self.ring.occupied_len() / self.channels) as f64 * 1000.0 / f64::from(self.rate)
    }
}

/// Where 20 ms, 48 kHz mono frames come from.
pub enum Capture {
    Device(Box<DeviceEnd<HeapCons<f32>>>),
    /// Paced by the clock, since nothing else paces a synthetic source.
    Sine {
        sine: Sine,
        next_frame: Instant,
    },
}

impl Capture {
    /// Opens the source. The returned stream (if any) must be kept alive.
    pub fn open(
        input: Input,
        stats: &Arc<DeviceStats>,
        notify: &Notify,
    ) -> Result<(Self, Option<Stream>, String), Error> {
        match input {
            Input::Sine => Ok((
                Capture::Sine {
                    sine: Sine::new(440.0),
                    next_frame: Instant::now(),
                },
                None,
                "sine 440 Hz".to_owned(),
            )),
            Input::Device => {
                let (stream, ring, channels, rate, name) = open_capture(stats, notify)?;
                let resampler = FrameResampler::new(rate, SAMPLE_RATE)?;
                let len = resampler.input_len();
                let end = DeviceEnd::new(ring, channels, rate, resampler, len);
                Ok((Capture::Device(end), Some(stream), name))
            }
        }
    }

    /// Fills `frame` with the next 20 ms if it's ready. Never blocks.
    pub fn read(&mut self, frame: &mut [f32; FRAME]) -> Result<bool, Error> {
        match self {
            Capture::Device(end) => {
                if end.ring.occupied_len() < end.interleaved.len() {
                    return Ok(false);
                }
                end.ring.pop_slice(&mut end.interleaved);
                downmix(&end.interleaved, end.channels, &mut end.mono);
                end.resampler.process(&end.mono, frame)?;
                Ok(true)
            }
            Capture::Sine { sine, next_frame } => {
                if Instant::now() < *next_frame {
                    return Ok(false);
                }
                *next_frame += FRAME_TIME;
                sine.fill(frame);
                Ok(true)
            }
        }
    }

    /// Captured audio waiting to be read.
    pub fn queued_ms(&self) -> f64 {
        match self {
            Capture::Device(end) => end.queued_ms(),
            Capture::Sine { .. } => 0.0,
        }
    }

    pub fn resample_ms(&self) -> f64 {
        match self {
            Capture::Device(end) => end.resampler.delay_ms(),
            Capture::Sine { .. } => 0.0,
        }
    }
}

/// Where 20 ms, 48 kHz mono frames go.
pub enum Playback {
    Device(Box<DeviceEnd<HeapProd<f32>>>),
    Null,
    Wav(hound::WavWriter<BufWriter<File>>),
}

impl Playback {
    /// Opens the sink. The returned stream (if any) must be kept alive.
    pub fn open(
        output: Output,
        stats: &Arc<DeviceStats>,
        notify: &Notify,
    ) -> Result<(Self, Option<Stream>, String), Error> {
        match output {
            Output::Null => Ok((Playback::Null, None, "null".to_owned())),
            Output::Wav(path) => {
                let name = format!("wav:{}", path.display());
                let spec = hound::WavSpec {
                    channels: 1,
                    sample_rate: SAMPLE_RATE,
                    bits_per_sample: 32,
                    sample_format: hound::SampleFormat::Float,
                };
                Ok((
                    Playback::Wav(hound::WavWriter::create(path, spec)?),
                    None,
                    name,
                ))
            }
            Output::Device => {
                let (stream, ring, channels, rate, name) = open_playback(stats, notify)?;
                let resampler = FrameResampler::new(SAMPLE_RATE, rate)?;
                let len = resampler.output_len();
                let end = DeviceEnd::new(ring, channels, rate, resampler, len);
                Ok((Playback::Device(end), Some(stream), name))
            }
        }
    }

    /// Queues one frame. Returns `false` if it was dropped because playback
    /// is already `MAX_PLAYBACK_QUEUE` behind.
    pub fn write(&mut self, frame: &[f32; FRAME]) -> Result<bool, Error> {
        match self {
            Playback::Device(end) => {
                let limit = samples_in(MAX_PLAYBACK_QUEUE, end.rate) * end.channels;
                if end.ring.occupied_len() > limit {
                    return Ok(false);
                }
                end.resampler.process(frame, &mut end.mono)?;
                upmix(&end.mono, end.channels, &mut end.interleaved);
                end.ring.push_slice(&end.interleaved);
                Ok(true)
            }
            Playback::Null => Ok(true),
            Playback::Wav(writer) => {
                for sample in frame {
                    writer.write_sample(*sample)?;
                }
                Ok(true)
            }
        }
    }

    /// Flushes what needs flushing (the WAV header).
    pub fn finish(self) -> Result<(), Error> {
        if let Playback::Wav(writer) = self {
            writer.finalize()?;
        }
        Ok(())
    }

    /// Audio queued for the speaker.
    pub fn queued_ms(&self) -> f64 {
        match self {
            Playback::Device(end) => end.queued_ms(),
            Playback::Null | Playback::Wav(_) => 0.0,
        }
    }

    pub fn resample_ms(&self) -> f64 {
        match self {
            Playback::Device(end) => end.resampler.delay_ms(),
            Playback::Null | Playback::Wav(_) => 0.0,
        }
    }
}

fn open_capture(
    stats: &Arc<DeviceStats>,
    notify: &Notify,
) -> Result<(Stream, HeapCons<f32>, usize, u32, String), Error> {
    let device = cpal::default_host()
        .default_input_device()
        .ok_or("no default input device")?;
    let config = pick_config(device.supported_input_configs()?, "input")?;
    let (config, name) = describe(&device, &config);
    let channels = usize::from(config.channels);
    let rate = config.sample_rate;

    let (mut ring, consumer) = HeapRb::<f32>::new(rate as usize * channels).split();
    let stats = Arc::clone(stats);

    let stream = device.build_input_stream::<f32, _, _>(
        config,
        move |data, info| {
            if ring.push_slice(data) < data.len() {
                stats.capture_overruns.fetch_add(1, Relaxed);
            }
            let at = info.timestamp();
            stats
                .capture_device_us
                .store(micros(at.callback.duration_since(at.capture)), Relaxed);
        },
        stream_error(notify),
        None,
    )?;

    Ok((stream, consumer, channels, rate, name))
}

fn open_playback(
    stats: &Arc<DeviceStats>,
    notify: &Notify,
) -> Result<(Stream, HeapProd<f32>, usize, u32, String), Error> {
    let device = cpal::default_host()
        .default_output_device()
        .ok_or("no default output device")?;
    let config = pick_config(device.supported_output_configs()?, "output")?;
    let (config, name) = describe(&device, &config);
    let channels = usize::from(config.channels);
    let rate = config.sample_rate;

    let (producer, mut ring) = HeapRb::<f32>::new(rate as usize * channels).split();
    let stats = Arc::clone(stats);

    let stream = device.build_output_stream::<f32, _, _>(
        config,
        move |data, info| {
            let filled = ring.pop_slice(data);
            if let Some(rest) = data.get_mut(filled..).filter(|rest| !rest.is_empty()) {
                rest.fill(0.0);
                stats.playback_underruns.fetch_add(1, Relaxed);
            }
            let at = info.timestamp();
            stats
                .playback_device_us
                .store(micros(at.playback.duration_since(at.callback)), Relaxed);
        },
        stream_error(notify),
        None,
    )?;

    Ok((stream, producer, channels, rate, name))
}

/// cpal's error callback runs off the real-time path (stream failures only),
/// so allocating here is fine.
fn stream_error(notify: &Notify) -> impl FnMut(cpal::Error) + Send + 'static {
    let notify = Arc::clone(notify);
    move |err| {
        notify(Event::StreamError {
            error: err.to_string(),
        })
    }
}

/// An f32 config, preferring 48 kHz (no resampling), then the highest rate
/// that has whole 20 ms frames (so 44.1 kHz Bluetooth music mode beats its
/// 16 kHz call mode), with the fewest channels at that rate.
fn pick_config(
    configs: impl Iterator<Item = SupportedStreamConfigRange>,
    what: &str,
) -> Result<SupportedStreamConfig, Error> {
    let configs: Vec<_> = configs.collect();
    let f32_configs = || {
        configs
            .iter()
            .filter(|range| range.sample_format() == SampleFormat::F32)
    };

    let at_48k = f32_configs()
        .filter_map(|range| range.try_with_sample_rate(SAMPLE_RATE))
        .min_by_key(SupportedStreamConfig::channels);

    let best_other = || {
        f32_configs()
            .filter_map(|range| {
                let rate = range.max_sample_rate();
                resample::frame_len(rate).and_then(|_| range.try_with_sample_rate(rate))
            })
            .max_by_key(|config| (config.sample_rate(), std::cmp::Reverse(config.channels())))
    };

    at_48k.or_else(best_other).ok_or_else(|| {
        let offered: Vec<_> = configs
            .iter()
            .map(|r| {
                format!(
                    "{}ch {} {}-{} Hz",
                    r.channels(),
                    r.sample_format(),
                    r.min_sample_rate(),
                    r.max_sample_rate()
                )
            })
            .collect();
        format!(
            "the {what} device has no usable f32 config; it offers: {}",
            offered.join(", ")
        )
        .into()
    })
}

fn describe(device: &cpal::Device, config: &SupportedStreamConfig) -> (StreamConfig, String) {
    let name = device
        .description()
        .map(|d| d.name().to_owned())
        .unwrap_or_else(|_| "unknown device".into());
    let description = format!(
        "{name}, {}ch {} Hz {}, buffer {:?}",
        config.channels(),
        config.sample_rate(),
        config.sample_format(),
        config.buffer_size()
    );
    (config.config(), description)
}

fn downmix(interleaved: &[f32], channels: usize, mono: &mut [f32]) {
    for (out, chunk) in mono.iter_mut().zip(interleaved.chunks_exact(channels)) {
        *out = chunk.iter().sum::<f32>() / channels as f32;
    }
}

fn upmix(mono: &[f32], channels: usize, interleaved: &mut [f32]) {
    for (sample, chunk) in mono.iter().zip(interleaved.chunks_exact_mut(channels)) {
        chunk.fill(*sample);
    }
}

fn samples_in(duration: Duration, rate: u32) -> usize {
    (duration.as_secs_f64() * f64::from(rate)) as usize
}

fn micros(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}
