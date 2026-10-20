//! Stage 0 loopback: mic → Opus encode → decode → speaker, reporting live
//! latency stats as `Event`s (over the Port, or to stderr from the CLI). It
//! proves device access, mic permission, and the codec path without a call.
//! Audio I/O is `audio`; this module is just the worker loop and its report.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use cpal::Stream;
use cpal::traits::StreamTrait;
use serde::Serialize;

use crate::Error;
use crate::audio::{Capture, DeviceStats, Input, Notify, Output, Playback};
use crate::codec::{self, CODEC_DELAY_MS, Decoder, Encoder, FRAME};
use crate::protocol::{Event, LoopbackStats};

/// What a started loopback is actually using, for the reply and the CLI.
#[derive(Debug, Serialize)]
pub struct Started {
    pub input: String,
    pub output: String,
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
        let stats = Arc::new(DeviceStats::default());
        let (capture, capture_stream, input_name) = Capture::open(input, &stats, &notify)?;
        let (playback, playback_stream, output_name) = Playback::open(output, &stats, &notify)?;

        let streams: Vec<Stream> = capture_stream.into_iter().chain(playback_stream).collect();
        for stream in &streams {
            stream.play()?;
        }

        let stop = Arc::new(AtomicBool::new(false));
        let worker = {
            let stop = Arc::clone(&stop);
            thread::Builder::new()
                .name("loopback".into())
                .spawn(move || {
                    let result = run_worker(capture, playback, &stop, &stats, &notify);
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

fn run_worker(
    mut capture: Capture,
    mut playback: Playback,
    stop: &AtomicBool,
    stats: &DeviceStats,
    notify: &Notify,
) -> Result<(), Error> {
    let (mut encoder, mut decoder) = (Encoder::new()?, Decoder::new()?);
    let (mut frame, mut decoded) = ([0.0; FRAME], [0.0; FRAME]);
    let mut report = Report::new();

    while !stop.load(Relaxed) {
        if !capture.read(&mut frame)? {
            thread::sleep(Duration::from_millis(2));
            continue;
        }

        let packet = encoder.encode(&frame)?;
        let packet_bytes = packet.len();
        decoder.decode(packet, &mut decoded)?;

        if !playback.write(&decoded)? {
            report.dropped += 1;
        }

        report.frame(packet_bytes, &frame, &capture, &playback, stats, notify);
    }

    playback.finish()
}

/// Reports once a second where the mouth-to-ear latency goes.
struct Report {
    since: Instant,
    bytes: usize,
    peak: f32,
    dropped: u64,
}

impl Report {
    fn new() -> Self {
        Self {
            since: Instant::now(),
            bytes: 0,
            peak: 0.0,
            dropped: 0,
        }
    }

    fn frame(
        &mut self,
        bytes: usize,
        input: &[f32; FRAME],
        capture: &Capture,
        playback: &Playback,
        stats: &DeviceStats,
        notify: &Notify,
    ) {
        self.bytes += bytes;
        self.peak = self.peak.max(codec::rms(input));

        let elapsed = self.since.elapsed();
        if elapsed < Duration::from_secs(1) {
            return;
        }

        let capture_device_ms = stats.capture_device_ms();
        let playback_device_ms = stats.playback_device_ms();
        let capture_ring_ms = capture.queued_ms();
        let playback_ring_ms = playback.queued_ms();
        let resample_ms = capture.resample_ms() + playback.resample_ms();

        notify(Event::LoopbackStats(LoopbackStats {
            latency_ms: capture_device_ms
                + capture_ring_ms
                + CODEC_DELAY_MS
                + resample_ms
                + playback_ring_ms
                + playback_device_ms,
            capture_device_ms,
            capture_ring_ms,
            codec_ms: CODEC_DELAY_MS,
            resample_ms,
            playback_ring_ms,
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
