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

pub mod json;
pub mod tsb;
pub mod vm;

// --- the wasm surface ------------------------------------------------------
// The same shape as kernel/src/lib.rs's: the host allocates inside this
// module's own linear memory, writes the `.tsb` there, and reads the printed
// text back out. No shared references cross -- only bytes.

use std::cell::RefCell;

thread_local! {
    static OUT: RefCell<String> = RefCell::new(String::new());
    /// The program stays up after it has run, so the host can call into it
    /// (`ops.call("setup")` and the rest) -- the same way the OCaml side's
    /// tsubakiEval/tsubakiCall share one persistent global scope.
    static VM: RefCell<Option<vm::Vm>> = RefCell::new(None);
}

fn take(ptr: *const u8, len: usize) -> String {
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr, len) }).into_owned()
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
            let code = match r {
                Ok(_) => 0,
                Err(e) => {
                    s.push_str(&format!("tsbvm: {}\n", machine.report(&e)));
                    1
                }
            };
            VM.with(|v| *v.borrow_mut() = Some(machine));
            (s, code)
        }
        Err(e) => (format!("tsbvm: {e}\n"), 1),
    };
    OUT.with(|o| *o.borrow_mut() = text);
    code
}

/// 走っている VM の上に、もう一枚を足して走らせる(静的 import)。一枚目が
/// `tsb_run`、続きがこちら -- 読む順は、畳んだ側が決めている。
///
/// 返すのは `tsb_run` と同じ 0 / 1。出るのは**この一枚が**印字したぶんだけ
/// (VM の out は溜まりつづけるので、走らせる前の長さを覚えて、伸びたぶんを渡す)。
#[no_mangle]
pub extern "C" fn tsb_load(ptr: *const u8, len: usize) -> i32 {
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    let (text, code) = VM.with(|cell| match cell.borrow_mut().as_mut() {
        None => ("tsbvm: nothing has been run yet".to_string(), 1),
        Some(machine) => {
            let was = machine.output().len();
            let r = machine.load(bytes);
            let mut s = machine.output()[was..].to_string();
            match r {
                Ok(_) => (s, 0),
                Err(e) => {
                    s.push_str(&format!("tsbvm: {}\n", machine.report(&e)));
                    (s, 1)
                }
            }
        }
    });
    OUT.with(|o| *o.borrow_mut() = text);
    code
}

/// Call a function of the program that already ran. The arguments arrive as a
/// JSON array and the answer leaves as JSON -- see json.rs for what that
/// carries, and why it is the same meaning the OCaml side hands to JS.
///
/// Returns 0 and leaves the answer in the output buffer; 1 and leaves the
/// reason there instead.
#[no_mangle]
pub extern "C" fn tsb_call(
    name_ptr: *const u8,
    name_len: usize,
    args_ptr: *const u8,
    args_len: usize,
) -> i32 {
    let name = take(name_ptr, name_len);
    let args_json = take(args_ptr, args_len);
    let args = match json::from_json(&args_json) {
        Ok(vm::Value::Arr(a)) => a.borrow().clone(),
        Ok(other) => vec![other],
        Err(e) => {
            OUT.with(|o| *o.borrow_mut() = format!("tsbvm: the arguments are not JSON: {e}"));
            return 1;
        }
    };
    let (text, code) = VM.with(|cell| match cell.borrow_mut().as_mut() {
        None => ("tsbvm: nothing has been run yet".to_string(), 1),
        Some(machine) => match machine.call_toplevel(&name, args) {
            Ok(v) => match json::to_json(&v) {
                Ok(j) => (j, 0),
                Err(e) => (format!("tsbvm: {e}"), 1),
            },
            Err(e) => (format!("tsbvm: {}", machine.report(&e)), 1),
        },
    });
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
