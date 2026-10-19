//! Converts one 20 ms frame between a device's sample rate and Opus's
//! 48 kHz. Opus can't take 44.1 kHz, the usual rate of Bluetooth headphones
//! in music (A2DP) mode, so the loopback (and later the call) resamples at
//! the device edges. Runs on the worker thread, never in a cpal callback.
//!
//! rubato's FFT resampler with both sides fixed: every frame in yields
//! exactly one frame out, so the pipeline stays frame-aligned.

use rubato::audioadapter_buffers::direct::InterleavedSlice;
use rubato::{Fft, FixedSync, Resampler};

use crate::Error;

/// Frames per 20 ms at `rate`, if that's a whole number.
pub fn frame_len(rate: u32) -> Option<usize> {
    rate.is_multiple_of(50).then_some((rate / 50) as usize)
}

pub struct FrameResampler {
    fft: Option<Fft<f32>>,
    input_len: usize,
    output_len: usize,
}

impl FrameResampler {
    /// A mono resampler from `from` Hz to `to` Hz in 20 ms frames; a plain
    /// copy when the rates match.
    pub fn new(from: u32, to: u32) -> Result<Self, Error> {
        let input_len =
            frame_len(from).ok_or_else(|| format!("{from} Hz has no whole 20 ms frame"))?;
        let output_len =
            frame_len(to).ok_or_else(|| format!("{to} Hz has no whole 20 ms frame"))?;

        if from == to {
            return Ok(Self {
                fft: None,
                input_len,
                output_len,
            });
        }

        let fft = Fft::new(from as usize, to as usize, input_len, 1, FixedSync::Both)?;
        if fft.input_frames_next() != input_len || fft.output_frames_next() != output_len {
            return Err(format!(
                "resampler chose {}→{} frames for {from}→{to} Hz, expected {input_len}→{output_len}",
                fft.input_frames_next(),
                fft.output_frames_next()
            )
            .into());
        }

        Ok(Self {
            fft: Some(fft),
            input_len,
            output_len,
        })
    }

    pub fn input_len(&self) -> usize {
        self.input_len
    }

    pub fn output_len(&self) -> usize {
        self.output_len
    }

    /// The delay this resampler adds, in milliseconds.
    pub fn delay_ms(&self) -> f64 {
        self.fft.as_ref().map_or(0.0, |fft| {
            fft.output_delay() as f64 * 20.0 / self.output_len as f64
        })
    }

    /// Resamples `input` (`input_len` samples) into `output` (`output_len`).
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        let (input, output) = (
            input
                .get(..self.input_len)
                .ok_or("resampler input too short")?,
            output
                .get_mut(..self.output_len)
                .ok_or("resampler output too short")?,
        );

        match &mut self.fft {
            None => output.copy_from_slice(input),
            Some(fft) => {
                let source = InterleavedSlice::new(input, 1, self.input_len)?;
                let mut target = InterleavedSlice::new_mut(output, 1, self.output_len)?;
                fft.process_into_buffer(&source, &mut target, None)?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codec::{Sine, rms};

    #[test]
    fn frame_lengths() {
        assert_eq!(frame_len(48_000), Some(960));
        assert_eq!(frame_len(44_100), Some(882));
        assert_eq!(frame_len(16_000), Some(320));
        assert_eq!(frame_len(11_025), None);
    }

    #[test]
    fn same_rate_is_a_copy() {
        let mut resampler = FrameResampler::new(48_000, 48_000).unwrap();
        let input: Vec<f32> = (0..960).map(|i| i as f32).collect();
        let mut output = vec![0.0; 960];
        resampler.process(&input, &mut output).unwrap();
        assert_eq!(input, output);
        assert_eq!(resampler.delay_ms(), 0.0);
    }

    #[test]
    fn bluetooth_rates_round_trip_frame_for_frame_and_keep_the_level() {
        for rate in [44_100, 16_000, 32_000, 96_000] {
            let mut down = FrameResampler::new(48_000, rate).unwrap();
            let mut up = FrameResampler::new(rate, 48_000).unwrap();
            assert_eq!(
                (down.input_len(), down.output_len()),
                (960, frame_len(rate).unwrap())
            );

            let mut sine = Sine::new(440.0);
            let (mut frame, mut device, mut back) =
                (vec![0.0; 960], vec![0.0; down.output_len()], vec![0.0; 960]);

            // Let the FFT overlap fill before judging the level.
            for _ in 0..10 {
                sine.fill(&mut frame);
                down.process(&frame, &mut device).unwrap();
                up.process(&device, &mut back).unwrap();
            }

            let ratio_db = 20.0 * (rms(&back) / rms(&frame)).log10();
            assert!(
                ratio_db.abs() < 1.0,
                "{rate} Hz changed the level by {ratio_db} dB"
            );
            assert!(
                down.delay_ms() < 15.0,
                "{rate} Hz adds {} ms",
                down.delay_ms()
            );
        }
    }
}
