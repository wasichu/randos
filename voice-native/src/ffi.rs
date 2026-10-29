//! The only unsafe code in the native voice bridge. See README.md's safety audit.
#![allow(unsafe_code)]

use std::cell::Cell;
use std::ffi::c_void;
use std::marker::PhantomData;
use std::ptr::NonNull;

use crate::{BATCH, Error, Style};

unsafe extern "C" {
    fn randos_spectral_new(pitch: f64, scale: f64) -> *mut c_void;
    fn randos_spectral_process(
        handle: *mut c_void,
        input: *const f32,
        output: *mut f32,
        count: usize,
        finish: bool,
    ) -> i32;
    fn randos_spectral_delete(handle: *mut c_void);
}

/// One independently owned native engine. Moves between threads, never shares
/// processing state; `Cell` deliberately prevents Sync. No borrowed C++ memory.
pub struct Engine {
    handle: NonNull<c_void>,
    failed: bool,
    finished: bool,
    _not_sync: PhantomData<Cell<()>>,
}

// SAFETY: the handle uniquely owns a context containing only private DSP buffers
// and PRNG state. No globals/thread affinity; C++ may execute on a different
// thread after a move. All operations require exclusive &mut self; it is !Sync.
unsafe impl Send for Engine {}

impl Engine {
    pub fn new(style: Style) -> Result<Self, Error> {
        let (pitch, scale) = style.settings();
        // SAFETY: bounded finite values, no references cross the call. C++ catches
        // constructor exceptions, returning null; ownership transfers only once.
        let handle = unsafe { randos_spectral_new(pitch, scale) };
        Ok(Self {
            handle: NonNull::new(handle).ok_or(Error::Native)?,
            failed: false,
            finished: false,
            _not_sync: PhantomData,
        })
    }

    /// Raw core output includes 3,840 startup samples. The live adapter below
    /// crops these once; finite renderers additionally flush the complete tail.
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.call(input, output, false)
    }

    /// Finite rendering only: first process 1,920 zeros, then flush once. Live
    /// Stop always drops the engine instead of draining buffered speech.
    pub fn finish(&mut self, output: &mut [f32; 1920]) -> Result<(), Error> {
        self.call(&[0.0; 1920], output, true)
    }

    fn call(&mut self, input: &[f32], output: &mut [f32], finish: bool) -> Result<(), Error> {
        output.fill(0.0);
        if self.failed || self.finished {
            return Err(Error::Failed);
        }
        if input.is_empty()
            || input.len() > BATCH
            || input.len() != output.len()
            || !input.iter().all(|value| value.is_finite())
        {
            self.failed = true;
            return Err(Error::Input);
        }
        // SAFETY: uniquely owned non-null live handle, initialized by new and
        // freed only by Drop. Rust borrows guarantee non-overlapping readable/
        // writable slices of exactly count f32s for the duration of this call.
        // C++ retains neither pointer, checks count, catches all exceptions and
        // returns only a status. finish() supplies exactly 1,920 output elements.
        let status = unsafe {
            randos_spectral_process(
                self.handle.as_ptr(),
                input.as_ptr(),
                output.as_mut_ptr(),
                input.len(),
                finish,
            )
        };
        if status != 1 {
            self.failed = true;
            output.fill(0.0);
            return Err(Error::Native);
        }
        self.finished = finish;
        Ok(())
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        // SAFETY: exactly one owner; no operations can race Drop or use the
        // context afterward. Delete is noexcept and matches the constructor.
        unsafe { randos_spectral_delete(self.handle.as_ptr()) };
    }
}
