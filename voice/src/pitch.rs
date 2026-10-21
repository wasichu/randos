//! A delay-line ("Doppler") pitch shifter: two read heads sweep a short
//! delay line at a speed set by the pitch ratio, each fading in and out
//! (Hann gains, which sum to one) so one is always mid-sweep while the
//! other jumps back.
//! Cheap and low-latency (about half the window on average), but it shifts
//! formants with the pitch, so voices sound smaller or larger rather than
//! like someone else: v0's baseline for the lab, not the final answer.

use std::f32::consts::PI;

pub const SEMITONES_RANGE: (f32, f32) = (-12.0, 12.0);
pub const DEFAULT_SEMITONES: f32 = -4.0;
pub const WINDOW_MS_RANGE: (f32, f32) = (10.0, 100.0);
pub const DEFAULT_WINDOW_MS: f32 = 40.0;

pub struct PitchShifter {
    buffer: Vec<f32>,
    mask: usize,
    write: usize,
    sample_rate: f32,
    ratio: f32,
    /// The sweep's length, in samples.
    window: f32,
    /// Where the first head is in its sweep, 0..1 (the second is half a
    /// sweep ahead).
    phase: f32,
}

impl PitchShifter {
    pub fn new(sample_rate: f32) -> Self {
        let longest = (WINDOW_MS_RANGE.1 / 1_000.0 * sample_rate).ceil() as usize + 4;
        let len = longest.next_power_of_two();
        let mut shifter = Self {
            buffer: vec![0.0; len],
            mask: len - 1,
            write: 0,
            sample_rate,
            ratio: 1.0,
            window: 1.0,
            phase: 0.0,
        };
        shifter.set_semitones(DEFAULT_SEMITONES);
        shifter.set_window_ms(DEFAULT_WINDOW_MS);
        shifter
    }

    pub fn set_semitones(&mut self, semitones: f32) {
        let semitones = semitones.clamp(SEMITONES_RANGE.0, SEMITONES_RANGE.1);
        self.ratio = 2.0_f32.powf(semitones / 12.0);
    }

    pub fn set_window_ms(&mut self, ms: f32) {
        let ms = ms.clamp(WINDOW_MS_RANGE.0, WINDOW_MS_RANGE.1);
        self.window = ms / 1_000.0 * self.sample_rate;
    }

    pub fn process(&mut self, input: &[f32], output: &mut [f32]) {
        // The delay changes by (1 - ratio) samples per sample: shrinking
        // (reading faster than writing) raises the pitch.
        let step = (1.0 - self.ratio) / self.window;
        for (out, sample) in output.iter_mut().zip(input) {
            if let Some(slot) = self.buffer.get_mut(self.write) {
                *slot = *sample;
            }
            let first = self.phase;
            let second = (self.phase + 0.5).rem_euclid(1.0);
            *out = fade(first) * self.read(first * self.window)
                + fade(second) * self.read(second * self.window);
            self.phase = (self.phase + step).rem_euclid(1.0);
            self.write = (self.write + 1) & self.mask;
        }
    }

    /// The sample `delay` samples ago (0: the one just written), linearly
    /// interpolated.
    fn read(&self, delay: f32) -> f32 {
        let position = self.write as f32 - delay;
        let whole = position.floor();
        let fraction = position - whole;
        let at = |offset: isize| {
            let index = (whole as isize + offset).rem_euclid(self.buffer.len() as isize) as usize;
            self.buffer.get(index).copied().unwrap_or(0.0)
        };
        at(0) * (1.0 - fraction) + at(1) * fraction
    }
}

/// A head's gain at `phase` of its sweep: sin², so the two heads' gains
/// (half a sweep apart) always sum to one.
fn fade(phase: f32) -> f32 {
    let s = (PI * phase).sin();
    s * s
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: f32 = 48_000.0;

    fn tone(hz: f32, seconds: f32) -> Vec<f32> {
        (0..(RATE * seconds) as usize)
            .map(|i| (2.0 * PI * hz * i as f32 / RATE).sin() * 0.5)
            .collect()
    }

    /// The strongest frequency between 100 and 1,000 Hz (Goertzel, 1 Hz steps).
    fn dominant_hz(samples: &[f32]) -> f32 {
        let power = |hz: f32| {
            let coefficient = 2.0 * (2.0 * PI * hz / RATE).cos();
            let (mut previous, mut before) = (0.0_f32, 0.0_f32);
            for sample in samples {
                let current = sample + coefficient * previous - before;
                before = previous;
                previous = current;
            }
            previous * previous + before * before - coefficient * previous * before
        };
        (100..1_000)
            .map(|hz| hz as f32)
            .max_by(|a, b| power(*a).total_cmp(&power(*b)))
            .unwrap_or(0.0)
    }

    fn shifted(semitones: f32, input: &[f32]) -> Vec<f32> {
        let mut shifter = PitchShifter::new(RATE);
        shifter.set_semitones(semitones);
        let mut output = vec![0.0; input.len()];
        // In 128-sample blocks, as the AudioWorklet calls it.
        for (inp, out) in input.chunks(128).zip(output.chunks_mut(128)) {
            shifter.process(inp, out);
        }
        output
    }

    #[test]
    fn shifts_a_tone_by_the_ratio() {
        let input = tone(440.0, 1.0);
        for (semitones, expected) in [(-12.0, 220.0), (-4.0, 349.2), (7.0, 659.3)] {
            let output = shifted(semitones, &input);
            // Skip the first window while the delay line fills.
            let measured = dominant_hz(output.get(4_800..).unwrap_or_default());
            // Within half a semitone: the crossfade modulates the level at
            // the sweep rate, and its sidebands can top a single-bin peak.
            assert!(
                (measured - expected).abs() / expected < 0.03,
                "{semitones} semitones: {measured} Hz, expected {expected}"
            );
        }
    }

    #[test]
    fn keeps_the_level_and_stays_finite() {
        let input = tone(300.0, 1.0);
        let output = shifted(-5.0, &input);
        let rms = |s: &[f32]| (s.iter().map(|x| x * x).sum::<f32>() / s.len() as f32).sqrt();
        let (before, after) = (rms(&input), rms(output.get(4_800..).unwrap_or_default()));
        assert!(output.iter().all(|x| x.is_finite()));
        assert!(
            (after / before - 1.0).abs() < 0.25,
            "level {before} -> {after}"
        );
    }

    #[test]
    fn parameters_are_clamped() {
        let mut shifter = PitchShifter::new(RATE);
        shifter.set_semitones(99.0);
        assert!((shifter.ratio - 2.0).abs() < 1e-6);
        shifter.set_window_ms(0.0);
        assert!((shifter.window - 480.0).abs() < 1e-3);
    }
}
