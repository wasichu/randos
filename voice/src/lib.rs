//! randos's voice processors, written once (docs/architecture/refactor_plan.md,
//! Phase 5): the same code runs in the browser (compiled to WASM, inside an
//! AudioWorklet, through `wasm.rs`) and in the TUI's media helper (linked
//! natively). The voice lab renders exactly what the calls run.
//!
//! A processor takes mono `f32` samples in and writes the same number out.
//! `process` never allocates, locks, or does I/O, so it's safe on a
//! real-time audio thread.

mod pitch;
#[cfg(target_arch = "wasm32")]
mod wasm;

pub use pitch::PitchShifter;

/// The processors, by the id the browser's worklet files use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Variant {
    /// Copies its input: the seam's default, and every comparison's baseline.
    Passthrough,
    /// Shifts pitch (`PitchShifter`), formants and all.
    PitchShift,
}

impl Variant {
    /// From the id the worklet files use (`0` passthrough, `1` pitch shift).
    pub fn from_id(id: u32) -> Option<Self> {
        match id {
            0 => Some(Self::Passthrough),
            1 => Some(Self::PitchShift),
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
}

impl Processor {
    pub fn new(variant: Variant, sample_rate: f32) -> Self {
        let kind = match variant {
            Variant::Passthrough => Kind::Passthrough,
            Variant::PitchShift => Kind::PitchShift(PitchShifter::new(sample_rate)),
        };
        Self { kind }
    }

    /// Sets parameter `index` (in the order of the variant's
    /// `parameterDescriptors` in its worklet file). Unknown indices are
    /// ignored; values are clamped to each parameter's range.
    pub fn set_param(&mut self, index: usize, value: f32) {
        if let Kind::PitchShift(shifter) = &mut self.kind {
            match index {
                0 => shifter.set_semitones(value),
                1 => shifter.set_window_ms(value),
                _ => {}
            }
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
        assert_eq!(Variant::from_id(9), None);
    }
}
