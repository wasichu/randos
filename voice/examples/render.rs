//! Renders audio through a voice processor, offline: mono little-endian
//! `f32` samples on stdin, the same out on stdout. The benchmark in
//! `tools/voice-eval` uses it so it measures exactly the code calls run.
//!
//!   cargo run --release -p randos_voice --example render -- \
//!     --variant pitch_shift --rate 48000 --param 0=-4 --param 1=40 < in.f32 > out.f32
//!
//! `--param INDEX=VALUE` sets a parameter in the order of the variant's
//! `parameterDescriptors` (pitch shift: 0 semitones, 1 window ms).

use std::io::{self, Read, Write};
use std::process::ExitCode;

use randos_voice::{MCADAMS_DELAY_SAMPLES, Processor, Variant};

/// Samples per `process` call: a worklet's render quantum.
const BLOCK: usize = 128;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("render: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let mut variant = Variant::Passthrough;
    let mut rate = 48_000.0_f32;
    let mut params: Vec<(usize, f32)> = Vec::new();
    let mut align_delay = false;
    let mut inverse_alpha: Option<f32> = None;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let value = args.next().ok_or(format!("{arg} needs a value"))?;
        match arg.as_str() {
            "--variant" => {
                variant = match value.as_str() {
                    "passthrough" => Variant::Passthrough,
                    "pitch_shift" => Variant::PitchShift,
                    "mcadams" => Variant::McAdams,
                    other => return Err(format!("unknown variant {other}")),
                }
            }
            "--rate" => rate = value.parse().map_err(|_| format!("bad rate {value}"))?,
            "--inverse-alpha" => {
                inverse_alpha = Some(
                    value
                        .parse()
                        .map_err(|_| format!("bad inverse alpha {value}"))?,
                )
            }
            "--align-delay" => {
                align_delay = value.parse().map_err(|_| format!("bad boolean {value}"))?
            }
            "--param" => {
                let (index, number) = value
                    .split_once('=')
                    .ok_or(format!("--param wants INDEX=VALUE, got {value}"))?;
                let index = index.parse().map_err(|_| format!("bad index {index}"))?;
                let number = number.parse().map_err(|_| format!("bad value {number}"))?;
                params.push((index, number));
            }
            other => return Err(format!("unknown option {other}")),
        }
    }

    let mut bytes = Vec::new();
    io::stdin()
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    let (chunks, _rest) = bytes.as_chunks::<4>();
    let mut input: Vec<f32> = chunks.iter().map(|b| f32::from_le_bytes(*b)).collect();
    if variant == Variant::McAdams && (!rate.is_finite() || (rate - 48_000.0).abs() >= 0.1) {
        return Err("McAdams requires 48000 Hz".into());
    }
    let length = input.len();
    // Offline evaluation only: flush the known causal delay, then remove
    // that leading delay without discarding the utterance's final samples.
    // The time-varying pitch shifter has no exact fixed alignment.
    let delay = if align_delay && variant == Variant::McAdams {
        MCADAMS_DELAY_SAMPLES
    } else {
        0
    };
    input.resize(length + delay, 0.0);

    let mut processor = match inverse_alpha {
        Some(alpha) if variant == Variant::McAdams && params.is_empty() => {
            Processor::mcadams_inverse(rate, alpha)
                .ok_or("inverse alpha must be finite and between 0.5 and 1")?
        }
        Some(_) => {
            return Err("--inverse-alpha requires mcadams and cannot be mixed with --param".into());
        }
        None => Processor::new(variant, rate),
    };
    for (index, value) in params {
        processor.set_param(index, value);
    }

    let mut output = vec![0.0_f32; input.len()];
    let mut worst = std::time::Duration::ZERO;
    let started = std::time::Instant::now();
    for (inp, out) in input.chunks(BLOCK).zip(output.chunks_mut(BLOCK)) {
        let block_started = std::time::Instant::now();
        processor.process(inp, out);
        worst = worst.max(block_started.elapsed());
    }
    let seconds = started.elapsed().as_secs_f64();
    let diagnostics = processor.diagnostics();
    eprintln!(
        "{{\"frames\":{},\"failed_frames\":{},\"clipped_samples\":{},\"corrected_poles\":{},\"corrected_frames\":{},\"worst_block_ms\":{},\"seconds\":{},\"aligned_delay_samples\":{},\"samples\":{}}}",
        diagnostics.frames,
        diagnostics.failed_frames,
        diagnostics.clipped_samples,
        diagnostics.corrected_poles,
        diagnostics.corrected_frames,
        worst.as_secs_f64() * 1000.0,
        seconds,
        delay,
        input.len()
    );

    let mut out = Vec::with_capacity(output.len() * 4);
    for sample in output.iter().skip(delay).take(length) {
        out.extend_from_slice(&sample.to_le_bytes());
    }
    io::stdout().write_all(&out).map_err(|e| e.to_string())
}
