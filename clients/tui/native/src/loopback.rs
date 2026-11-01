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
    volume_updates: Sender<MonitorVolume>,
    audition: bool,
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
        let (volume_updates, volume_changes) = mpsc::channel();
        let monitor = Monitor::new(volume_changes);
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
                    let result =
                        run_worker(capture, playback, &stop, &stats, &notify, preview, monitor);
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
                volume_updates,
                audition,
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

    /// Queues a local listening change without resetting capture or DSP.
    pub fn set_volume(&self, level: u8) -> Result<(), Error> {
        if !self.audition {
            return Err("preview volume requires an explicit audition".into());
        }
        let volume = MonitorVolume::new(level)?;
        self.volume_updates
            .send(volume)
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

/// Monitoring is deliberately downstream of decoding and metering: this
/// setting cannot alter masking headroom, microphone levels, or call audio.
#[derive(Clone, Copy)]
struct MonitorVolume {
    gain: f64,
}

impl MonitorVolume {
    fn new(level: u8) -> Result<Self, Error> {
        if !(1..=9).contains(&level) {
            return Err("preview volume must be between 1 and 9".into());
        }
        Ok(Self {
            gain: 10.0f64.powf(f64::from(level - 1) * 3.0 / 20.0),
        })
    }
}

struct Monitor {
    volume: MonitorVolume,
    changes: Receiver<MonitorVolume>,
}

impl Monitor {
    fn new(changes: Receiver<MonitorVolume>) -> Self {
        Self {
            volume: MonitorVolume { gain: 1.0 },
            changes,
        }
    }

    fn apply_pending(&mut self, stop: &AtomicBool) {
        if stop.load(Relaxed) {
            return;
        }
        let mut latest = None;
        for volume in self.changes.try_iter() {
            if stop.load(Relaxed) {
                return;
            }
            latest = Some(volume);
        }
        if let Some(volume) = latest.filter(|_| !stop.load(Relaxed)) {
            self.volume = volume;
        }
    }

    fn process(&self, decoded: &[f32; FRAME], output: &mut [f32; FRAME]) -> Result<(), Error> {
        for (input, output) in decoded.iter().zip(output.iter_mut()) {
            if !input.is_finite() {
                return Err("nonfinite preview audio".into());
            }
            // f64 multiplication stays finite for any finite f32 input.
            *output = (f64::from(*input) * self.volume.gain).clamp(-1.0, 1.0) as f32;
        }
        Ok(())
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
    mut monitor: Monitor,
) -> Result<(), Error> {
    let (mut encoder, mut decoder) = (Encoder::new()?, Decoder::new()?);
    let (mut frame, mut decoded) = ([0.0; FRAME], [0.0; FRAME]);
    let mut report = Report::new();
    let audition = preview.audition;
    report.voice_ms = preview.delay_ms();

    while !stop.load(Relaxed) {
        monitor.apply_pending(stop);
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

        let mut listening = [0.0; FRAME];
        if audition {
            monitor.process(&decoded, &mut listening)?;
        } else {
            listening.copy_from_slice(&decoded);
        }
        if stop.load(Relaxed) {
            break;
        }
        if !playback.write(&listening)? {
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
    fn monitor_levels_have_three_db_steps_and_finite_bounded_output() {
        let (_, changes) = mpsc::channel();
        let mut monitor = Monitor::new(changes);
        let mut output = [0.0; FRAME];
        let input = tone(0, 440.0);
        monitor.process(&input, &mut output).unwrap();
        assert_eq!(
            output, input,
            "default monitoring changes no ordinary samples"
        );
        for level in 1..=9 {
            monitor.volume = MonitorVolume::new(level).unwrap();
            let amplitude = 10.0f32.powf(f32::from(level - 1) * 3.0 / 20.0);
            monitor.process(&[0.01; FRAME], &mut output).unwrap();
            assert!(
                output
                    .iter()
                    .all(|sample| (*sample - 0.01 * amplitude).abs() < 1e-6)
            );
            monitor.process(&[f32::MAX; FRAME], &mut output).unwrap();
            assert_eq!(output, [1.0; FRAME]);
            monitor.process(&[-f32::MAX; FRAME], &mut output).unwrap();
            assert_eq!(output, [-1.0; FRAME]);
        }
        for level in [0, 10, 255] {
            assert!(MonitorVolume::new(level).is_err());
        }
        for invalid in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            assert!(monitor.process(&[invalid; FRAME], &mut output).is_err());
        }
    }

    #[test]
    fn monitor_changes_coalesce_and_stop_wins_without_resetting_masking() {
        let (updates, changes) = mpsc::channel();
        let mut monitor = Monitor::new(changes);
        let (mut running, _) = preview(Some(Style::LowerResonance), true);
        let (mut reference, _) = preview(Some(Style::LowerResonance), true);
        let mut output = [0.0; FRAME];
        let mut expected = [0.0; FRAME];
        for frame in 0..40 {
            if frame == 20 {
                for level in [9, 1, 4] {
                    updates.send(MonitorVolume::new(level).unwrap()).unwrap();
                }
                monitor.apply_pending(&AtomicBool::new(false));
                assert!((monitor.volume.gain - 10.0f64.powf(9.0 / 20.0)).abs() < 1e-9);
            }
            running.process(&tone(frame, 220.0), &mut output).unwrap();
            reference
                .process(&tone(frame, 220.0), &mut expected)
                .unwrap();
            assert_eq!(output, expected, "volume reset masking at frame {frame}");
        }
        updates.send(MonitorVolume::new(9).unwrap()).unwrap();
        let before = monitor.volume.gain;
        monitor.apply_pending(&AtomicBool::new(true));
        assert_eq!(monitor.volume.gain, before);
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
