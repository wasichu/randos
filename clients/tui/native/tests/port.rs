//! Contract test: drives the built helper over stdin/stdout exactly as
//! `Tui.Media` does (4-byte length + JSON), with no audio hardware.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::io::{Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// One helper process. A reader thread decodes its stdout frames into a
/// channel, so a test can watch several helpers at once.
struct Helper {
    child: Child,
    stdin: Option<ChildStdin>,
    messages: Receiver<Value>,
}

impl Helper {
    fn spawn() -> Self {
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

    fn send(&mut self, body: &[u8]) {
        let stdin = self.stdin.as_mut().unwrap();
        stdin
            .write_all(&u32::try_from(body.len()).unwrap().to_be_bytes())
            .unwrap();
        stdin.write_all(body).unwrap();
        stdin.flush().unwrap();
    }

    fn receive(&mut self) -> Value {
        self.messages
            .recv_timeout(Duration::from_secs(10))
            .expect("a message from the helper")
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

    /// Events that have arrived so far, without waiting.
    fn events(&mut self) -> Vec<Value> {
        self.messages.try_iter().collect()
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

#[test]
fn two_helpers_call_each_other_through_a_relay() {
    let (mut offerer, mut answerer) = (Helper::spawn(), Helper::spawn());
    let mut ignored = Vec::new();

    for (helper, role) in [(&mut offerer, "offerer"), (&mut answerer, "answerer")] {
        let start = json!({
            "id": 1, "cmd": "call_start", "role": role, "ice_servers": [],
            "in": "sine", "out": "null", "bind_ip": "127.0.0.1"
        });
        let reply = helper.request(start, &mut ignored);
        assert_eq!(reply["ok"]["input"], "sine 440 Hz", "{role}: {reply}");
    }

    // Play the server: relay each helper's call_signal events to the other
    // as call_signal requests, and keep everything else.
    let (mut offerer_seen, mut answerer_seen) = (Vec::new(), Vec::new());
    let mut next_id = 100;
    let until = Instant::now() + Duration::from_millis(3_500);
    while Instant::now() < until {
        let from_offerer = offerer.events();
        let from_answerer = answerer.events();
        for (events, seen, to) in [
            (from_offerer, &mut offerer_seen, &mut answerer),
            (from_answerer, &mut answerer_seen, &mut offerer),
        ] {
            for event in events {
                if event["event"] == "call_signal" {
                    next_id += 1;
                    let relayed = json!({
                        "id": next_id, "cmd": "call_signal",
                        "type": event["type"], "payload": event["payload"]
                    });
                    let reply = to.request(relayed, seen);
                    assert_eq!(reply["ok"], true, "relaying {event}: {reply}");
                }
                seen.push(event);
            }
        }
        thread::sleep(Duration::from_millis(10));
    }

    for (name, seen) in [("offerer", &offerer_seen), ("answerer", &answerer_seen)] {
        assert!(
            seen.iter()
                .any(|e| e["event"] == "call_state" && e["state"] == "connected"),
            "{name} never connected: {seen:?}"
        );
        let stats = seen
            .iter()
            .rev()
            .find(|e| e["event"] == "call_stats")
            .unwrap_or_else(|| panic!("{name} sent no call_stats"));
        assert!(
            stats["packets_received"].as_u64().unwrap() > 50,
            "{name}: {stats}"
        );
        assert!(
            stats["output_peak_dbfs"].as_f64().unwrap() > -15.0,
            "{name} heard: {stats}"
        );
    }

    for helper in [&mut offerer, &mut answerer] {
        let reply = helper.request(json!({"id": 999, "cmd": "call_stop"}), &mut ignored);
        assert_eq!(reply["ok"], true);
    }
    assert_eq!(offerer.close(), 0);
    assert_eq!(answerer.close(), 0);
}

#[test]
fn call_signals_without_a_call_and_double_starts_are_errors() {
    let mut helper = Helper::spawn();
    let mut events = Vec::new();

    let signal = json!({"id": 1, "cmd": "call_signal", "type": "offer", "payload": {}});
    assert_eq!(
        helper.request(signal, &mut events)["error"],
        "no call running"
    );

    let start = json!({"id": 2, "cmd": "call_start", "role": "answerer", "in": "sine", "out": "null", "bind_ip": "127.0.0.1"});
    assert!(
        helper
            .request(start.clone(), &mut events)
            .get("ok")
            .is_some()
    );
    assert_eq!(
        helper.request(
            json!({"id": 3, "cmd": "loopback_start", "in": "sine", "out": "null"}),
            &mut events
        )["error"],
        "call already running"
    );
    assert_eq!(
        helper.request(start, &mut events)["error"],
        "call already running"
    );

    let bad_role = json!({"id": 4, "cmd": "call_start", "role": "dancer"});
    assert_eq!(
        helper.request(json!({"id": 5, "cmd": "call_stop"}), &mut events)["ok"],
        true
    );
    assert!(
        helper.request(bad_role, &mut events)["error"]
            .as_str()
            .unwrap()
            .contains("unknown role")
    );

    assert_eq!(helper.close(), 0);
}
