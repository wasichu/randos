//! Opus at 48 kHz mono in 20 ms frames: an `Encoder` (mic → network) and a
//! `Decoder` (network → speaker), used by the call and, back to back, by the
//! loopback. They know nothing about audio devices, so `cargo test` covers
//! them.

use opus::{Application, Bitrate, Channels};

use crate::Error;

/// Opus's rate; devices at other rates are resampled (`resample`).
pub const SAMPLE_RATE: u32 = 48_000;
/// Samples in one 20 ms frame at `SAMPLE_RATE`.
pub const FRAME: usize = 960;
/// Voice at this rate measured −14.9 dB SNR in the design research.
pub const BITRATE_BPS: i32 = 24_000;
/// libopus's recommended upper bound for one packet.
const MAX_PACKET: usize = 4_000;
/// A whole 20 ms frame is buffered before encoding, plus 6.5 ms of Opus
/// lookahead.
pub const CODEC_DELAY_MS: f64 = 26.5;

pub struct Encoder {
    opus: opus::Encoder,
    packet: [u8; MAX_PACKET],
}

impl Encoder {
    pub fn new() -> Result<Self, Error> {
        let mut opus = opus::Encoder::new(SAMPLE_RATE, Channels::Mono, Application::Voip)?;
        opus.set_bitrate(Bitrate::Bits(BITRATE_BPS))?;
        Ok(Self {
            opus,
            packet: [0; MAX_PACKET],
        })
    }

    /// Encodes one frame; the packet borrows the encoder's buffer.
    pub fn encode(&mut self, frame: &[f32; FRAME]) -> Result<&[u8], Error> {
        let len = self.opus.encode_float(frame, &mut self.packet)?;
        Ok(self
            .packet
            .get(..len)
            .ok_or("opus packet overran its buffer")?)
    }
}

pub struct Decoder {
    opus: opus::Decoder,
}

impl Decoder {
    pub fn new() -> Result<Self, Error> {
        Ok(Self {
            opus: opus::Decoder::new(SAMPLE_RATE, Channels::Mono)?,
        })
    }

    /// Decodes one packet into a frame.
    pub fn decode(&mut self, packet: &[u8], frame: &mut [f32; FRAME]) -> Result<(), Error> {
        Self::whole_frame(self.opus.decode_float(packet, frame, false)?)
    }

    /// Fills a frame for a packet that never arrived (Opus packet-loss
    /// concealment: an empty packet).
    pub fn conceal(&mut self, frame: &mut [f32; FRAME]) -> Result<(), Error> {
        Self::whole_frame(self.opus.decode_float(&[], frame, false)?)
    }

    fn whole_frame(decoded: usize) -> Result<(), Error> {
        if decoded == FRAME {
            Ok(())
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
        let (mut encoder, mut decoder) = (Encoder::new().unwrap(), Decoder::new().unwrap());
        let mut sine = Sine::new(440.0);
        let (mut input, mut output) = ([0.0; FRAME], [0.0; FRAME]);

        // Opus has ~6.5 ms of lookahead, so judge a frame after it settles.
        for _ in 0..10 {
            sine.fill(&mut input);
            let packet = encoder.encode(&input).unwrap();
            let bytes = packet.len();
            decoder.decode(packet, &mut output).unwrap();
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
        let (mut encoder, mut decoder) = (Encoder::new().unwrap(), Decoder::new().unwrap());
        let mut output = [1.0; FRAME];

        for _ in 0..5 {
            let packet = encoder.encode(&[0.0; FRAME]).unwrap();
            decoder.decode(packet, &mut output).unwrap();
        }

        assert!(rms(&output) < 1e-3);
    }

    #[test]
    fn a_lost_packet_is_concealed_not_an_error() {
        let (mut encoder, mut decoder) = (Encoder::new().unwrap(), Decoder::new().unwrap());
        let mut sine = Sine::new(440.0);
        let (mut input, mut output) = ([0.0; FRAME], [0.0; FRAME]);

        for _ in 0..5 {
            sine.fill(&mut input);
            let packet = encoder.encode(&input).unwrap();
            decoder.decode(packet, &mut output).unwrap();
        }
        decoder.conceal(&mut output).unwrap();
        // Concealment extrapolates the tone rather than going silent.
        assert!(rms(&output) > 0.05);
    }
}
