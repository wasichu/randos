//! Contract test: drives the built helper over stdin/stdout exactly as
//! `Tui.Media` does (4-byte length + JSON), with no audio hardware.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::io::{Read, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::Duration;

use serde_json::{Value, json};

struct Helper {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: ChildStdout,
}

impl Helper {
    fn spawn() -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_randos_media"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().unwrap();
        Self {
            child,
            stdin,
            stdout,
        }
    }

    fn send(&mut self, body: &[u8]) {
        let stdin = self.stdin.as_mut().unwrap();
        stdin
            .write_all(&u32::try_from(body.len()).unwrap().to_be_bytes())
            .unwrap();
        stdin.write_all(body).unwrap();
        stdin.flush().unwrap();
    }

    fn receive(&mut self) -> Value {
        let mut header = [0u8; 4];
        self.stdout.read_exact(&mut header).unwrap();
        let mut body = vec![0u8; u32::from_be_bytes(header) as usize];
        self.stdout.read_exact(&mut body).unwrap();
        serde_json::from_slice(&body).unwrap()
    }

    /// Sends a request and returns its reply, collecting events seen first.
    fn request(&mut self, request: Value, events: &mut Vec<Value>) -> Value {
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

    fn close(mut self) -> i32 {
        drop(self.stdin.take());
        self.child.wait().unwrap().code().unwrap()
    }
}

#[test]
fn ping_and_malformed_requests() {
    let mut helper = Helper::spawn();
    let mut events = Vec::new();

    let reply = helper.request(json!({"id": 1, "cmd": "ping"}), &mut events);
    assert_eq!(reply, json!({"reply": 1, "ok": "pong"}));

    let reply = helper.request(json!({"id": 2, "cmd": "dance"}), &mut events);
    assert_eq!(reply["reply"], 2);
    assert!(reply["error"].as_str().unwrap().contains("invalid request"));

    helper.send(b"not json");
    let reply = helper.receive();
    assert_eq!(reply["reply"], Value::Null);

    assert!(events.is_empty());
    assert_eq!(helper.close(), 0, "exits cleanly when stdin closes");
}

#[test]
fn loopback_runs_and_reports_stats_without_hardware() {
    let mut helper = Helper::spawn();
    let mut events = Vec::new();

    let start = json!({"id": 1, "cmd": "loopback_start", "in": "sine", "out": "null"});
    let reply = helper.request(start.clone(), &mut events);
    assert_eq!(
        reply["ok"],
        json!({"input": "sine 440 Hz", "output": "null"})
    );

    let reply = helper.request(
        json!({"id": 2, "cmd": "loopback_start", "in": "sine", "out": "null"}),
        &mut events,
    );
    assert_eq!(
        reply,
        json!({"reply": 2, "error": "loopback already running"})
    );

    // Stats arrive once a second.
    std::thread::sleep(Duration::from_millis(1_300));
    let reply = helper.request(json!({"id": 3, "cmd": "loopback_stop"}), &mut events);
    assert_eq!(reply, json!({"reply": 3, "ok": true}));

    let stats = events
        .iter()
        .find(|event| event["event"] == "loopback_stats")
        .expect("a loopback_stats event");
    assert_eq!(stats["codec_ms"], 26.5);
    assert!(
        stats["input_peak_dbfs"].as_f64().unwrap() > -10.0,
        "the sine reached the codec"
    );

    let reply = helper.request(
        json!({"id": 4, "cmd": "loopback_start", "in": "nope", "out": "null"}),
        &mut events,
    );
    assert!(reply["error"].as_str().unwrap().contains("unknown input"));

    assert_eq!(helper.close(), 0);
}

#[test]
fn closing_stdin_stops_a_running_loopback() {
    let mut helper = Helper::spawn();
    let mut events = Vec::new();

    let start = json!({"id": 1, "cmd": "loopback_start", "in": "sine", "out": "null"});
    assert!(helper.request(start, &mut events).get("ok").is_some());

    assert_eq!(helper.close(), 0);
}
