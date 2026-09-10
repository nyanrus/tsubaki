//! `tsbvm file.tsb` -- run a folded Tsubaki program. No parser here, by
//! design: the folding happens in `tsubakic` (see bin/tsubakic.ml).

fn main() {
    let path = match std::env::args().nth(1) {
        Some(p) => p,
        None => {
            eprintln!("usage: tsbvm file.tsb");
            std::process::exit(1);
        }
    };
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("tsbvm: {path}: {e}");
            std::process::exit(1);
        }
    };
    let p = match tsbvm::tsb::read(&bytes) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("tsbvm: {e}");
            std::process::exit(1);
        }
    };
    if std::env::args().nth(2).as_deref() == Some("--pairs") {
        for (k, n) in tsbvm::vm::adjacent_pairs(&p).into_iter().take(20) {
            println!("  {n:5}  {k}");
        }
        return;
    }
    if std::env::args().nth(2).as_deref() == Some("--census") {
        let all = tsbvm::vm::instruction_census(&p);
        let total: usize = all.iter().map(|(_, n)| n).sum();
        println!("{total} instructions, {} kinds (the set has 64)", all.len());
        for (k, n) in all {
            println!("  {n:5}  {k}");
        }
        return;
    }
    // `--check` の形で呼ばれたら、走らせずに「まだ知らない命令」を数える
    if std::env::args().nth(2).as_deref() == Some("--check") {
        let missing = tsbvm::vm::unsupported(&p);
        if missing.is_empty() {
            println!("nothing missing: every instruction in this .tsb is known");
        } else {
            let total: usize = missing.iter().map(|(_, n)| n).sum();
            println!("{total} instructions this VM does not know yet:");
            for (k, n) in missing {
                println!("  {n:5}  {k}");
            }
        }
        return;
    }
    let mut vm = tsbvm::vm::Vm::new(p);
    let r = vm.run();
    print!("{}", vm.output());
    if let Err(e) = r {
        eprintln!("tsbvm: {e}");
        std::process::exit(1);
    }
}
