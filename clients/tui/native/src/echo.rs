//! Echo cancellation for calls, so headphones become optional: without it,
//! the peer's voice from the speaker reaches the mic and they hear
//! themselves. `sonora` is a pure-Rust port of WebRTC's audio processing,
//! the canceller (AEC3) browsers run on every call.
//!
//! The canceller needs both sides: everything about to be played (`render`)
//! and the mic (`capture`, cleaned in place before encoding). It estimates
//! the echo's delay itself; `capture` also takes the audio queued between
//! the two (the rings) as a hint. Only on calls: on the mic test's loopback
//! it would cancel your own voice, the very echo the test is for.
//!
//! On the call session thread, never in a real-time audio callback.

use sonora::config::EchoCanceller as Aec3;
use sonora::{AudioProcessing, Config, StreamConfig};

use crate::Error;
use crate::codec::{FRAME, SAMPLE_RATE};

/// sonora processes 10 ms chunks; our frames are 20 ms.
const CHUNK: usize = FRAME / 2;

pub struct EchoCanceller {
    apm: AudioProcessing,
    chunk: [f32; CHUNK],
}

impl EchoCanceller {
    pub fn new() -> Self {
        let stream = StreamConfig::new(SAMPLE_RATE, 1);
        let config = Config {
            echo_canceller: Some(Aec3::default()),
            ..Default::default()
        };
        Self {
            apm: AudioProcessing::builder()
                .config(config)
                .capture_config(stream)
                .render_config(stream)
                .build(),
            chunk: [0.0; CHUNK],
        }
    }

    /// A frame about to be played: what the mic may hear back.
    pub fn render(&mut self, frame: &[f32; FRAME]) -> Result<(), Error> {
        for half in frame.as_chunks::<CHUNK>().0 {
            self.chunk.copy_from_slice(half);
            self.apm
                .process_render_f32(&[half.as_slice()], &mut [&mut self.chunk])
                .map_err(|err| format!("echo canceller (render): {err:?}"))?;
        }
        Ok(())
    }

    /// A mic frame, with the echo of what was played taken out (in place).
    /// `queued_ms`: audio waiting in the capture and playback rings, a hint
    /// for the echo's delay.
    pub fn capture(&mut self, frame: &mut [f32; FRAME], queued_ms: f64) -> Result<(), Error> {
        // Clamped by sonora to 0..500; a clamped hint still processes.
        let _ = self.apm.set_stream_delay_ms(queued_ms.round() as i32);
        for half in frame.as_chunks_mut::<CHUNK>().0 {
            self.chunk.copy_from_slice(half);
            self.apm
                .process_capture_f32(&[&self.chunk], &mut [half.as_mut_slice()])
                .map_err(|err| format!("echo canceller (capture): {err:?}"))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codec::rms;

    /// Speech-like noise: a deterministic pseudo-random source, low-passed
    /// and with a slow amplitude wobble (a pure tone would be too easy).
    fn voice(seed: u32, frames: usize) -> Vec<[f32; FRAME]> {
        let mut state = seed;
        let mut low = 0.0f32;
        (0..frames)
            .map(|f| {
                let mut frame = [0.0; FRAME];
                for (i, sample) in frame.iter_mut().enumerate() {
                    state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                    let white = (state >> 8) as f32 / (1u32 << 24) as f32 * 2.0 - 1.0;
                    low = 0.85 * low + 0.15 * white;
                    let t = (f * FRAME + i) as f32 / SAMPLE_RATE as f32;
                    *sample = low * (0.6 + 0.4 * (std::f32::consts::TAU * 3.0 * t).sin());
                }
                frame
            })
            .collect()
    }

    fn db(ratio: f32) -> f32 {
        20.0 * ratio.max(1e-9).log10()
    }

    /// The peer's voice is played; the mic hears it back 100 ms later at
    /// half the level (a laptop's speakers and mic).
    #[test]
    fn the_echo_of_what_was_played_is_taken_out() {
        let far = voice(1, 400); // 8 s
        let delay = 5; // frames: 100 ms
        let mut aec = EchoCanceller::new();
        let (mut mic_energy, mut out_energy) = (0.0f32, 0.0f32);

        for (i, played) in far.iter().enumerate() {
            aec.render(played).unwrap();
            let mut mic = [0.0; FRAME];
            if i >= delay {
                for (m, s) in mic.iter_mut().zip(&far[i - delay]) {
                    *m = 0.5 * s;
                }
            }
            let before = rms(&mic);
            aec.capture(&mut mic, 100.0).unwrap();
            // Score the last 3 s, after the canceller has converged.
            if i >= 250 {
                mic_energy += before * before;
                out_energy += rms(&mic) * rms(&mic);
            }
        }

        let reduction = db((mic_energy / out_energy).sqrt());
        assert!(reduction > 10.0, "echo reduced by only {reduction:.1} dB");
    }

    /// Nothing played: your own voice must go through untouched (the
    /// canceller mustn't eat speech that isn't echo).
    #[test]
    fn your_own_voice_passes_through() {
        let near = voice(7, 200);
        let mut aec = EchoCanceller::new();
        let (mut before, mut after) = (0.0f32, 0.0f32);
        for (i, spoken) in near.iter().enumerate() {
            aec.render(&[0.0; FRAME]).unwrap();
            let mut mic = *spoken;
            aec.capture(&mut mic, 100.0).unwrap();
            if i >= 50 {
                before += rms(spoken) * rms(spoken);
                after += rms(&mic) * rms(&mic);
            }
        }
        let change = db((after / before).sqrt());
        assert!(change.abs() < 1.5, "your voice changed by {change:.1} dB");
    }

    /// Both talking at once: your voice must mostly survive (a canceller
    /// that suppresses too hard here clips your words). Compared by energy,
    /// as the high-pass filter shifts phase (harmless, but it would spoil a
    /// sample-by-sample comparison).
    #[test]
    fn double_talk_keeps_your_voice() {
        let far = voice(1, 400);
        let near = voice(9, 400);
        let delay = 5;
        let mut aec = EchoCanceller::new();
        let (mut near_energy, mut mic_energy, mut out_energy) = (0.0f32, 0.0f32, 0.0f32);
        for i in 0..far.len() {
            aec.render(&far[i]).unwrap();
            let mut mic = near[i];
            if i >= delay {
                for (m, s) in mic.iter_mut().zip(&far[i - delay]) {
                    *m += 0.5 * s;
                }
            }
            let with_echo = rms(&mic);
            aec.capture(&mut mic, 100.0).unwrap();
            if i >= 250 {
                near_energy += rms(&near[i]) * rms(&near[i]);
                mic_energy += with_echo * with_echo;
                out_energy += rms(&mic) * rms(&mic);
            }
        }
        let kept = db((out_energy / near_energy).sqrt());
        let echo_level = db((mic_energy / near_energy).sqrt());
        // Measured: the voice keeps -3.5 dB (a little ducking while both
        // talk, as in WebRTC), against +1 dB for voice plus echo.
        assert!(
            kept > -6.0 && kept < echo_level,
            "your voice: {kept:.1} dB left (voice + echo was {echo_level:.1} dB)"
        );
    }
}
