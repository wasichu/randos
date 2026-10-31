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
fn masking_is_validated_and_local_audition_uses_the_call_processor() {
    let mut helper = Helper::spawn();
    let mut events = Vec::new();
    let invalid = helper.request(
        json!({"id":101,"cmd":"loopback_start","in":"sine","out":"null","masking":"unknown"}),
        &mut events,
    );
    assert!(invalid["error"].is_string());
    for (id, style) in [
        "off",
        "lower_resonance",
        "lower_resonance_pitch",
        "higher_resonance",
        "higher_resonance_pitch",
    ]
    .into_iter()
    .enumerate()
    {
        let reply = helper.request(
            json!({"id":id,"cmd":"loopback_start","in":"sine","out":"null","masking":style}),
            &mut events,
        );
        assert!(reply.get("ok").is_some(), "{reply:?}");
        if style == "higher_resonance_pitch" {
            std::thread::sleep(Duration::from_millis(1300));
        }
        helper.request(json!({"id":id+20,"cmd":"loopback_stop"}), &mut events);
    }
    assert!(
        events
            .iter()
            .any(|event| event["event"] == "loopback_stats" && event["voice_ms"] == 140.0)
    );
    assert_eq!(helper.close(), 0);
}

#[test]
fn live_audition_changes_keep_one_loopback_and_stop_remains_authoritative() {
    let mut helper = Helper::spawn();
    let mut events = Vec::new();
    let capabilities = helper.request(json!({"id":1,"cmd":"capabilities"}), &mut events);
    assert_eq!(capabilities["ok"]["live_audition"], true);
    let started = helper.request(
        json!({"id":2,"cmd":"loopback_start","in":"sine","out":"null","masking":"off","audition":42}),
        &mut events,
    );
    assert!(started.get("ok").is_some());
    for (id, style, delay) in [
        (3, "higher_resonance_pitch", 140.0),
        (4, "off", 0.0),
        (5, "lower_resonance", 140.0),
    ] {
        let reply = helper.request(
            json!({"id":id,"cmd":"loopback_masking","masking":style}),
            &mut events,
        );
        assert_eq!(reply["ok"], true);
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            let event = helper.receive();
            assert_ne!(event["event"], "loopback_failed", "{event:?}");
            assert_eq!(
                event["audition"], 42,
                "audition events retain their session"
            );
            let applied = event["event"] == "loopback_stats" && event["voice_ms"] == delay;
            events.push(event);
            if applied {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "new preview was not installed"
            );
        }
    }
    let invalid = helper.request(
        json!({"id":6,"cmd":"loopback_masking","masking":"unknown"}),
        &mut events,
    );
    assert!(invalid["error"].is_string());
    let occupied = helper.request(
        json!({"id":7,"cmd":"loopback_start","in":"sine","out":"null"}),
        &mut events,
    );
    assert_eq!(occupied["error"], "loopback already running");
    for (id, style) in [
        (8, "off"),
        (9, "lower_resonance_pitch"),
        (10, "higher_resonance"),
        (11, "off"),
    ] {
        assert_eq!(
            helper.request(
                json!({"id":id,"cmd":"loopback_masking","masking":style}),
                &mut events
            )["ok"],
            true
        );
    }
    assert_eq!(
        helper.request(json!({"id":12,"cmd":"loopback_stop"}), &mut events)["ok"],
        true
    );
    let stopped = helper.request(
        json!({"id":13,"cmd":"loopback_masking","masking":"off"}),
        &mut events,
    );
    assert_eq!(stopped["error"], "no loopback running");
    assert!(!events.iter().any(|e| e["event"] == "loopback_failed"));
    assert_eq!(helper.close(), 0);
}

#[test]
fn ping_and_malformed_requests() {
    let mut helper = Helper::spawn();
    let mut events = Vec::new();

    let reply = helper.request(json!({"id": 1, "cmd": "ping"}), &mut events);
    assert_eq!(reply, json!({"reply": 1, "ok": "pong"}));
    let capabilities = helper.request(json!({"id": 10, "cmd": "capabilities"}), &mut events);
    assert_eq!(capabilities["ok"]["voice_masking"], true);

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
