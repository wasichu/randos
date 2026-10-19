//! Opus encode → decode at 48 kHz mono in 20 ms frames: the loopback's codec
//! stage. It knows nothing about audio devices, so `cargo test` covers it.

use opus::{Application, Bitrate, Channels, Decoder, Encoder};

use crate::Error;

/// Opus doesn't accept 44.1 kHz; until Stage 2 adds resampling, devices must
/// run at this rate.
pub const SAMPLE_RATE: u32 = 48_000;
/// Samples in one 20 ms frame at `SAMPLE_RATE`.
pub const FRAME: usize = 960;
/// Voice at this rate measured −14.9 dB SNR in the design research.
pub const BITRATE_BPS: i32 = 24_000;
/// libopus's recommended upper bound for one packet.
const MAX_PACKET: usize = 4_000;

pub struct OpusLoop {
    encoder: Encoder,
    decoder: Decoder,
    packet: [u8; MAX_PACKET],
}

impl OpusLoop {
    pub fn new() -> Result<Self, Error> {
        let mut encoder = Encoder::new(SAMPLE_RATE, Channels::Mono, Application::Voip)?;
        encoder.set_bitrate(Bitrate::Bits(BITRATE_BPS))?;
        let decoder = Decoder::new(SAMPLE_RATE, Channels::Mono)?;

        Ok(Self {
            encoder,
            decoder,
            packet: [0; MAX_PACKET],
        })
    }

    /// Encodes one frame and decodes it back into `output`. Returns the Opus
    /// packet size in bytes.
    pub fn process(
        &mut self,
        input: &[f32; FRAME],
        output: &mut [f32; FRAME],
    ) -> Result<usize, Error> {
        let len = self.encoder.encode_float(input, &mut self.packet)?;
        let packet = self
            .packet
            .get(..len)
            .ok_or("opus packet overran its buffer")?;
        let decoded = self.decoder.decode_float(packet, output, false)?;

        if decoded == FRAME {
            Ok(len)
        } else {
            Err(format!("opus decoded {decoded} samples, expected {FRAME}").into())
        }
    }
}

/// A test tone source for `--in sine`.
pub struct Sine {
    phase: f32,
    step: f32,
}

impl Sine {
    pub fn new(hz: f32) -> Self {
        Self {
            phase: 0.0,
            step: std::f32::consts::TAU * hz / SAMPLE_RATE as f32,
        }
    }

    pub fn fill(&mut self, frame: &mut [f32]) {
        for sample in frame {
            *sample = 0.5 * self.phase.sin();
            self.phase = (self.phase + self.step) % std::f32::consts::TAU;
        }
    }
}

pub fn rms(samples: &[f32]) -> f32 {
    let sum: f32 = samples.iter().map(|s| s * s).sum();
    (sum / samples.len().max(1) as f32).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tone_survives_the_round_trip() {
        let mut codec = OpusLoop::new().unwrap();
        let mut sine = Sine::new(440.0);
        let (mut input, mut output) = ([0.0; FRAME], [0.0; FRAME]);

        // Opus has ~6.5 ms of lookahead, so judge a frame after it settles.
        for _ in 0..10 {
            sine.fill(&mut input);
            let bytes = codec.process(&input, &mut output).unwrap();
            assert!(
                bytes > 0 && bytes < 200,
                "24 kbps is ~60 bytes per frame, got {bytes}"
            );
        }

        let ratio_db = 20.0 * (rms(&output) / rms(&input)).log10();
        assert!(ratio_db.abs() < 3.0, "level changed by {ratio_db} dB");
    }

    #[test]
    fn silence_stays_silent() {
        let mut codec = OpusLoop::new().unwrap();
        let mut output = [1.0; FRAME];

        for _ in 0..5 {
            codec.process(&[0.0; FRAME], &mut output).unwrap();
        }

        assert!(rms(&output) < 1e-3);
    }
}
