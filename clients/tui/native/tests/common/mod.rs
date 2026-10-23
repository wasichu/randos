//! Shared by the integration tests: the helper over its Port, and the test
//! TURN server (`examples/test_turn.rs`).
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    dead_code
)]

use std::io::{BufRead, BufReader, Read, Write};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

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

/// One side of a `Call`: its helper, the events it has sent, and those
/// that arrived while the test waited on one of its replies (relayed on
/// the next pass, like any other).
pub struct Side {
    pub helper: Helper,
    pub seen: Vec<Value>,
    inbox: Vec<Value>,
}

impl Side {
    /// Packets received, from its latest `call_stats`.
    pub fn received(&self) -> u64 {
        self.seen
            .iter()
            .rev()
            .find(|e| e["event"] == "call_stats")
            .and_then(|e| e["packets_received"].as_u64())
            .unwrap_or(0)
    }

    /// Sends a request, keeping events that arrive first for the next pass.
    pub fn request(&mut self, request: Value) -> Value {
        self.helper.request(request, &mut self.inbox)
    }
}

/// Two helpers in a call, the test playing the server between them.
pub struct Call {
    pub offerer: Side,
    pub answerer: Side,
    next_id: u64,
}

impl Call {
    /// Starts both helpers' calls (`relay_only` with a relay in
    /// `ice_servers`); `run` connects them.
    pub fn start(ice_servers: &Value, relay_only: bool) -> Self {
        let side = |role: &str| {
            let mut side = Side {
                helper: Helper::spawn(),
                seen: Vec::new(),
                inbox: Vec::new(),
            };
            let reply = side.request(json!({
                "id": 1, "cmd": "call_start", "role": role, "ice_servers": ice_servers,
                "in": "sine", "out": "null", "bind_ip": "127.0.0.1", "relay_only": relay_only
            }));
            assert_eq!(reply["ok"]["input"], "sine 440 Hz", "{role}: {reply}");
            side
        };
        Self {
            offerer: side("offerer"),
            answerer: side("answerer"),
            next_id: 100,
        }
    }

    /// Relays each helper's `call_signal` events to the other for `duration`.
    pub fn run(&mut self, duration: Duration) {
        self.run_until(duration, |_| false);
    }

    /// `run` until `done` holds or `limit` passes; whether it held.
    pub fn run_until(&mut self, limit: Duration, done: impl Fn(&Self) -> bool) -> bool {
        let until = Instant::now() + limit;
        while Instant::now() < until {
            relay(&mut self.offerer, &mut self.answerer, &mut self.next_id);
            relay(&mut self.answerer, &mut self.offerer, &mut self.next_id);
            if done(self) {
                return true;
            }
            thread::sleep(Duration::from_millis(10));
        }
        false
    }

    /// Runs until both sides hear the other (10 s at most: CI is slow).
    pub fn connect(&mut self) {
        let connected = self.run_until(Duration::from_secs(10), |call| {
            call.received().0 > 50 && call.received().1 > 50
        });
        assert!(connected, "never connected: {:?}", self.received());
    }

    /// Packets each side has received, from its latest `call_stats`.
    pub fn received(&self) -> (u64, u64) {
        (self.offerer.received(), self.answerer.received())
    }

    /// Asks the offerer for an ICE restart (what the TUI does when the
    /// server's `ice_generation` grows).
    pub fn restart(&mut self) {
        self.next_id += 1;
        let reply = self
            .offerer
            .request(json!({"id": self.next_id, "cmd": "call_restart"}));
        assert_eq!(reply["ok"], true, "call_restart: {reply}");
    }

    pub fn stop(mut self) {
        for side in [&mut self.offerer, &mut self.answerer] {
            let reply = side.request(json!({"id": 999, "cmd": "call_stop"}));
            assert_eq!(reply["ok"], true);
        }
        assert_eq!(self.offerer.helper.close(), 0);
        assert_eq!(self.answerer.helper.close(), 0);
    }
}

/// Relays `from`'s `call_signal` events to `to`. Events `to` sends while we
/// wait for its reply are its own, so they wait in its inbox.
fn relay(from: &mut Side, to: &mut Side, next_id: &mut u64) {
    let mut events = std::mem::take(&mut from.inbox);
    events.extend(from.helper.events());
    for event in events {
        if event["event"] == "call_signal" {
            *next_id += 1;
            let reply = to.request(json!({
                "id": *next_id, "cmd": "call_signal",
                "type": event["type"], "payload": event["payload"]
            }));
            assert_eq!(reply["ok"], true, "relaying {event}: {reply}");
        }
        from.seen.push(event);
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
