#!/usr/bin/env python3
"""Run every tests/*.jl and compare its output against the recorded golden.

Each test is a pair: `tests/NAME.jl` (the program) and `tests/NAME.out` (what
running it must print). The comparison is on stdout+stderr combined, exactly
-- Tsubaki reports its own errors on stdout with a "tsubaki: " prefix (see
main.ml's run_or_report), so a program that is *supposed* to fail is an
ordinary test too, with its error message as the golden.

A test whose first line is `# julia: yes` is additionally run through real
Julia and must produce the SAME golden. That is the honest version of "this
matches Julia" -- not a claim, a second execution. Only opt in a test whose
source is genuinely valid Julia (Tsubaki's `::Float`/`::Int` annotations, for
one, are not).

    python3 tools/test.py                # run everything
    python3 tools/test.py dispatch mac   # only tests whose name contains one of these
    python3 tools/test.py --julia        # also cross-check the `# julia: yes` ones
    python3 tools/test.py --tsbvm        # run through the Rust VM (tsbvm/)
    python3 tools/test.py --update       # rewrite goldens from current output

--tsbvm folds each test with tsubakic and runs the bytes through the Rust VM
(tsbvm/) -- and compares against REAL JULIA, not against the golden. The Rust
VM follows Julia where the OCaml runtime and Julia disagree (an all-Int array
stays Int there, a struct prints without field names), so the goldens, which
record what the OCaml runtime does, are the wrong reference for it. A test
without `# julia: yes` has no reference here and is skipped. Needs julia on
PATH. A shape the Rust VM does not know yet says so and is counted separately.

--update exists so a deliberate change doesn't mean hand-editing 20 files.
It records whatever comes out, including a regression -- read the diff it
prints before trusting it.
"""

import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = os.path.join(ROOT, "tests")
BINARY = os.path.join("_build", "default", "bin", "main.bc.wasm.js")

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"
if not sys.stdout.isatty():
    GREEN = RED = YELLOW = DIM = RESET = ""


def run(cmd, timeout=180, stdin=None):
    """Combined stdout+stderr, with a trailing newline normalized away."""
    try:
        p = subprocess.run(
            cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, input=stdin
        )
    except subprocess.TimeoutExpired:
        return "<timed out after %ds>" % timeout
    return (p.stdout + p.stderr).rstrip("\n")


def run_tsubaki(path):
    # a test named repl_* is fed to the REPL on stdin instead of run as a
    # file -- same golden mechanism, exercising the interactive path
    if os.path.basename(path).startswith("repl"):
        with open(os.path.join(ROOT, path)) as f:
            return run(["node", "-r", "./preload.js", BINARY, "--repl"], stdin=f.read())
    return run(["node", "-r", "./preload.js", BINARY, path])


TSBVM = os.path.join("_build", "default", "bin", "tsbvm-check.tsb")
TSUBAKIC = os.path.join("_build", "default", "bin", "tsubakic.bc.wasm.js")


def run_tsbvm(path):
    """Fold with tsubakic, run with the Rust VM. The folding side's own
    complaint comes back as-is, so a shape neither side has yet is named once."""
    folded = run(["node", TSUBAKIC, TSBVM, path])
    if "tsubakic:" in folded:
        return folded
    return run(["node", os.path.join("tools", "tsbvm-host.js"), TSBVM])


def tsbvm_not_yet(output):
    """What the Rust VM (or the folder in front of it) still needs, or None."""
    for marker, cut in (
        ("tsubakic: cannot fold ", " yet"),
        ("tsbvm: vm: ", " (line"),
    ):
        if marker in output:
            rest = output.split(marker, 1)[1]
            return rest.split(cut)[0].replace(" is not supported yet", "").strip()
    # a builtin this VM was never given is the other kind of "not yet"
    if "tsbvm: MethodError: no method matching" in output:
        name = output.split("no method matching ", 1)[1].split("(")[0]
        return f"the builtin {name}"
    if "tsbvm: UndefVarError:" in output:
        return "a name the Rust VM does not have"
    return None


def run_julia(path):
    return run(["julia", "--startup-file=no", path])


def diff(expected, actual):
    import difflib

    lines = difflib.unified_diff(
        expected.splitlines(), actual.splitlines(),
        fromfile="expected", tofile="actual", lineterm="",
    )
    out = []
    for line in lines:
        if line.startswith("+"):
            out.append(GREEN + line + RESET)
        elif line.startswith("-"):
            out.append(RED + line + RESET)
        else:
            out.append(DIM + line + RESET)
    return "\n".join("    " + l for l in out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("filters", nargs="*", help="substring match on test name")
    ap.add_argument("--update", action="store_true", help="rewrite goldens")
    ap.add_argument("--julia", action="store_true", help="cross-check julia-compatible tests")
    ap.add_argument("--tsbvm", action="store_true", help="run through the Rust VM (see tsbvm/)")
    args = ap.parse_args()

    if not os.path.exists(os.path.join(ROOT, BINARY)):
        print("tests: %s is missing -- run `make build` first" % BINARY)
        return 1

    names = sorted(
        f[:-3] for f in os.listdir(TESTS) if f.endswith(".jl")
    )
    if args.filters:
        names = [n for n in names if any(f in n for f in args.filters)]
    if not names:
        print("tests: nothing matched")
        return 1

    passed, failed, crosschecked, skipped = 0, [], 0, 0
    not_yet = []  # (test name, the shape Tocode stopped on) -- --vm only

    for name in names:
        # repo-relative, not absolute: a test whose expected output includes a
        # source position (tests/errors_position.jl) would otherwise bake this
        # machine's home directory into its golden
        jl = os.path.join("tests", name + ".jl")
        golden_path = os.path.join(TESTS, name + ".out")
        if args.tsbvm and name.startswith("repl"):
            # the REPL reads a line at a time; there is no .tsb to fold
            continue
        actual = run_tsbvm(jl) if args.tsbvm else run_tsubaki(jl)

        if args.update:
            with open(golden_path, "w") as f:
                f.write(actual + "\n")
            print("%supdated%s %s" % (YELLOW, RESET, name))
            continue

        if args.tsbvm:
            reason = tsbvm_not_yet(actual)
            if reason is not None:
                print("%snot yet%s %s %s(%s)%s" % (YELLOW, RESET, name, DIM, reason, RESET))
                not_yet.append((name, reason))
                continue
            # real Julia is the reference here, not the golden -- see the
            # module docstring for why
            with open(jl) as f:
                if f.readline().strip() != "# julia: yes":
                    print("%sno julia%s %s %s(not marked `# julia: yes`)%s"
                          % (YELLOW, RESET, name, DIM, RESET))
                    skipped += 1
                    continue
            expected = run_julia(jl)
            if actual != expected:
                print("%sFAIL%s %s %s(julia disagrees)%s" % (RED, RESET, name, DIM, RESET))
                print(diff(expected, actual))
                failed.append(name)
                continue
            print("%sok%s   %s %s(matches julia)%s" % (GREEN, RESET, name, DIM, RESET))
            passed += 1
            continue

        if not os.path.exists(golden_path):
            print("%sno golden%s %s -- run with --update once you've read its output"
                  % (YELLOW, RESET, name))
            skipped += 1
            continue

        with open(golden_path) as f:
            expected = f.read().rstrip("\n")

        if actual != expected:
            print("%sFAIL%s %s" % (RED, RESET, name))
            print(diff(expected, actual))
            failed.append(name)
            continue

        # the same file, through real Julia, against the same golden
        note = ""
        with open(jl) as f:
            wants_julia = f.readline().strip() == "# julia: yes"
        if wants_julia and args.julia:
            jout = run_julia(jl)
            if jout != expected:
                print("%sFAIL%s %s %s(julia disagrees)%s" % (RED, RESET, name, DIM, RESET))
                print(diff(expected, jout))
                failed.append(name + " (julia)")
                continue
            crosschecked += 1
            note = " %s+julia%s" % (DIM, RESET)

        print("%sok%s   %s%s" % (GREEN, RESET, name, note))
        passed += 1

    if args.update:
        return 0

    print("")
    line = "%d passed" % passed
    if crosschecked:
        line += ", %d also verified against real Julia" % crosschecked
    if skipped:
        line += ", %d without a golden" % skipped
    if not_yet:
        line += ", %d the VM can't do yet" % len(not_yet)
    if failed:
        line += ", %s%d failed%s: %s" % (RED, len(failed), RESET, ", ".join(failed))
    print(line)
    if not_yet:
        # what the VM still needs, most-wanted first
        counts = {}
        for _, reason in not_yet:
            counts[reason] = counts.get(reason, 0) + 1
        print("")
        print("still to do:")
        for reason, n in sorted(counts.items(), key=lambda kv: -kv[1]):
            print("  %2d  %s" % (n, reason))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
