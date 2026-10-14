//! What the command-line `tsbvm` lets a program reach: its files, its
//! environment, a way to stop, and (with the `http` feature) one HTTP call.
//!
//! A program asks with `host(name, args...)`; the VM carries the arguments in
//! as one JSON array and the answer out as one JSON value (json.rs). The
//! names below are the whole list -- anything else is an error the program can
//! `catch`. An embedder that wants less (a server running somebody's hook)
//! gives the VM a smaller `Host`; this one is for a person's own scripts and
//! hands out everything, so only run programs you would run anyway.
//!
//!   env.get(name, default)            string | default
//!   fs.dirs(path)                     [string]   sub-directories, sorted
//!   fs.files(path)                    [string]   every file below it, as
//!                                                path + "/" + relative; sorted
//!   fs.exists(path)                   bool
//!   fs.read(path)                     string
//!   fs.write(path, text)              nothing
//!   fs.mkdirp(path)                   nothing
//!   fs.copy(from, to)                 nothing
//!   fs.rmrf(path)                     nothing    (absent is fine)
//!   json.parse(text)                  value      (object -> Dict, array -> Vector)
//!   json.stringify(value)             string
//!   http.post_json(url, token, body)  Dict("status" => Int, "body" => value)
//!                                     needs the `http` feature
//!   exit(code)                        never returns; not catchable

use crate::json;
use crate::vm::{Host, HostError, Value};
use std::path::Path;

pub struct StdHost;

type R = Result<String, HostError>;

fn fail<T>(msg: impl Into<String>) -> Result<T, HostError> {
    Err(HostError::Fail(msg.into()))
}

fn text(args: &[Value], i: usize, what: &str) -> Result<String, HostError> {
    match args.get(i) {
        Some(Value::Str(s)) => Ok(s.to_string()),
        Some(_) => fail(format!("argument {} ({what}) must be a String", i + 1)),
        None => fail(format!("missing argument {} ({what})", i + 1)),
    }
}

fn io<T>(r: std::io::Result<T>, what: &str, path: &str) -> Result<T, HostError> {
    r.or_else(|e| fail(format!("{what} {path}: {e}")))
}

impl Host for StdHost {
    fn call(&mut self, name: &str, args_json: &str) -> R {
        let args = match json::from_json(args_json) {
            Ok(Value::Arr(a)) => a.borrow().clone(),
            Ok(_) | Err(_) => return fail("the arguments did not arrive as a JSON array"),
        };
        match name {
            "env.get" => {
                let var = text(&args, 0, "name")?;
                match (std::env::var(&var), args.get(1)) {
                    (Ok(v), _) => Ok(json::quote(&v)),
                    (Err(_), Some(Value::Str(d))) => Ok(json::quote(d)),
                    (Err(_), _) => Ok("null".to_string()),
                }
            }
            "fs.dirs" => {
                let path = text(&args, 0, "path")?;
                let mut names = Vec::new();
                for entry in io(std::fs::read_dir(&path), "read_dir", &path)? {
                    let entry = io(entry, "read_dir", &path)?;
                    if entry.path().is_dir() {
                        names.push(entry.file_name().to_string_lossy().into_owned());
                    }
                }
                names.sort();
                let quoted: Vec<String> = names.iter().map(|n| json::quote(n)).collect();
                Ok(format!("[{}]", quoted.join(",")))
            }
            "fs.files" => {
                let path = text(&args, 0, "path")?;
                let mut found = Vec::new();
                walk(Path::new(&path), &mut found).or_else(|e| fail(format!("walk {path}: {e}")))?;
                found.sort();
                let quoted: Vec<String> = found.iter().map(|n| json::quote(n)).collect();
                Ok(format!("[{}]", quoted.join(",")))
            }
            "fs.exists" => {
                let path = text(&args, 0, "path")?;
                Ok(Path::new(&path).exists().to_string())
            }
            "fs.read" => {
                let path = text(&args, 0, "path")?;
                Ok(json::quote(&io(std::fs::read_to_string(&path), "read", &path)?))
            }
            "fs.write" => {
                let path = text(&args, 0, "path")?;
                let body = text(&args, 1, "text")?;
                io(std::fs::write(&path, body), "write", &path)?;
                Ok("null".to_string())
            }
            "fs.mkdirp" => {
                let path = text(&args, 0, "path")?;
                io(std::fs::create_dir_all(&path), "mkdir", &path)?;
                Ok("null".to_string())
            }
            "fs.copy" => {
                let from = text(&args, 0, "from")?;
                let to = text(&args, 1, "to")?;
                io(std::fs::copy(&from, &to), "copy", &from)?;
                Ok("null".to_string())
            }
            "fs.rmrf" => {
                let path = text(&args, 0, "path")?;
                let p = Path::new(&path);
                let done = if p.is_dir() {
                    std::fs::remove_dir_all(p)
                } else if p.exists() {
                    std::fs::remove_file(p)
                } else {
                    Ok(())
                };
                io(done, "remove", &path)?;
                Ok("null".to_string())
            }
            "json.parse" => {
                let src = text(&args, 0, "text")?;
                match json::from_json(&src) {
                    // the VM parses the answer again; handing the text back
                    // is the whole job
                    Ok(_) => Ok(src),
                    Err(e) => fail(format!("not JSON: {e}")),
                }
            }
            // the answer is the TEXT of the JSON, so it is itself a JSON
            // string: handing back the JSON would just be parsed again
            "json.stringify" => match args.first() {
                Some(v) => json::to_json(v).map(|t| json::quote(&t)).or_else(fail),
                None => fail("missing argument 1 (value)"),
            },
            "http.post_json" => {
                let url = text(&args, 0, "url")?;
                let token = text(&args, 1, "token")?;
                let body = match args.get(2) {
                    Some(v) => json::to_json(v).or_else(fail)?,
                    None => return fail("missing argument 3 (body)"),
                };
                post_json(&url, &token, &body)
            }
            "exit" => match args.first() {
                Some(Value::Int(n)) => Err(HostError::Exit(*n as i32)),
                _ => fail("exit(code): the code must be an Int"),
            },
            other => fail(format!("no such capability: {other}")),
        }
    }
}

/// Every regular file below `dir`, depth first. A symlink to a directory is
/// not followed (a loop would never end), but a symlink to a file is listed.
fn walk(dir: &Path, out: &mut Vec<String>) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let kind = entry.file_type()?;
        if kind.is_dir() {
            walk(&path, out)?;
        } else {
            out.push(path.to_string_lossy().into_owned());
        }
    }
    Ok(())
}

#[cfg(feature = "http")]
fn post_json(url: &str, token: &str, body: &str) -> R {
    let mut req = ureq::post(url)
        .set("content-type", "application/json")
        .set("accept", "application/json");
    if !token.is_empty() {
        req = req.set("authorization", &format!("Bearer {token}"));
    }
    // A 4xx/5xx is an answer, not a failure of the call: the program decides
    // what a refusal means. Only "could not talk to it at all" is an error.
    let (status, reply) = match req.send_string(body) {
        Ok(r) => (r.status(), r.into_string().unwrap_or_default()),
        Err(ureq::Error::Status(code, r)) => (code, r.into_string().unwrap_or_default()),
        Err(e) => return fail(e.to_string()),
    };
    let parsed = if json::from_json(&reply).is_ok() {
        reply.trim().to_string()
    } else {
        json::quote(&reply)
    };
    Ok(format!("{{\"status\":{status},\"body\":{parsed}}}"))
}

#[cfg(not(feature = "http"))]
fn post_json(_url: &str, _token: &str, _body: &str) -> R {
    fail("this tsbvm was built without the `http` feature")
}
