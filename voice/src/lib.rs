//! randos's voice processors, written once (docs/architecture/refactor_plan.md,
//! Phase 5): the same code runs in the browser (compiled to WASM, inside an
//! AudioWorklet, through `wasm.rs`) and in the TUI's media helper (linked
//! natively). The voice lab renders exactly what the calls run.
//!
//! A processor takes mono `f32` samples in and writes the same number out.
//! `process` never allocates, locks, or does I/O, so it's safe on a
//! real-time audio thread.

mod lpc;
mod mcadams;
mod pitch;
#[cfg(target_arch = "wasm32")]
mod wasm;

pub use mcadams::{DELAY_SAMPLES as MCADAMS_DELAY_SAMPLES, Diagnostics, McAdams};
pub use pitch::PitchShifter;

/// The processors, by the id the browser's worklet files use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Variant {
    /// Copies its input: the seam's default, and every comparison's baseline.
    Passthrough,
    /// Shifts pitch (`PitchShifter`), formants and all.
    PitchShift,
    /// Experimental 16 kHz LPC formant warping, supported at 48 kHz only.
    McAdams,
}

impl Variant {
    /// From the processor id (`0` passthrough, `1` pitch shift, `2` McAdams).
    pub fn from_id(id: u32) -> Option<Self> {
        match id {
            0 => Some(Self::Passthrough),
            1 => Some(Self::PitchShift),
            2 => Some(Self::McAdams),
            _ => None,
        }
    }
}

/// One voice processor at a sample rate.
pub struct Processor {
    kind: Kind,
}

enum Kind {
    Passthrough,
    PitchShift(PitchShifter),
    McAdams(Box<McAdams>),
}

impl Processor {
    /// Offline approximate recovery probe; not exposed as a browser variant.
    pub fn mcadams_inverse(sample_rate: f32, forward_alpha: f32) -> Option<Self> {
        McAdams::inverse(sample_rate, forward_alpha).map(|processor| Self {
            kind: Kind::McAdams(Box::new(processor)),
        })
    }

    pub fn new(variant: Variant, sample_rate: f32) -> Self {
        let kind = match variant {
            Variant::Passthrough => Kind::Passthrough,
            Variant::PitchShift => Kind::PitchShift(PitchShifter::new(sample_rate)),
            Variant::McAdams => Kind::McAdams(Box::new(McAdams::new(sample_rate))),
        };
        Self { kind }
    }

    /// Sets parameter `index` (in the order of the variant's
    /// `parameterDescriptors` in its worklet file). Unknown indices are
    /// ignored; values are clamped to each parameter's range.
    pub fn set_param(&mut self, index: usize, value: f32) {
        match &mut self.kind {
            Kind::PitchShift(shifter) => match index {
                0 => shifter.set_semitones(value),
                1 => shifter.set_window_ms(value),
                _ => {}
            },
            Kind::McAdams(processor) if index == 0 => processor.set_alpha(value),
            _ => {}
        }
    }

    pub fn diagnostics(&self) -> Diagnostics {
        match &self.kind {
            Kind::McAdams(processor) => processor.diagnostics(),
            _ => Diagnostics::default(),
        }
    }

    /// Processes `input` into `output`, sample for sample (the shorter of
    /// the two sets the length).
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) {
        match &mut self.kind {
            Kind::Passthrough => {
                for (out, sample) in output.iter_mut().zip(input) {
                    *out = *sample;
                }
            }
            Kind::PitchShift(shifter) => shifter.process(input, output),
            Kind::McAdams(processor) => processor.process(input, output),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passthrough_copies_its_input() {
        let mut processor = Processor::new(Variant::Passthrough, 48_000.0);
        let input: Vec<f32> = (0..128).map(|i| (i as f32 * 0.1).sin()).collect();
        let mut output = vec![0.0; 128];
        processor.process(&input, &mut output);
        assert_eq!(input, output);
    }

    #[test]
    fn variants_by_id() {
        assert_eq!(Variant::from_id(0), Some(Variant::Passthrough));
        assert_eq!(Variant::from_id(1), Some(Variant::PitchShift));
        assert_eq!(Variant::from_id(2), Some(Variant::McAdams));
        assert_eq!(Variant::from_id(9), None);
    }

    #[test]
    fn inverse_factory_is_distinct_and_validates_its_known_setting() {
        assert!(Processor::mcadams_inverse(44_100.0, 0.9).is_none());
        assert!(Processor::mcadams_inverse(48_000.0, f32::NAN).is_none());
        assert!(Processor::mcadams_inverse(48_000.0, 0.0).is_none());
        let mut control = Processor::new(Variant::McAdams, 48_000.0);
        control.set_param(0, 1.0);
        let mut identity = Processor::mcadams_inverse(48_000.0, 1.0).expect("inverse identity");
        let mut inverse = Processor::mcadams_inverse(48_000.0, 0.7).expect("inverse setting");
        let input: Vec<f32> = (0..4096)
            .map(|i| ((i as f32 * 1.17).sin() + (i as f32 * 0.071).sin()) * 0.01)
            .collect();
        let mut expected = vec![0.0; input.len()];
        let mut unchanged = vec![0.0; input.len()];
        let mut recovered = vec![0.0; input.len()];
        control.process(&input, &mut expected);
        identity.process(&input, &mut unchanged);
        inverse.process(&input, &mut recovered);
        assert_eq!(unchanged, expected);
        assert!(
            recovered
                .iter()
                .zip(expected)
                .any(|(a, b)| (a - b).abs() > 1e-4)
        );
        assert!(recovered.iter().all(|sample| sample.is_finite()));
    }
}
