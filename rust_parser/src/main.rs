//! CLI entry point for the Rust src->AST port -- see rust_parser/README.md
//! for what this is and (more importantly) what it's deliberately NOT: a
//! second implementation of Tsubaki to maintain forever, only a frozen-
//! snapshot differential-testing/comparison tool, OCaml (`bin/main.ml`)
//! remaining the one canonical implementation.
//!
//! Usage: `tsubaki-rust-parser '<source snippet>'` (reads stdin if no arg) --
//! parses+evaluates ONE bare expression and prints it in the SAME format
//! Tsubaki's own `println(expr)` would, so its output can be diffed directly
//! against `node -r ./preload.js .../main.bc.wasm.js` on the identical
//! snippet.
//!
//! `tsubaki-rust-parser --program '<source>'` (reads stdin if no second arg)
//! instead parses+runs a whole STATEMENT-level program (`if`/`for`/`while`/
//! `return`, see rust_parser/README.md) exactly the way `bin/main.ml`'s own
//! `Eval.run` does: nothing is auto-printed, only explicit `println`/`print`
//! calls inside the source produce output -- so the RAW source (not
//! wrapped in an outer `println(...)`) is what gets diffed against real
//! Tsubaki's own stdout for the same script.

mod ast;
mod lexer;
mod parser;
mod value;

use std::io::Read;

fn read_src(arg: Option<String>) -> String {
    match arg {
        Some(s) => s,
        None => {
            let mut buf = String::new();
            std::io::stdin().read_to_string(&mut buf).expect("failed to read stdin");
            buf
        }
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let first = args.next();

    if first.as_deref() == Some("--program") {
        let src = read_src(args.next());
        match parser::parse_program(&src) {
            Err(e) => {
                println!("PARSE ERROR: {}", e.0);
                std::process::exit(2);
            }
            Ok(prog) => {
                if let Err(e) = value::exec_program(&prog) {
                    println!("EVAL ERROR: {}", e.message());
                    std::process::exit(3);
                }
            }
        }
        return;
    }

    let src = read_src(first);
    match parser::parse(&src) {
        Err(e) => {
            println!("PARSE ERROR: {}", e.0);
            std::process::exit(2);
        }
        Ok(expr) => match value::eval(&expr, &mut value::Env::new()) {
            Ok(v) => println!("{}", value::show(&v)),
            Err(e) => {
                println!("EVAL ERROR: {}", e.message());
                std::process::exit(3);
            }
        },
    }
}
