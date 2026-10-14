//! `host(...)` through the real `tsbvm` binary, on programs folded by
//! `tsubakic` (tests/fixtures/*.jl -> *.tsb). Regenerate a fixture with:
//!
//!   node _build/default/bin/tsubakic.bc.wasm.js \
//!        tsbvm/tests/fixtures/NAME.tsb tsbvm/tests/fixtures/NAME.jl
//!
//! What is asserted is what the program printed and how the process ended --
//! the contract a script relies on.

use std::path::PathBuf;
use std::process::{Command, Output};

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(format!("{name}.tsb"))
}

fn run(name: &str, env: &[(&str, &str)]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_tsbvm"))
        .arg(fixture(name))
        .envs(env.iter().copied())
        .output()
        .expect("run tsbvm")
}

fn stdout(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

fn temp_dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("tsbvm-host-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn fs_env_and_json_capabilities() {
    let dir = temp_dir("fs");
    let o = run("host_fs", &[("HOST_TEST_DIR", dir.to_str().unwrap())]);
    assert!(o.status.success(), "stderr: {}", String::from_utf8_lossy(&o.stderr));
    assert_eq!(
        stdout(&o),
        "default: fallback\n\
         absent without default: true\n\
         exists: true false\n\
         read: hello \"quoted\"\nline two\n\
         copied: true\n\
         dirs: [\"alpha\", \"deep\", \"zeta\"]\n\
         parsed: x 3 true\n\
         stringified: {\"k\":[1,\"two\"]}\n\
         after rmrf: false\n\
         done\n"
    );
    assert!(!dir.join("out").exists(), "rmrf removed the tree");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn exit_ends_the_program_with_that_code_and_cannot_be_caught() {
    let o = run("host_exit", &[]);
    assert_eq!(o.status.code(), Some(3));
    // what was printed before the exit still comes out; nothing after it does
    assert_eq!(stdout(&o), "before\n");
}

#[test]
fn refusals_are_errors_the_program_can_catch() {
    let o = run("host_errors", &[]);
    assert!(o.status.success(), "stderr: {}", String::from_utf8_lossy(&o.stderr));
    let out = stdout(&o);
    for expected in [
        "caught: host(\"no.such.capability\"): no such capability: no.such.capability",
        "caught: host(\"fs.read\"): read /definitely/not/here/x.txt: No such file or directory",
        "caught: host(\"fs.read\"): argument 1 (path) must be a String",
        "caught: host(\"fs.write\"): missing argument 2 (text)",
        "caught: host(\"json.parse\"): not JSON:",
        "caught: host(\"exit\"): exit(code): the code must be an Int",
        "still running",
    ] {
        assert!(out.contains(expected), "missing {expected:?} in:\n{out}");
    }
    assert!(!out.contains("no error"), "every attempt should have failed:\n{out}");
}

#[test]
fn a_program_with_no_host_attached_cannot_reach_out() {
    // the library, not the CLI: no `set_host`, so `host(...)` is an error
    let bytes = std::fs::read(fixture("host_errors")).unwrap();
    let mut vm = tsbvm::vm::Vm::new(tsbvm::tsb::read(&bytes).unwrap());
    let _ = vm.run();
    assert!(
        vm.output().contains("this VM has no host attached"),
        "output was:\n{}",
        vm.output()
    );
}

#[cfg(feature = "http")]
mod http {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;

    /// A one-shot-per-connection HTTP/1.1 server. `/ok` answers 200 JSON,
    /// `/refuse` 403 JSON, `/text` 500 plain text. Every request is sent back
    /// down the channel as (path, authorization header, body).
    fn serve() -> (String, mpsc::Receiver<(String, String, String)>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = stream.unwrap();
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                let (head, mut body) = loop {
                    let n = stream.read(&mut chunk).unwrap();
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        break (String::from_utf8_lossy(&buf[..i]).into_owned(), buf[i + 4..].to_vec());
                    }
                };
                let want = head
                    .lines()
                    .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap()))
                    .unwrap_or(0);
                while body.len() < want {
                    let n = stream.read(&mut chunk).unwrap();
                    body.extend_from_slice(&chunk[..n]);
                }
                let path = head.split_whitespace().nth(1).unwrap().to_string();
                let auth = head
                    .lines()
                    .find_map(|l| l.to_ascii_lowercase().strip_prefix("authorization:").map(|v| v.trim().to_string()))
                    .unwrap_or_default();
                let (status, ctype, reply) = match path.as_str() {
                    "/ok" => ("200 OK", "application/json", r#"{"imported":1,"results":[{"status":"ok"}]}"#),
                    "/refuse" => ("403 Forbidden", "application/json", r#"{"error":"admin_required"}"#),
                    _ => ("500 Internal Server Error", "text/plain", "boom"),
                };
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status}\r\ncontent-type: {ctype}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
                    reply.len()
                );
                let _ = tx.send((path, auth, String::from_utf8_lossy(&body).into_owned()));
            }
        });
        (url, rx)
    }

    #[test]
    fn post_json_sends_token_and_body_and_returns_status_with_parsed_body() {
        let (url, rx) = serve();
        let o = run("host_http", &[("HOST_TEST_URL", &url)]);
        assert!(o.status.success(), "stderr: {}", String::from_utf8_lossy(&o.stderr));
        assert_eq!(
            stdout(&o),
            "ok: 200 1 ok\n\
             refused: 403 admin_required\n\
             text: 500 boom\n\
             unreachable is an error: yes\n"
        );

        let (path, auth, body) = rx.recv().unwrap();
        assert_eq!(path, "/ok");
        assert_eq!(auth, "bearer secret-token");
        assert_eq!(body, r#"{"emojis":[{"shortcode":"a"}],"dry_run":true}"#);
        // an empty token sends no Authorization header at all
        let (path, auth, _) = rx.recv().unwrap();
        assert_eq!((path.as_str(), auth.as_str()), ("/refuse", ""));
    }
}

#[cfg(not(feature = "http"))]
#[test]
fn post_json_without_the_feature_says_so() {
    let o = run("host_http", &[("HOST_TEST_URL", "http://127.0.0.1:1")]);
    assert!(!o.status.success());
    assert!(String::from_utf8_lossy(&o.stderr).contains("built without the `http` feature"));
}
