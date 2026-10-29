//! The WASM interface the browser's worklet shim (`assets/js/randos/voice/worklet.js`)
//! calls: plain exported functions over numbers, no bindings generator.
//! Each AudioWorklet node instantiates its own copy of the module, so the
//! state here is one processor's.
//!
//! The JS side writes a block of input into the buffer `voice_input` points
//! at, calls `voice_process`, and reads the result from `voice_output`. Only
//! `#[unsafe(no_mangle)]`, which exporting a symbol requires, needs the
//! `unsafe_code` allowance; there is no unsafe block.
#![allow(unsafe_code)]

use std::sync::Mutex;

use crate::{Processor, Variant};

struct State {
    processor: Processor,
    input: Vec<f32>,
    output: Vec<f32>,
}

// A Mutex rather than thread_local!: the module is single-threaded either
// way, and thread_local! would embed the toolchain's absolute path (its
// panic location) in the .wasm, so the committed build would differ per
// machine.
static STATE: Mutex<Option<State>> = Mutex::new(None);

/// Runs `f` on this instance's state. (Poisoning can't happen without
/// threads; it's handled rather than unwrapped.)
fn with_state<T>(f: impl FnOnce(&mut Option<State>) -> T) -> T {
    let mut guard = match STATE.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    f(&mut guard)
}

/// Creates this instance's processor (`variant`: `Variant::from_id`) for
/// blocks of at most `frames` samples. Returns 1, or 0 for an unknown variant.
#[unsafe(no_mangle)]
pub extern "C" fn voice_new(variant: u32, sample_rate: f32, frames: u32) -> u32 {
    let Some(variant) = Variant::from_id(variant) else {
        return 0;
    };
    if variant == Variant::McAdams
        && (!sample_rate.is_finite() || (sample_rate - 48_000.0).abs() >= 0.1)
    {
        return 0;
    }
    let frames = frames as usize;
    with_state(|state| {
        *state = Some(State {
            processor: Processor::new(variant, sample_rate),
            input: vec![0.0; frames],
            output: vec![0.0; frames],
        });
    });
    1
}

/// Where the JS side writes each block of input (0 before `voice_new`).
#[unsafe(no_mangle)]
pub extern "C" fn voice_input() -> usize {
    with_state(|state| state.as_mut().map_or(0, |s| s.input.as_mut_ptr() as usize))
}

/// Where the JS side reads each block of output (0 before `voice_new`).
#[unsafe(no_mangle)]
pub extern "C" fn voice_output() -> usize {
    with_state(|state| state.as_ref().map_or(0, |s| s.output.as_ptr() as usize))
}

#[unsafe(no_mangle)]
pub extern "C" fn voice_set_param(index: u32, value: f32) {
    with_state(|state| {
        if let Some(state) = state.as_mut() {
            state.processor.set_param(index as usize, value);
        }
    });
}

/// Processes the first `frames` samples of the input buffer into the output buffer.
#[unsafe(no_mangle)]
pub extern "C" fn voice_process(frames: u32) {
    with_state(|state| {
        if let Some(State {
            processor,
            input,
            output,
        }) = state.as_mut()
        {
            let frames = (frames as usize).min(input.len());
            let (Some(input), Some(output)) = (input.get(..frames), output.get_mut(..frames))
            else {
                return;
            };
            processor.process(input, output);
        }
    });
}
