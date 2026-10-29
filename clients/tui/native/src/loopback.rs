//! Stage 0 loopback: mic → Opus encode → decode → speaker, reporting live
//! latency stats as `Event`s (over the Port, or to stderr from the CLI). It
//! proves device access, mic permission, and the codec path without a call.
//! Audio I/O is `audio`; this module is just the worker loop and its report.

use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::sync::{
    Arc,
    mpsc::{self, Receiver, Sender},
};
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
    updates: Sender<Option<randos_voice_native::Style>>,
    worker: JoinHandle<Result<(), Error>>,
}

impl Loopback {
    pub fn start(input: Input, output: Output, notify: Notify) -> Result<(Self, Started), Error> {
        Self::start_with_mask(input, output, notify, None, false)
    }

    pub fn start_with_mask(
        input: Input,
        output: Output,
        notify: Notify,
        masking: Option<randos_voice_native::Style>,
        audition: bool,
    ) -> Result<(Self, Started), Error> {
        let mut voice = crate::voice::Voice::new(randos_voice::Variant::Passthrough, &[], masking)?;
        voice.set_eligible(true)?;
        let Devices {
            capture,
            playback,
            stats,
            streams,
            started,
        } = Devices::open(input, output, &notify)?;

        let stop = Arc::new(AtomicBool::new(false));
        let (updates, changes) = mpsc::channel();
        let preview = Preview {
            voice,
            masking,
            audition,
            changes,
        };
        let worker = {
            let stop = Arc::clone(&stop);
            thread::Builder::new()
                .name("loopback".into())
                .spawn(move || {
                    let result = run_worker(capture, playback, &stop, &stats, &notify, preview);
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
                updates,
                worker,
            },
            started,
        ))
    }

    /// Queues a change for the existing worker; devices stay open.
    pub fn set_masking(&self, style: Option<randos_voice_native::Style>) -> Result<(), Error> {
        self.updates
            .send(style)
            .map_err(|_| "loopback worker stopped".into())
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

struct Preview {
    voice: crate::voice::Voice,
    masking: Option<randos_voice_native::Style>,
    audition: bool,
    changes: Receiver<Option<randos_voice_native::Style>>,
}

impl Preview {
    fn apply_pending(&mut self, stop: &AtomicBool, capture: &mut Capture) -> Result<bool, Error> {
        let mut latest = None;
        for change in self.changes.try_iter() {
            if stop.load(Relaxed) {
                return Ok(false);
            }
            latest = Some(change);
        }
        let Some(masking) = latest else {
            return Ok(false);
        };
        if stop.load(Relaxed) {
            return Ok(false);
        }
        let mut voice = crate::voice::Voice::new(randos_voice::Variant::Passthrough, &[], masking)?;
        voice.set_eligible(true)?;
        capture.discard_pending()?;
        self.voice = voice;
        self.masking = masking;
        self.audition = true;
        Ok(true)
    }

    fn process(&mut self, frame: &[f32; FRAME], output: &mut [f32; FRAME]) -> Result<(), Error> {
        if self.audition && self.masking.is_none() {
            // Off is explicit original-voice monitoring, at the same headroom
            // as masked previews. The silent meter and CLI stay unchanged.
            self.voice
                .process(&frame.map(|sample| sample * 0.25), output)
        } else {
            self.voice.process(frame, output)
        }
    }

    fn delay_ms(&self) -> f64 {
        if self.masking.is_some() {
            randos_voice_native::FRAME_PREFIX_SAMPLES as f64 / 48.0
        } else {
            0.0
        }
    }
}

fn run_worker(
    mut capture: Capture,
    mut playback: Playback,
    stop: &AtomicBool,
    stats: &DeviceStats,
    notify: &Notify,
    mut preview: Preview,
) -> Result<(), Error> {
    let (mut encoder, mut decoder) = (Encoder::new()?, Decoder::new()?);
    let (mut frame, mut decoded) = ([0.0; FRAME], [0.0; FRAME]);
    let mut report = Report::new();
    report.voice_ms = preview.delay_ms();

    while !stop.load(Relaxed) {
        if preview.apply_pending(stop, &mut capture)? {
            encoder = Encoder::new()?;
            decoder = Decoder::new()?;
            playback.reset_resampler()?;
            report = Report::new();
            report.voice_ms = preview.delay_ms();
        }
        if stop.load(Relaxed) {
            break;
        }
        if !capture.read(&mut frame)? {
            thread::sleep(Duration::from_millis(2));
            continue;
        }

        let mut processed = [0.0; FRAME];
        preview.process(&frame, &mut processed)?;
        let packet = encoder.encode(&processed)?;
        let packet_bytes = packet.len();
        decoder.decode(packet, &mut decoded)?;

        if !playback.write(&decoded)? {
            report.dropped += 1;
        }

        report.frame(packet_bytes, &processed, &capture, &playback, stats, notify);
    }

    playback.finish()
}

/// Reports once a second where the mouth-to-ear latency goes, and every
/// `LEVELS_EVERY` the mic's meter bars.
struct Report {
    voice_ms: f64,
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
            voice_ms: 0.0,
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
            voice_ms: self.voice_ms,
            latency_ms: self.voice_ms
                + capture_device_ms
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

#[cfg(test)]
mod tests {
    use super::*;
    use randos_voice_native::Style;

    fn preview(masking: Option<Style>, audition: bool) -> (Preview, Sender<Option<Style>>) {
        let (updates, changes) = mpsc::channel();
        let mut voice =
            crate::voice::Voice::new(randos_voice::Variant::Passthrough, &[], masking).unwrap();
        voice.set_eligible(true).unwrap();
        (
            Preview {
                voice,
                masking,
                audition,
                changes,
            },
            updates,
        )
    }

    fn capture() -> Capture {
        Capture::Sine {
            sine: crate::codec::Sine::new(440.0),
            next_frame: Instant::now(),
        }
    }

    fn tone(frame: usize, hz: f32) -> [f32; FRAME] {
        std::array::from_fn(|i| {
            ((frame * FRAME + i) as f32 * hz * std::f32::consts::TAU / 48000.0).sin() * 0.2
        })
    }

    #[test]
    fn changes_discard_old_voice_history_and_coalesce_to_latest_selection() {
        let (mut running, changes) = preview(Some(Style::LowerResonance), true);
        let mut output = [0.0; FRAME];
        let mut capture = capture();
        let stop = AtomicBool::new(false);
        for style in [
            Some(Style::HigherResonancePitch),
            None,
            Some(Style::LowerResonancePitch),
            Some(Style::HigherResonance),
        ] {
            for i in 0..35 {
                running.process(&tone(i, 1200.0), &mut output).unwrap();
            }
            changes.send(Some(Style::LowerResonance)).unwrap();
            changes.send(None).unwrap();
            changes.send(style).unwrap();
            assert!(running.apply_pending(&stop, &mut capture).unwrap());
            assert_eq!(running.masking, style);
            let (mut fresh, _) = preview(style, true);
            for i in 0..40 {
                let mut expected = [0.0; FRAME];
                fresh.process(&tone(i, 220.0), &mut expected).unwrap();
                running.process(&tone(i, 220.0), &mut output).unwrap();
                assert_eq!(output, expected, "previous style history at frame {i}");
            }
            assert!(!running.apply_pending(&stop, &mut capture).unwrap());
        }
    }

    #[test]
    fn explicit_off_matches_headroom_without_changing_plain_loopback_and_stop_wins() {
        let (mut original, updates) = preview(None, true);
        let (mut meter, _) = preview(None, false);
        let input = tone(0, 440.0);
        let mut output = [0.0; FRAME];
        original.process(&input, &mut output).unwrap();
        assert_eq!(output, input.map(|x| x * 0.25));
        meter.process(&input, &mut output).unwrap();
        assert_eq!(output, input);
        updates.send(Some(Style::LowerResonance)).unwrap();
        assert!(
            !original
                .apply_pending(&AtomicBool::new(true), &mut capture())
                .unwrap()
        );
        assert_eq!(original.masking, None);
    }
}
