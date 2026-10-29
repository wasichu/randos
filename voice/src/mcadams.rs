//! Experimental causal McAdams adaptation: 48 kHz -> anti-aliased 16 kHz,
//! LPC pole-angle warping on 20 ms frames / 10 ms hops, normalized overlap
//! add, then interpolation to 48 kHz. Alpha=1 is the matched bandwidth and
//! overlap-add control (bypasses LPC). This is not a promise of anonymity.
use crate::lpc::{self, ORDER};
use std::f64::consts::PI;

const FRAME: usize = 320;
const HOP: usize = FRAME / 2;
const TAPS: usize = 63;
/// Frame buffering plus two linear-phase FIRs, at 48 kHz.
pub const DELAY_SAMPLES: usize = FRAME * 3 + TAPS - 1;
pub const ALPHA_RANGE: (f32, f32) = (0.5, 1.0);
pub const DEFAULT_ALPHA: f32 = 0.8;

#[derive(Clone, Copy, Default, Debug)]
pub struct Diagnostics {
    pub frames: u64,
    pub failed_frames: u64,
    pub clipped_samples: u64,
    pub corrected_poles: u64,
    pub corrected_frames: u64,
}

struct Fir {
    coefficients: [f64; TAPS],
    history: [f64; TAPS],
    write: usize,
}
impl Fir {
    fn new() -> Self {
        // Blackman-windowed sinc: 6 kHz pass region, >60 dB rejection at
        // 8 kHz, the decimated Nyquist boundary. Both controls use it.
        let mut coefficients = std::array::from_fn(|i| {
            let position = i as f64 - (TAPS - 1) as f64 / 2.0;
            let sinc = if position.abs() < 1e-12 {
                0.25
            } else {
                (0.25 * PI * position).sin() / (PI * position)
            };
            let angle = std::f64::consts::TAU * i as f64 / (TAPS - 1) as f64;
            sinc * (0.42 - 0.5 * angle.cos() + 0.08 * (2.0 * angle).cos())
        });
        let sum: f64 = coefficients.iter().sum();
        for coefficient in &mut coefficients {
            *coefficient /= sum;
        }
        Self {
            coefficients,
            history: [0.0; TAPS],
            write: 0,
        }
    }
    fn push(&mut self, input: f64) -> f64 {
        if let Some(slot) = self.history.get_mut(self.write) {
            *slot = input;
        }
        let result = self
            .coefficients
            .iter()
            .enumerate()
            .map(|(lag, coefficient)| {
                coefficient * lpc::at(&self.history, (self.write + TAPS - lag) % TAPS)
            })
            .sum();
        self.write = (self.write + 1) % TAPS;
        result
    }
}

pub struct McAdams {
    valid_rate: bool,
    alpha: f64,
    inverse_alpha: Option<f64>,
    down: Fir,
    up: Fir,
    phase: usize,
    input: [f64; FRAME],
    filled: usize,
    window: [f64; FRAME],
    overlap: [f64; FRAME],
    weights: [f64; FRAME],
    output: [f64; HOP],
    output_at: usize,
    diagnostics: Diagnostics,
}

impl McAdams {
    pub fn new(sample_rate: f32) -> Self {
        Self {
            valid_rate: (sample_rate - 48_000.0).abs() < 0.1,
            alpha: f64::from(DEFAULT_ALPHA),
            inverse_alpha: None,
            down: Fir::new(),
            up: Fir::new(),
            phase: 0,
            input: [0.0; FRAME],
            filled: 0,
            window: std::array::from_fn(|i| (PI * (i as f64 + 0.5) / FRAME as f64).sin()),
            overlap: [0.0; FRAME],
            weights: [0.0; FRAME],
            output: [0.0; HOP],
            output_at: HOP,
            diagnostics: Diagnostics::default(),
        }
    }
    pub fn set_alpha(&mut self, alpha: f32) {
        if alpha.is_finite() {
            self.alpha = f64::from(alpha.clamp(ALPHA_RANGE.0, ALPHA_RANGE.1));
            self.inverse_alpha = None;
        }
    }
    /// Offline research only: reestimate LPC from the disguised waveform
    /// and attempt its known setting's inverse. No original signal is used.
    pub fn inverse(sample_rate: f32, forward_alpha: f32) -> Option<Self> {
        if !forward_alpha.is_finite() || !(ALPHA_RANGE.0..=ALPHA_RANGE.1).contains(&forward_alpha) {
            return None;
        }
        let mut processor = Self::new(sample_rate);
        if !processor.valid_rate {
            return None;
        }
        processor.inverse_alpha = Some(f64::from(forward_alpha));
        Some(processor)
    }
    pub fn diagnostics(&self) -> Diagnostics {
        self.diagnostics
    }
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) {
        if !self.valid_rate {
            output.fill(0.0);
            self.diagnostics.failed_frames += 1;
            return;
        }
        for (sample, out) in input.iter().zip(output) {
            let low = self.down.push(f64::from(*sample));
            self.phase = (self.phase + 1) % 3;
            let impulse = if self.phase == 0 {
                self.push_low(low) * 3.0
            } else {
                0.0
            };
            let value = self.up.push(impulse);
            if value.abs() > 1.0 {
                self.diagnostics.clipped_samples += 1;
            }
            *out = value.clamp(-1.0, 1.0) as f32;
        }
    }
    fn push_low(&mut self, input: f64) -> f64 {
        let output = self.output.get(self.output_at).copied().unwrap_or(0.0);
        self.output_at = self.output_at.saturating_add(1);
        if let Some(slot) = self.input.get_mut(self.filled) {
            *slot = input;
        }
        self.filled += 1;
        if self.filled == FRAME {
            self.frame();
            self.input.copy_within(HOP.., 0);
            self.filled = HOP;
            for (i, output) in self.output.iter_mut().enumerate() {
                let weight = lpc::at(&self.weights, i);
                *output = if weight > 1e-12 {
                    lpc::at(&self.overlap, i) / weight
                } else {
                    0.0
                };
            }
            self.overlap.copy_within(HOP.., 0);
            self.weights.copy_within(HOP.., 0);
            for value in self.overlap.iter_mut().skip(HOP) {
                *value = 0.0;
            }
            for value in self.weights.iter_mut().skip(HOP) {
                *value = 0.0;
            }
            self.output_at = 0;
        }
        output
    }
    fn frame(&mut self) {
        self.diagnostics.frames += 1;
        let frame = std::array::from_fn::<_, FRAME, _>(|i| {
            lpc::at(&self.input, i) * lpc::at(&self.window, i)
        });
        let energy: f64 = frame.iter().map(|value| value * value).sum();
        let rendered = if energy < 1e-20 {
            Some([0.0; FRAME])
        } else if (self.inverse_alpha.unwrap_or(self.alpha) - 1.0).abs() < 1e-8 {
            // Exact identity transform; this is the resampling/OLA control.
            Some(frame)
        } else {
            lpc::coefficients(&frame).and_then(|a| {
                let b = if let Some(alpha) = self.inverse_alpha {
                    lpc::inverse(&a, alpha).map(|(b, corrected)| {
                        self.diagnostics.corrected_poles += corrected as u64;
                        self.diagnostics.corrected_frames += u64::from(corrected > 0);
                        b
                    })
                } else {
                    lpc::warp(&a, self.alpha)
                }?;
                synthesize(&frame, &a, &b)
            })
        };
        let rendered = rendered.unwrap_or_else(|| {
            self.diagnostics.failed_frames += 1;
            [0.0; FRAME] // Never fall back to revealing the unmodified frame.
        });
        for (i, ((overlap, weight), window)) in self
            .overlap
            .iter_mut()
            .zip(&mut self.weights)
            .zip(self.window)
            .enumerate()
        {
            *overlap += lpc::at(&rendered, i) * window;
            *weight += window * window;
        }
    }
}

fn synthesize(
    frame: &[f64; FRAME],
    a: &lpc::Coefficients,
    b: &lpc::Coefficients,
) -> Option<[f64; FRAME]> {
    let mut output = [0.0; FRAME];
    for (i, sample) in frame.iter().enumerate() {
        let mut value = *sample;
        for lag in 1..=ORDER.min(i) {
            value += lpc::at(a, lag) * lpc::at(frame, i - lag)
                - lpc::at(b, lag) * lpc::at(&output, i - lag);
        }
        if !value.is_finite() || value.abs() > 16.0 {
            return None;
        }
        if let Some(slot) = output.get_mut(i) {
            *slot = value;
        }
    }
    Some(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lpc_analysis_and_identity_warp_reconstruct_a_frame() {
        let mut state = 13_u32;
        let frame = std::array::from_fn(|_| {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (f64::from(state) / f64::from(u32::MAX) - 0.5) * 0.05
        });
        let a = lpc::coefficients(&frame).expect("finite analysis");
        let b = lpc::warp(&a, 1.0).expect("identity roots converge");
        let reconstructed = synthesize(&frame, &a, &b).expect("stable identity synthesis");
        let worst = frame
            .iter()
            .zip(reconstructed)
            .map(|(a, b)| (a - b).abs())
            .fold(0.0_f64, f64::max);
        assert!(worst < 1e-6, "identity error {worst}");
    }
    fn run(input: &[f32], alpha: f32, chunk: usize) -> (Vec<f32>, Diagnostics) {
        let mut processor = McAdams::new(48_000.0);
        processor.set_alpha(alpha);
        let mut output = vec![0.0; input.len()];
        for (input, output) in input.chunks(chunk).zip(output.chunks_mut(chunk)) {
            processor.process(input, output);
        }
        (output, processor.diagnostics())
    }
    #[test]
    fn matched_control_reconstructs_with_declared_delay_and_any_chunks() {
        let mut input: Vec<f32> = (0..12_000)
            .map(|i| (std::f32::consts::TAU * 210.0 * i as f32 / 48_000.0).sin() * 0.1)
            .collect();
        input.extend(vec![0.0; 2048]);
        let (output, diagnostics) = run(&input, 1.0, 128);
        assert_eq!(diagnostics.failed_frames, 0);
        let (other, _) = run(&input, 1.0, 71);
        assert_eq!(output, other);
        let error: f64 = output
            .iter()
            .skip(DELAY_SAMPLES + 100)
            .zip(input.iter().skip(100))
            .take(11_000)
            .map(|(a, b)| f64::from(a - b).powi(2))
            .sum::<f64>()
            / 11_000.0;
        assert!(error.sqrt() < 0.003, "identity RMS error {}", error.sqrt());
    }
    #[test]
    fn flushing_preserves_speech_at_the_end_of_a_clip() {
        let length = 4096;
        let mut input = vec![0.0; length + DELAY_SAMPLES];
        input[length - 32] = 0.5;
        let (output, diagnostics) = run(&input, 1.0, 128);
        assert_eq!(diagnostics.failed_frames, 0);
        let aligned = &output[DELAY_SAMPLES..DELAY_SAMPLES + length];
        let peak = aligned
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.abs().total_cmp(&b.abs()))
            .expect("nonempty aligned output");
        assert_eq!(peak.0, length - 32);
        assert!(peak.1.abs() > 0.05, "final impulse was lost");
    }
    #[test]
    fn silence_and_noise_are_finite_and_failures_are_observable() {
        let mut state = 7_u32;
        let input: Vec<f32> = (0..12_000)
            .map(|_| {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (state as f32 / u32::MAX as f32 - 0.5) * 0.05
            })
            .collect();
        let (output, diagnostics) = run(&input, 0.8, 128);
        assert!(
            output
                .iter()
                .all(|value| value.is_finite() && value.abs() <= 1.0)
        );
        assert!(
            diagnostics.failed_frames < diagnostics.frames / 10,
            "{diagnostics:?}"
        );
        let (silence, diagnostics) = run(&vec![0.0; 4096], 0.8, 128);
        assert!(silence.iter().all(|value| value.abs() < 1e-12));
        assert_eq!(diagnostics.failed_frames, 0);
        let mut unsupported = McAdams::new(44_100.0);
        let mut output = [1.0; 128];
        unsupported.process(&[1.0; 128], &mut output);
        assert_eq!(output, [0.0; 128]);
        assert_eq!(unsupported.diagnostics().failed_frames, 1);
    }
    #[test]
    fn formant_processing_preserves_excitation_periodicity() {
        let input: Vec<f32> = (0..24_000)
            .map(|i| if i % 240 == 0 { 0.2 } else { 0.0 })
            .collect();
        let (output, diagnostics) = run(&input, 0.8, 128);
        assert_eq!(diagnostics.failed_frames, 0, "{diagnostics:?}");
        let settled = &output[4096..];
        let correlation = |lag: usize| {
            settled
                .iter()
                .skip(lag)
                .zip(settled)
                .map(|(a, b)| a * b)
                .sum::<f32>()
        };
        let lag = (200..280)
            .max_by(|a, b| correlation(*a).total_cmp(&correlation(*b)))
            .expect("nonempty lags");
        assert!(
            (lag as i32 - 240).abs() <= 1,
            "excitation moved to lag {lag}"
        );
    }

    #[test]
    fn anti_alias_filter_rejects_the_decimated_nyquist_boundary() {
        let fir = Fir::new();
        let magnitude = |hz: f64| {
            let (re, im) =
                fir.coefficients
                    .iter()
                    .enumerate()
                    .fold((0.0, 0.0), |(re, im), (i, c)| {
                        let angle = std::f64::consts::TAU * hz * i as f64 / 48_000.0;
                        (re + c * angle.cos(), im + c * angle.sin())
                    });
            re.hypot(im)
        };
        assert!((magnitude(1000.0) - 1.0).abs() < 0.01);
        assert!(magnitude(8000.0) < 0.001);
    }
}
