//! Stage 0 loopback: mic → Opus encode → decode → speaker, reporting live
//! latency stats as `Event`s (over the Port, or to stderr from the CLI). It
//! proves device access, mic permission, and the codec path without a call.
//! Audio I/O is `audio`; this module is just the worker loop and its report.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use cpal::Stream;

use crate::Error;
use crate::audio::{Capture, DeviceStats, Devices, Input, Notify, Output, Playback, Started};
use crate::codec::{CODEC_DELAY_MS, Decoder, Encoder, FRAME, Peak};
use crate::protocol::{Event, LoopbackStats};
use crate::report::{LEVELS_EVERY, rounded};
use crate::spectrum::Analyser;

/// A running loopback. Dropping the streams stops the devices; `stop`
/// also joins the worker and surfaces its error, if any.
pub struct Loopback {
    _streams: Vec<Stream>,
    stop: Arc<AtomicBool>,
    worker: JoinHandle<Result<(), Error>>,
}

impl Loopback {
    pub fn start(input: Input, output: Output, notify: Notify) -> Result<(Self, Started), Error> {
        let Devices {
            capture,
            playback,
            stats,
            streams,
            started,
        } = Devices::open(input, output, &notify)?;

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

/// Reports once a second where the mouth-to-ear latency goes, and every
/// `LEVELS_EVERY` the mic's meter bars.
struct Report {
    since: Instant,
    bytes: usize,
    peak: Peak,
    dropped: u64,
    bars: Analyser,
    levels_since: Instant,
}

impl Report {
    fn new() -> Self {
        Self {
            since: Instant::now(),
            bytes: 0,
            peak: Peak::default(),
            dropped: 0,
            bars: Analyser::new(),
            levels_since: Instant::now(),
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
        self.peak.add(input);
        self.bars.push(input);

        if self.levels_since.elapsed() >= LEVELS_EVERY {
            self.levels_since = Instant::now();
            // A failed FFT only skips one meter frame.
            if let Ok(you) = self.bars.bars() {
                notify(Event::LoopbackLevels { you: rounded(&you) });
            }
        }

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
            input_peak_dbfs: self.peak.dbfs(),
            underruns: stats.playback_underruns.load(Relaxed),
            overruns: stats.capture_overruns.load(Relaxed),
            dropped: self.dropped,
        }));

        self.since = Instant::now();
        self.bytes = 0;
        self.peak = Peak::default();
    }
}
