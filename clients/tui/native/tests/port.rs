//! Contract test: drives the built helper over stdin/stdout exactly as
//! `Tui.Media` does (4-byte length + JSON), with no audio hardware.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]

use std::time::Duration;

use serde_json::{Value, json};

mod common;
use common::{Call, Helper};

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

    // The meter: bars many times a second, and the 440 Hz tone lights one.
    let levels: Vec<_> = events
        .iter()
        .filter(|event| event["event"] == "loopback_levels")
        .collect();
    assert!(
        levels.len() >= 10,
        "{} loopback_levels events",
        levels.len()
    );
    let bars = levels.last().unwrap()["you"].as_array().unwrap();
    assert_eq!(bars.len(), 12);
    assert!(
        bars.iter().any(|bar| bar.as_f64().unwrap() > 0.3),
        "{bars:?}"
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
    let mut call = Call::start(&json!([]), false);
    call.connect();

    for (name, seen) in [
        ("offerer", &call.offerer.seen),
        ("answerer", &call.answerer.seen),
    ] {
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
            stats["output_peak_dbfs"].as_f64().unwrap() > -15.0,
            "{name} heard: {stats}"
        );
    }
    call.stop();
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
