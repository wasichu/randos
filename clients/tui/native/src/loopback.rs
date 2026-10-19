//! Stage 0 loopback: mic → Opus encode → decode → speaker, reporting live
//! latency stats as `Event`s (over the Port, or to stderr from the CLI). It proves device access, macOS mic permission, and the
//! codec path before WebRTC exists.
//!
//! Threads: the cpal callbacks only copy samples into or out of lock-free
//! rings and bump atomic counters (no allocation, locks, or I/O). A worker
//! thread does everything else: downmix, Opus, upmix, WAV writing, stats.

use std::fs::File;
use std::io::BufWriter;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, Stream, StreamConfig, SupportedStreamConfig, SupportedStreamConfigRange};
use ringbuf::traits::{Consumer, Observer, Producer, Split};
use ringbuf::{HeapCons, HeapProd, HeapRb};

use serde::Serialize;

use crate::Error;
use crate::codec::{self, FRAME, OpusLoop, SAMPLE_RATE, Sine};
use crate::protocol::{Event, LoopbackStats};

/// Where the loopback reports stats and failures. Called from the worker and
/// from cpal's error callbacks, never from the real-time data callbacks.
pub type Notify = Arc<dyn Fn(Event) + Send + Sync>;

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

/// What a started loopback is actually using, for the reply and the CLI.
#[derive(Debug, Serialize)]
pub struct Started {
    pub input: String,
    pub output: String,
}

/// Playback may queue at most this much (two frames); beyond it, frames are
/// dropped. That sheds the startup burst and any clock drift between the
/// mic and speaker, so latency can't creep up.
const MAX_PLAYBACK_QUEUE: Duration = Duration::from_millis(40);

#[derive(Default)]
struct Stats {
    capture_overruns: AtomicU64,
    playback_underruns: AtomicU64,
    capture_device_us: AtomicU64,
    playback_device_us: AtomicU64,
}

enum Source {
    Device {
        ring: HeapCons<f32>,
        channels: usize,
    },
    Sine(Sine),
}

enum Sink {
    Device {
        ring: HeapProd<f32>,
        channels: usize,
    },
    Null,
    Wav(hound::WavWriter<BufWriter<File>>),
}

/// A running loopback. Dropping the streams stops the devices; `stop`
/// also joins the worker and surfaces its error, if any.
pub struct Loopback {
    _streams: Vec<Stream>,
    stop: Arc<AtomicBool>,
    worker: JoinHandle<Result<(), Error>>,
}

impl Loopback {
    pub fn start(input: Input, output: Output, notify: Notify) -> Result<(Self, Started), Error> {
        let host = cpal::default_host();
        let stats = Arc::new(Stats::default());
        let mut streams = Vec::new();

        let (source, input_name) = match input {
            Input::Sine => (Source::Sine(Sine::new(440.0)), "sine 440 Hz".to_owned()),
            Input::Device => {
                let (stream, ring, channels, name) = open_capture(&host, &stats, &notify)?;
                streams.push(stream);
                (Source::Device { ring, channels }, name)
            }
        };

        let (sink, output_name) = match output {
            Output::Null => (Sink::Null, "null".to_owned()),
            Output::Wav(path) => {
                let name = format!("wav:{}", path.display());
                let writer = hound::WavWriter::create(
                    path,
                    hound::WavSpec {
                        channels: 1,
                        sample_rate: SAMPLE_RATE,
                        bits_per_sample: 32,
                        sample_format: hound::SampleFormat::Float,
                    },
                )?;
                (Sink::Wav(writer), name)
            }
            Output::Device => {
                let (stream, ring, channels, name) = open_playback(&host, &stats, &notify)?;
                streams.push(stream);
                (Sink::Device { ring, channels }, name)
            }
        };

        for stream in &streams {
            stream.play()?;
        }

        let stop = Arc::new(AtomicBool::new(false));
        let worker = {
            let stop = Arc::clone(&stop);
            thread::Builder::new()
                .name("loopback".into())
                .spawn(move || {
                    let result = run_worker(source, sink, &stop, &stats, &notify);
                    if let Err(err) = &result {
                        notify(Event::LoopbackFailed {
                            error: err.to_string(),
                        });
                    }
                    result
                })?
        };

        let started = Started {
            input: input_name,
            output: output_name,
        };
        Ok((
            Self {
                _streams: streams,
                stop,
                worker,
            },
            started,
        ))
    }

    /// False once the worker has stopped on its own (it reported `LoopbackFailed`).
    pub fn is_running(&self) -> bool {
        !self.worker.is_finished()
    }

    pub fn stop(self) -> Result<(), Error> {
        self.stop.store(true, Relaxed);
        self.worker.join().map_err(|_| "loopback worker panicked")?
    }
}

fn open_capture(
    host: &cpal::Host,
    stats: &Arc<Stats>,
    notify: &Notify,
) -> Result<(Stream, HeapCons<f32>, usize, String), Error> {
    let device = host
        .default_input_device()
        .ok_or("no default input device")?;
    let config = pick_config(device.supported_input_configs()?, "input")?;
    let (config, name) = describe(&device, &config);
    let channels = usize::from(config.channels);

    let (mut ring, consumer) = HeapRb::<f32>::new(SAMPLE_RATE as usize * channels).split();
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

    Ok((stream, consumer, channels, name))
}

fn open_playback(
    host: &cpal::Host,
    stats: &Arc<Stats>,
    notify: &Notify,
) -> Result<(Stream, HeapProd<f32>, usize, String), Error> {
    let device = host
        .default_output_device()
        .ok_or("no default output device")?;
    let config = pick_config(device.supported_output_configs()?, "output")?;
    let (config, name) = describe(&device, &config);
    let channels = usize::from(config.channels);

    let (producer, mut ring) = HeapRb::<f32>::new(SAMPLE_RATE as usize * channels).split();
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

    Ok((stream, producer, channels, name))
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

/// The fewest-channel f32 config at 48 kHz. Fails loudly rather than falling
/// back to another rate: a silent 44.1 kHz stream would "work" and sound wrong.
fn pick_config(
    configs: impl Iterator<Item = SupportedStreamConfigRange>,
    what: &str,
) -> Result<SupportedStreamConfig, Error> {
    let configs: Vec<_> = configs.collect();

    configs
        .iter()
        .filter(|range| range.sample_format() == SampleFormat::F32)
        .filter_map(|range| range.try_with_sample_rate(SAMPLE_RATE))
        .min_by_key(SupportedStreamConfig::channels)
        .ok_or_else(|| {
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
                "the {what} device has no 48 kHz f32 config (resampling comes in Stage 2); it offers: {}",
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

fn run_worker(
    mut source: Source,
    mut sink: Sink,
    stop: &AtomicBool,
    stats: &Stats,
    notify: &Notify,
) -> Result<(), Error> {
    let mut codec = OpusLoop::new()?;
    let (mut frame, mut decoded) = ([0.0; FRAME], [0.0; FRAME]);
    let mut interleaved = Vec::new();
    let frame_time = Duration::from_millis(20);
    let mut next_frame = Instant::now();
    let mut report = Report::new();

    while !stop.load(Relaxed) {
        match &mut source {
            Source::Device { ring, channels } => {
                if ring.occupied_len() < FRAME * *channels {
                    thread::sleep(Duration::from_millis(2));
                    continue;
                }
                interleaved.resize(FRAME * *channels, 0.0);
                ring.pop_slice(&mut interleaved);
                downmix(&interleaved, *channels, &mut frame);
            }
            // Nothing else paces a synthetic source, so keep real time.
            Source::Sine(sine) => {
                next_frame += frame_time;
                thread::sleep(next_frame.saturating_duration_since(Instant::now()));
                sine.fill(&mut frame);
            }
        }

        let packet_bytes = codec.process(&frame, &mut decoded)?;

        match &mut sink {
            Sink::Device { ring, channels } => {
                if ring.occupied_len() > samples_in(MAX_PLAYBACK_QUEUE) * *channels {
                    report.dropped += 1;
                } else {
                    interleaved.resize(FRAME * *channels, 0.0);
                    upmix(&decoded, *channels, &mut interleaved);
                    ring.push_slice(&interleaved);
                }
            }
            Sink::Null => {}
            Sink::Wav(writer) => {
                for sample in decoded {
                    writer.write_sample(sample)?;
                }
            }
        }

        report.frame(packet_bytes, &frame, &source, &sink, stats, notify);
    }

    if let Sink::Wav(writer) = sink {
        writer.finalize()?;
    }
    Ok(())
}

fn downmix(interleaved: &[f32], channels: usize, mono: &mut [f32; FRAME]) {
    for (out, chunk) in mono.iter_mut().zip(interleaved.chunks_exact(channels)) {
        *out = chunk.iter().sum::<f32>() / channels as f32;
    }
}

fn upmix(mono: &[f32; FRAME], channels: usize, interleaved: &mut [f32]) {
    for (sample, chunk) in mono.iter().zip(interleaved.chunks_exact_mut(channels)) {
        chunk.fill(*sample);
    }
}

fn samples_in(duration: Duration) -> usize {
    (duration.as_secs_f64() * f64::from(SAMPLE_RATE)) as usize
}

fn ms_of(samples: usize) -> f64 {
    samples as f64 * 1000.0 / f64::from(SAMPLE_RATE)
}

fn micros(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}

/// Reports once a second where the mouth-to-ear latency goes.
struct Report {
    since: Instant,
    frames: u32,
    bytes: usize,
    peak: f32,
    dropped: u64,
}

impl Report {
    fn new() -> Self {
        Self {
            since: Instant::now(),
            frames: 0,
            bytes: 0,
            peak: 0.0,
            dropped: 0,
        }
    }

    fn frame(
        &mut self,
        bytes: usize,
        input: &[f32; FRAME],
        source: &Source,
        sink: &Sink,
        stats: &Stats,
        notify: &Notify,
    ) {
        self.frames += 1;
        self.bytes += bytes;
        self.peak = self.peak.max(codec::rms(input));

        let elapsed = self.since.elapsed();
        if elapsed < Duration::from_secs(1) {
            return;
        }

        let capture_ring = match source {
            Source::Device { ring, channels } => ms_of(ring.occupied_len() / channels),
            Source::Sine(_) => 0.0,
        };
        let playback_ring = match sink {
            Sink::Device { ring, channels } => ms_of(ring.occupied_len() / channels),
            Sink::Null | Sink::Wav(_) => 0.0,
        };
        let capture_device_ms = stats.capture_device_us.load(Relaxed) as f64 / 1000.0;
        let playback_device_ms = stats.playback_device_us.load(Relaxed) as f64 / 1000.0;
        // A whole 20 ms frame is buffered before encoding, plus 6.5 ms of Opus lookahead.
        let codec_ms = 26.5;

        notify(Event::LoopbackStats(LoopbackStats {
            latency_ms: capture_device_ms
                + capture_ring
                + codec_ms
                + playback_ring
                + playback_device_ms,
            capture_device_ms,
            capture_ring_ms: capture_ring,
            codec_ms,
            playback_ring_ms: playback_ring,
            playback_device_ms,
            kbps: self.bytes as f64 * 8.0 / elapsed.as_secs_f64() / 1000.0,
            input_peak_dbfs: f64::from(20.0 * self.peak.max(1e-6).log10()),
            underruns: stats.playback_underruns.load(Relaxed),
            overruns: stats.capture_overruns.load(Relaxed),
            dropped: self.dropped,
        }));

        *self = Self {
            dropped: self.dropped,
            ..Self::new()
        };
    }
}
