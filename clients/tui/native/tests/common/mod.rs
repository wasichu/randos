//! Shared by the integration tests: the helper over its Port, and the test
//! TURN server (`examples/test_turn.rs`).
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, dead_code)]

use std::io::{BufRead, BufReader, Read, Write};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::Duration;

use serde_json::Value;

/// One helper process. A reader thread decodes its stdout frames into a
/// channel, so a test can watch several helpers at once.
pub struct Helper {
    child: Child,
    stdin: Option<ChildStdin>,
    messages: Receiver<Value>,
}

impl Helper {
    pub fn spawn() -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_randos_media"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take();
        let mut stdout = child.stdout.take().unwrap();
        let (tx, messages) = mpsc::channel();

        thread::spawn(move || {
            loop {
                let mut header = [0u8; 4];
                if stdout.read_exact(&mut header).is_err() {
                    return;
                }
                let mut body = vec![0u8; u32::from_be_bytes(header) as usize];
                stdout.read_exact(&mut body).unwrap();
                if tx.send(serde_json::from_slice(&body).unwrap()).is_err() {
                    return;
                }
            }
        });

        Self {
            child,
            stdin,
            messages,
        }
    }

    pub fn send(&mut self, body: &[u8]) {
        let stdin = self.stdin.as_mut().unwrap();
        stdin
            .write_all(&u32::try_from(body.len()).unwrap().to_be_bytes())
            .unwrap();
        stdin.write_all(body).unwrap();
        stdin.flush().unwrap();
    }

    pub fn receive(&mut self) -> Value {
        self.messages
            .recv_timeout(Duration::from_secs(10))
            .expect("a message from the helper")
    }

    /// Sends a request and returns its reply, collecting events seen first.
    pub fn request(&mut self, request: Value, events: &mut Vec<Value>) -> Value {
        self.send(&serde_json::to_vec(&request).unwrap());
        loop {
            let message = self.receive();
            if message.get("event").is_some() {
                events.push(message);
            } else {
                return message;
            }
        }
    }

    /// Events that have arrived so far, without waiting.
    pub fn events(&mut self) -> Vec<Value> {
        self.messages.try_iter().collect()
    }

    pub fn close(mut self) -> i32 {
        drop(self.stdin.take());
        self.child.wait().unwrap().code().unwrap()
    }
}

/// The test TURN server, running; it exits when this is dropped (its stdin
/// closes).
pub struct TestTurn {
    child: Child,
    stdin: Option<ChildStdin>,
    pub addr: SocketAddr,
    lines: Receiver<String>,
}

impl TestTurn {
    /// Starts `examples/test_turn` (`cargo test` builds the examples too).
    pub fn spawn() -> Self {
        let mut path: PathBuf = std::env::current_exe().unwrap();
        path.pop();
        if path.ends_with("deps") {
            path.pop();
        }
        path.push("examples/test_turn");
        let mut child = Command::new(&path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap_or_else(|e| {
                panic!("{}: {e} (cargo build --example test_turn)", path.display())
            });
        let stdin = child.stdin.take();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        let (tx, lines) = mpsc::channel();
        thread::spawn(move || {
            for line in stdout.lines() {
                let Ok(line) = line else { return };
                if tx.send(line).is_err() {
                    return;
                }
            }
        });
        let first = lines.recv_timeout(Duration::from_secs(10)).unwrap();
        let addr = first.strip_prefix("listening ").unwrap().parse().unwrap();
        Self {
            child,
            stdin,
            addr,
            lines,
        }
    }

    /// The call's `ice_servers` for this relay (its fixed test credentials).
    pub fn ice_servers(&self) -> Value {
        serde_json::json!([{
            "urls": format!("turn:{}?transport=udp", self.addr),
            "username": "randos",
            "credential": "randos"
        }])
    }

    pub fn command(&mut self, line: &str) {
        let stdin = self.stdin.as_mut().unwrap();
        writeln!(stdin, "{line}").unwrap();
        stdin.flush().unwrap();
    }

    /// Its report lines so far (`allocated CLIENT RELAYED`, `cut CLIENT`).
    pub fn lines(&self) -> Vec<String> {
        self.lines.try_iter().collect()
    }
}

impl Drop for TestTurn {
    fn drop(&mut self) {
        drop(self.stdin.take());
        let _ = self.child.wait();
    }
}
