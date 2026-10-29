//! Worker-side voice path. Connection/mute eligibility precedes buffered DSP.
use randos_voice::{Processor, Variant};
use randos_voice_native::{Masker, Style};

use crate::{Error, codec::FRAME};

pub struct Voice {
    legacy: Processor,
    native: Option<Box<Masker>>,
    eligible: bool,
}

impl Voice {
    pub fn new(variant: Variant, params: &[f32], mask: Option<Style>) -> Result<Self, Error> {
        if mask.is_some() && (variant != Variant::Passthrough || !params.is_empty()) {
            return Err("choose either native masking or the legacy voice processor".into());
        }
        let mut legacy = Processor::new(variant, crate::codec::SAMPLE_RATE as f32);
        for (index, value) in params.iter().enumerate() {
            legacy.set_param(index, *value);
        }
        Ok(Self {
            legacy,
            native: mask.map(Masker::new).transpose()?.map(Box::new),
            eligible: false,
        })
    }

    /// Returns true when the native gate opens: the caller must discard stale
    /// capture/resampler data too. Closing purges all native history immediately,
    /// including when mute/unmute commands arrive between capture frames.
    pub fn set_eligible(&mut self, eligible: bool) -> Result<bool, Error> {
        let opening = !self.eligible && eligible && self.native.is_some();
        let closing = self.eligible && !eligible;
        self.eligible = eligible;
        if closing && let Some(native) = &mut self.native {
            native.reset()?;
        }
        Ok(opening)
    }

    pub fn process(
        &mut self,
        input: &[f32; FRAME],
        output: &mut [f32; FRAME],
    ) -> Result<(), Error> {
        output.fill(0.0);
        match &mut self.native {
            Some(native) if self.eligible => {
                // Same fixed headroom as the browser live DSP path, outside the
                // raw core. No loudness normalization or fallback to dry audio.
                let scaled = input.map(|sample| sample * 0.25);
                native.process(&scaled, output)?;
            }
            Some(_) => {} // No pre-connection or muted input reaches the DSP.
            None => self.legacy.process(input, output),
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(frame: usize, hz: f32) -> [f32; FRAME] {
        std::array::from_fn(|i| {
            ((frame * FRAME + i) as f32 * hz * std::f32::consts::TAU / 48000.0).sin() * 0.2
        })
    }

    #[test]
    fn preconnection_muted_and_disconnected_sentinels_never_reappear() {
        for style in [
            Style::LowerResonance,
            Style::LowerResonancePitch,
            Style::HigherResonance,
            Style::HigherResonancePitch,
        ] {
            let mut voice = Voice::new(Variant::Passthrough, &[], Some(style)).unwrap();
            let mut output = [0.0; FRAME];
            for i in 0..30 {
                voice.process(&tone(i, 1200.0), &mut output).unwrap();
                assert_eq!(output, [0.0; FRAME]);
            }
            for _ in 0..3 {
                assert!(voice.set_eligible(true).unwrap());
                let mut fresh = Voice::new(Variant::Passthrough, &[], Some(style)).unwrap();
                fresh.set_eligible(true).unwrap();
                for i in 0..40 {
                    let mut expected = [0.0; FRAME];
                    voice.process(&tone(i, 220.0), &mut output).unwrap();
                    fresh.process(&tone(i, 220.0), &mut expected).unwrap();
                    assert_eq!(output, expected, "old speech leaked at frame {i}");
                }
                voice.set_eligible(false).unwrap();
                for i in 0..19 {
                    voice.process(&tone(i, 880.0), &mut output).unwrap();
                    assert_eq!(output, [0.0; FRAME]);
                }
                // A quick reopen/close without a frame still purges history.
                voice.set_eligible(true).unwrap();
                voice.set_eligible(false).unwrap();
            }
        }
    }

    #[test]
    fn native_and_legacy_processors_cannot_accidentally_stack() {
        assert!(Voice::new(Variant::PitchShift, &[], Some(Style::LowerResonance)).is_err());
        assert!(Voice::new(Variant::Passthrough, &[0.0], Some(Style::LowerResonance)).is_err());
        let mut off = Voice::new(Variant::Passthrough, &[], None).unwrap();
        assert!(!off.set_eligible(true).unwrap());
        let input = tone(0, 440.0);
        let mut output = [0.0; FRAME];
        off.process(&input, &mut output).unwrap();
        assert_eq!(input, output);
    }

    #[test]
    fn live_headroom_matches_browser_policy_and_loud_transients_stay_bounded() {
        for style in [
            Style::LowerResonance,
            Style::LowerResonancePitch,
            Style::HigherResonance,
            Style::HigherResonancePitch,
        ] {
            let mut voice = Voice::new(Variant::Passthrough, &[], Some(style)).unwrap();
            voice.set_eligible(true).unwrap();
            let mut reference = Masker::new(style).unwrap();
            for i in 0..60 {
                let mut input = tone(i, 220.0);
                if i == 6 {
                    input[0] = 1.0;
                }
                let mut actual = [0.0; FRAME];
                let mut expected = [0.0; FRAME];
                voice.process(&input, &mut actual).unwrap();
                reference
                    .process(&input.map(|x| x * 0.25), &mut expected)
                    .unwrap();
                assert_eq!(actual, expected);
                assert!(actual.iter().all(|x| x.abs() <= 1.0));
            }
            let mut stopped = false;
            for i in 0..60 {
                let mut output = [1.0; FRAME];
                if voice
                    .process(&tone(i, 220.0).map(|x| x * 10000.0), &mut output)
                    .is_err()
                {
                    assert!(output.iter().all(|x| *x == 0.0));
                    assert!(voice.process(&[0.0; FRAME], &mut output).is_err());
                    stopped = true;
                    break;
                }
            }
            assert!(
                stopped,
                "over-range audio must stop, never clip or pass dry"
            );
        }
    }
}
