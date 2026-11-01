//! Native Signalsmith, with an owned FFI boundary and bounded 20 ms adapter.
//! DSP runs on the media worker, never a cpal device callback.
#![deny(unsafe_code)]

mod ffi;
pub use ffi::Engine;

pub const FRAME: usize = 960;
pub const BATCH: usize = 3840;
pub const CORE_DELAY: usize = 3840;
const PREFILL: usize = BATCH;
/// Returned-frame offset; first delivery at 160 ms includes a capture frame.
/// Core crop and prefill overlap with batching; do not sum a second frame delay.
pub const FRAME_PREFIX_SAMPLES: usize = CORE_DELAY + PREFILL - FRAME;
const CAPACITY: usize = BATCH * 4;

/// Two candidate style families, each with a lower/higher direction. These
/// internal names are not product copy or a claim of anonymity.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Style {
    LowerResonance,
    LowerResonancePitch,
    HigherResonance,
    HigherResonancePitch,
}

impl Style {
    pub fn parse(value: &str) -> Result<Self, Error> {
        match value {
            "lower_resonance" => Ok(Self::LowerResonance),
            "lower_resonance_pitch" => Ok(Self::LowerResonancePitch),
            "higher_resonance" => Ok(Self::HigherResonance),
            "higher_resonance_pitch" => Ok(Self::HigherResonancePitch),
            _ => Err(Error::Input),
        }
    }
    pub const fn settings(self) -> (f64, f64) {
        match self {
            Self::LowerResonance => (0.0, 0.8),
            Self::LowerResonancePitch => (-1.0, 0.8),
            Self::HigherResonance => (0.0, 1.25),
            Self::HigherResonancePitch => (1.0, 1.25),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    Native,
    Input,
    Queue,
    Failed,
    Level,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Native => "native voice processor failed",
            Self::Input => "invalid voice processor input",
            Self::Queue => "voice processor queue failed",
            Self::Failed => "voice processor has stopped",
            Self::Level => "voice processor output exceeded its audio range",
        })
    }
}
impl std::error::Error for Error {}

/// 960-sample ingress/egress around unchanged 3,840-sample core calls. Startup
/// emits silence. Once primed, output stays contiguous; a fault permanently
/// stops processing until an explicit reset succeeds. No dry fallback.
pub struct Masker {
    engine: Engine,
    style: Style,
    input: [f32; BATCH],
    fill: usize,
    queue: [f32; CAPACITY],
    head: usize,
    length: usize,
    skip: usize,
    primed: bool,
    failed: bool,
}

impl Masker {
    pub fn new(style: Style) -> Result<Self, Error> {
        Ok(Self {
            engine: Engine::new(style)?,
            style,
            input: [0.0; BATCH],
            fill: 0,
            queue: [0.0; CAPACITY],
            head: 0,
            length: 0,
            skip: CORE_DELAY,
            primed: false,
            failed: false,
        })
    }

    /// Purges the partial batch, output queue and native analysis history.
    /// May allocate/reinitialize on the worker; never called from a callback.
    pub fn reset(&mut self) -> Result<(), Error> {
        self.failed = true;
        self.input.fill(0.0);
        self.queue.fill(0.0);
        self.fill = 0;
        self.head = 0;
        self.length = 0;
        self.skip = CORE_DELAY;
        self.primed = false;
        self.engine = Engine::new(self.style)?;
        self.failed = false;
        Ok(())
    }

    pub fn process(
        &mut self,
        input: &[f32; FRAME],
        output: &mut [f32; FRAME],
    ) -> Result<(), Error> {
        output.fill(0.0);
        if self.failed {
            return Err(Error::Failed);
        }
        let result = self.process_inner(input, output);
        if result.is_err() {
            self.failed = true;
            output.fill(0.0);
        }
        result
    }

    fn process_inner(
        &mut self,
        input: &[f32; FRAME],
        output: &mut [f32; FRAME],
    ) -> Result<(), Error> {
        if !input.iter().all(|x| x.is_finite()) {
            return Err(Error::Input);
        }
        self.input
            .get_mut(self.fill..self.fill + FRAME)
            .ok_or(Error::Queue)?
            .copy_from_slice(input);
        self.fill += FRAME;
        if self.fill == BATCH {
            let mut block = [0.0; BATCH];
            self.engine.process(&self.input, &mut block)?;
            self.fill = 0;
            let cut = self.skip.min(BATCH);
            self.skip -= cut;
            for &sample in block.get(cut..).ok_or(Error::Queue)? {
                if sample.abs() > 1.0 {
                    return Err(Error::Level);
                }
                if self.length == CAPACITY {
                    return Err(Error::Queue);
                }
                *self
                    .queue
                    .get_mut((self.head + self.length) % CAPACITY)
                    .ok_or(Error::Queue)? = sample;
                self.length += 1;
            }
        }
        if !self.primed && self.length >= PREFILL {
            self.primed = true;
        }
        if self.primed {
            if self.length < FRAME {
                return Err(Error::Queue);
            }
            for sample in output {
                *sample = *self.queue.get(self.head).ok_or(Error::Queue)?;
                self.head = (self.head + 1) % CAPACITY;
                self.length -= 1;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signal(frame: usize, frequency: f32) -> [f32; FRAME] {
        std::array::from_fn(|i| {
            ((frame * FRAME + i) as f32 * frequency * std::f32::consts::TAU / 48000.0).sin() * 0.2
        })
    }

    #[test]
    fn instances_and_reset_have_independent_analysis_and_queues() {
        let mut used = Masker::new(Style::LowerResonancePitch).unwrap();
        let mut reference = Masker::new(Style::LowerResonancePitch).unwrap();
        let mut output = [0.0; FRAME];
        for i in 0..37 {
            used.process(&signal(i, 880.0), &mut output).unwrap();
        }
        used.reset().unwrap();
        for i in 0..60 {
            let mut expected = [0.0; FRAME];
            used.process(&signal(i, 220.0), &mut output).unwrap();
            reference.process(&signal(i, 220.0), &mut expected).unwrap();
            assert_eq!(output, expected, "frame {i}");
            if i < FRAME_PREFIX_SAMPLES / FRAME {
                assert!(output.iter().all(|x| *x == 0.0));
            }
        }
        assert!(output.iter().any(|x| x.abs() > 0.01));
    }

    #[test]
    fn first_output_arrives_on_eighth_capture_frame_and_stays_contiguous() {
        for style in [
            Style::LowerResonance,
            Style::LowerResonancePitch,
            Style::HigherResonance,
            Style::HigherResonancePitch,
        ] {
            let mut masker = Masker::new(style).unwrap();
            let mut output = [0.; FRAME];
            for frame in 0..100 {
                masker.process(&signal(frame, 220.), &mut output).unwrap();
                if frame < 7 {
                    assert!(output.iter().all(|v| *v == 0.));
                } else {
                    assert!(
                        output.iter().any(|v| v.abs() > 0.001),
                        "missing frame {frame}"
                    );
                }
            }
        }
    }

    #[test]
    fn invalid_input_silences_and_stops_until_reset() {
        let mut masker = Masker::new(Style::HigherResonance).unwrap();
        let mut output = [1.0; FRAME];
        assert_eq!(
            masker.process(&[f32::NAN; FRAME], &mut output),
            Err(Error::Input)
        );
        assert!(output.iter().all(|x| *x == 0.0));
        assert_eq!(
            masker.process(&[0.0; FRAME], &mut output),
            Err(Error::Failed)
        );
        masker.reset().unwrap();
        masker.process(&[0.0; FRAME], &mut output).unwrap();
    }

    #[test]
    fn engine_rejects_length_mismatch_and_stops_after_finite_finish() {
        let mut engine = Engine::new(Style::LowerResonance).unwrap();
        let mut short = [1.0; 12];
        assert_eq!(engine.process(&[0.0; 13], &mut short), Err(Error::Input));
        assert_eq!(short, [0.0; 12]);
        let mut engine = Engine::new(Style::HigherResonancePitch).unwrap();
        engine.finish(&mut [0.0; 1920]).unwrap();
        assert_eq!(engine.process(&[0.0; 12], &mut short), Err(Error::Failed));
    }
}
