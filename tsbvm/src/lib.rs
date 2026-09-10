//! A VM for Tsubaki's `.tsb`, in Rust.
//!
//! The OCaml side already has one (bin/vm.ml) and it is the reference: what
//! this one answers has to match it, or it is wrong. What it buys is a host
//! without OCaml's runtime under it -- see AST_IN_RUST_EXPERIMENT.md for why
//! that was expected to matter, and what was measured before believing it.
//!
//! Deliberately narrow for now: numbers, strings, bools, variables, calls
//! with positional arguments, `if`/`while`, `return`. Anything else says so
//! (`Unsupported`) rather than guessing -- the same shape as Tocode's
//! `Not_yet` on the folding side.

pub mod tsb;
pub mod vm;

// --- the wasm surface ------------------------------------------------------
// The same shape as kernel/src/lib.rs's: the host allocates inside this
// module's own linear memory, writes the `.tsb` there, and reads the printed
// text back out. No shared references cross -- only bytes.

use std::cell::RefCell;

thread_local! {
    static OUT: RefCell<String> = RefCell::new(String::new());
}

#[no_mangle]
pub extern "C" fn tsb_alloc(bytes: usize) -> *mut u8 {
    let mut buf = Vec::<u8>::with_capacity(bytes);
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf);
    ptr
}

#[no_mangle]
pub extern "C" fn tsb_dealloc(ptr: *mut u8, bytes: usize) {
    unsafe {
        drop(Vec::from_raw_parts(ptr, 0, bytes));
    }
}

/// Run a `.tsb`. Returns 0 when it ran to the end, 1 when it stopped -- what
/// it printed (and, if it stopped, why) is in the output buffer either way.
#[no_mangle]
pub extern "C" fn tsb_run(ptr: *const u8, len: usize) -> i32 {
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    let (text, code) = match tsb::read(bytes) {
        Ok(p) => {
            let mut machine = vm::Vm::new(p);
            let r = machine.run();
            let mut s = machine.output().to_string();
            match r {
                Ok(_) => (s, 0),
                Err(e) => {
                    s.push_str(&format!("tsbvm: {e}\n"));
                    (s, 1)
                }
            }
        }
        Err(e) => (format!("tsbvm: {e}\n"), 1),
    };
    OUT.with(|o| *o.borrow_mut() = text);
    code
}

#[no_mangle]
pub extern "C" fn tsb_out_ptr() -> *const u8 {
    OUT.with(|o| o.borrow().as_ptr())
}

#[no_mangle]
pub extern "C" fn tsb_out_len() -> usize {
    OUT.with(|o| o.borrow().len())
}
