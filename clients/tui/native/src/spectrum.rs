//! Frequency bars for the TUI's audio meters: the same numbers the website's
//! visualizer draws (`assets/js/randos/audio_visualizer.js`), so the two
//! clients look alike. That visualizer reads a Web Audio `AnalyserNode`
//! (fftSize 256, smoothing 0.82, -100..-30 dB) every 50 ms and draws the
//! first 12 of 24 buckets of 5 bins (about 0-11 kHz at 48 kHz), mirrored.
//! This does what `AnalyserNode.getByteFrequencyData` does: a Blackman
//! window over the newest 256 samples, an FFT, magnitude smoothed over time,
//! then decibels scaled to 0..1.
//!
//! Runs on the call session thread (never a real-time audio callback).

use std::sync::Arc;

use realfft::num_complex::Complex;
use realfft::{RealFftPlanner, RealToComplex};

use crate::Error;

/// Bars per side of the mirrored meter (the website's `BARS_PER_SIDE`).
pub const BARS: usize = 12;

const FFT_SIZE: usize = 256;
const BINS: usize = FFT_SIZE / 2 + 1;
/// The website buckets 128 bins into 24 bars: 5 bins each, of which it draws
/// the first 12.
const BINS_PER_BAR: usize = (FFT_SIZE / 2) / (BARS * 2);
const SMOOTHING: f32 = 0.82;
const MIN_DB: f32 = -100.0;
const MAX_DB: f32 = -30.0;
/// The website's floor, so a silent meter still shows a thin line.
const FLOOR: f32 = 0.04;

pub struct Analyser {
    fft: Arc<dyn RealToComplex<f32>>,
    window: Vec<f32>,
    /// The newest `FFT_SIZE` samples, oldest first.
    recent: Vec<f32>,
    /// Whether audio arrived since the last `bars`; if not, the meter decays
    /// as it would on silence (a stalled stream mustn't freeze the bars).
    fresh: bool,
    input: Vec<f32>,
    output: Vec<Complex<f32>>,
    smoothed: Vec<f32>,
}

impl Analyser {
    pub fn new() -> Self {
        let fft = RealFftPlanner::<f32>::new().plan_fft_forward(FFT_SIZE);
        // Web Audio's Blackman window (alpha 0.16).
        let window = (0..FFT_SIZE)
            .map(|n| {
                let x = std::f32::consts::TAU * n as f32 / FFT_SIZE as f32;
                0.42 - 0.5 * x.cos() + 0.08 * (2.0 * x).cos()
            })
            .collect();
        Self {
            input: fft.make_input_vec(),
            output: fft.make_output_vec(),
            fft,
            window,
            recent: vec![0.0; FFT_SIZE],
            fresh: false,
            smoothed: vec![0.0; BINS],
        }
    }

    /// Audio that was just sent or played (any length).
    pub fn push(&mut self, samples: &[f32]) {
        let newest = &samples[samples.len().saturating_sub(FFT_SIZE)..];
        self.recent.rotate_left(newest.len());
        let start = FFT_SIZE - newest.len();
        self.recent[start..].copy_from_slice(newest);
        self.fresh = true;
    }

    /// The bars now, each 0..1 (lowest frequencies first).
    pub fn bars(&mut self) -> Result<[f32; BARS], Error> {
        if !self.fresh {
            self.recent.fill(0.0);
        }
        self.fresh = false;

        for ((input, sample), weight) in self.input.iter_mut().zip(&self.recent).zip(&self.window) {
            *input = sample * weight;
        }
        self.fft
            .process(&mut self.input, &mut self.output)
            .map_err(|err| format!("spectrum: {err}"))?;
        for (smoothed, bin) in self.smoothed.iter_mut().zip(&self.output) {
            let magnitude = bin.norm() / FFT_SIZE as f32;
            *smoothed = SMOOTHING * *smoothed + (1.0 - SMOOTHING) * magnitude;
        }

        let mut bars = [FLOOR; BARS];
        for (bar, chunk) in bars.iter_mut().zip(self.smoothed.chunks(BINS_PER_BAR)) {
            let scaled: f32 = chunk
                .iter()
                .map(|&magnitude| {
                    let db = 20.0 * magnitude.max(1e-12).log10();
                    ((db - MIN_DB) / (MAX_DB - MIN_DB)).clamp(0.0, 1.0)
                })
                .sum::<f32>()
                / chunk.len() as f32;
            *bar = scaled.max(FLOOR);
        }
        Ok(bars)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(hz: f32, amplitude: f32, len: usize) -> Vec<f32> {
        (0..len)
            .map(|n| amplitude * (std::f32::consts::TAU * hz * n as f32 / 48_000.0).sin())
            .collect()
    }

    /// Feeds 50 ms frames of `samples` for a while, as a call would.
    fn settle(analyser: &mut Analyser, samples: &[f32]) -> [f32; BARS] {
        let mut bars = [0.0; BARS];
        for _ in 0..30 {
            analyser.push(samples);
            bars = analyser.bars().unwrap();
        }
        bars
    }

    #[test]
    fn silence_is_the_floor() {
        let mut analyser = Analyser::new();
        assert_eq!(settle(&mut analyser, &[0.0; 960]), [FLOOR; BARS]);
    }

    #[test]
    fn a_tone_lights_its_own_bar() {
        // Bar i covers bins 5i..5i+5, 187.5 Hz each: 1 kHz is bin ~5, bar 1.
        let mut analyser = Analyser::new();
        let bars = settle(&mut analyser, &tone(1_000.0, 0.5, 960));
        let loudest = (0..BARS)
            .max_by(|&a, &b| bars[a].total_cmp(&bars[b]))
            .unwrap();
        assert_eq!(loudest, 1, "bars: {bars:?}");
        // Averaged over the bar's 5 bins, as the website does: well up, not full.
        assert!(bars[1] > 0.6, "bars: {bars:?}");
        assert!(bars[BARS - 1] < 0.4, "high bars stay low: {bars:?}");
    }

    #[test]
    fn a_stalled_stream_decays_instead_of_freezing() {
        let mut analyser = Analyser::new();
        let loud = settle(&mut analyser, &tone(1_000.0, 0.5, 960));
        // No more audio (the peer stopped sending): bars fall back.
        let mut bars = loud;
        for _ in 0..60 {
            bars = analyser.bars().unwrap();
        }
        assert!(bars[1] < loud[1] / 2.0, "{} then {}", loud[1], bars[1]);
    }
}
