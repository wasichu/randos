//! A relay-only helper↔helper call through the test TURN server
//! (`examples/test_turn.rs`): the relay carries the call, and a cut stops
//! it, as a network change does. ICE restart recovers it (`call_restart`).
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

mod common;
use common::{Helper, TestTurn};

/// Two helpers in a relay-only call through `turn`, the test playing the
/// server between them.
struct Call {
    offerer: Helper,
    answerer: Helper,
    offerer_seen: Vec<Value>,
    answerer_seen: Vec<Value>,
    next_id: u64,
}

impl Call {
    fn start(turn: &TestTurn) -> Self {
        let (mut offerer, mut answerer) = (Helper::spawn(), Helper::spawn());
        let mut ignored = Vec::new();
        for (helper, role) in [(&mut offerer, "offerer"), (&mut answerer, "answerer")] {
            let start = json!({
                "id": 1, "cmd": "call_start", "role": role, "ice_servers": turn.ice_servers(),
                "in": "sine", "out": "null", "bind_ip": "127.0.0.1", "relay_only": true
            });
            let reply = helper.request(start, &mut ignored);
            assert_eq!(reply["ok"]["input"], "sine 440 Hz", "{role}: {reply}");
        }
        Self {
            offerer,
            answerer,
            offerer_seen: Vec::new(),
            answerer_seen: Vec::new(),
            next_id: 100,
        }
    }

    /// Relays each helper's `call_signal` events to the other for `duration`.
    fn run(&mut self, duration: Duration) {
        let until = Instant::now() + duration;
        while Instant::now() < until {
            let from_offerer = self.offerer.events();
            let from_answerer = self.answerer.events();
            for (events, seen, to) in [
                (from_offerer, &mut self.offerer_seen, &mut self.answerer),
                (from_answerer, &mut self.answerer_seen, &mut self.offerer),
            ] {
                for event in events {
                    if event["event"] == "call_signal" {
                        self.next_id += 1;
                        let relayed = json!({
                            "id": self.next_id, "cmd": "call_signal",
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
    }

    /// Packets each side has received, from its latest `call_stats`.
    fn received(&self) -> (u64, u64) {
        let latest = |seen: &[Value]| {
            seen.iter()
                .rev()
                .find(|e| e["event"] == "call_stats")
                .and_then(|e| e["packets_received"].as_u64())
                .unwrap_or(0)
        };
        (latest(&self.offerer_seen), latest(&self.answerer_seen))
    }

    fn stop(mut self) {
        let mut ignored = Vec::new();
        for helper in [&mut self.offerer, &mut self.answerer] {
            let reply = helper.request(json!({"id": 999, "cmd": "call_stop"}), &mut ignored);
            assert_eq!(reply["ok"], true);
        }
        assert_eq!(self.offerer.close(), 0);
        assert_eq!(self.answerer.close(), 0);
    }
}

#[test]
fn the_test_relay_carries_a_relay_only_call_and_a_cut_stops_it() {
    let mut turn = TestTurn::spawn();
    let mut call = Call::start(&turn);
    call.run(Duration::from_millis(3_500));

    let (offerer, answerer) = call.received();
    assert!(
        offerer > 50 && answerer > 50,
        "through the relay: {offerer}, {answerer}"
    );
    let allocations = turn.lines();
    assert!(
        allocations
            .iter()
            .filter(|l| l.starts_with("allocated "))
            .count()
            >= 2,
        "{allocations:?}"
    );

    // The network goes: every path through the relay is dead.
    turn.command("cut-all");
    call.run(Duration::from_millis(1_500));
    let before = call.received();
    call.run(Duration::from_millis(1_500));
    let after = call.received();
    assert!(
        after.0 - before.0 < 5 && after.1 - before.1 < 5,
        "audio kept flowing after the cut: {before:?} -> {after:?}"
    );
    call.stop();
}
