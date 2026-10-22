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

    /// Asks the offerer for an ICE restart (what the TUI does when the
    /// server's `ice_generation` grows).
    fn restart(&mut self) {
        self.next_id += 1;
        let request = json!({"id": self.next_id, "cmd": "call_restart"});
        let reply = self.offerer.request(request, &mut self.offerer_seen);
        assert_eq!(reply["ok"], true, "call_restart: {reply}");
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

#[test]
fn after_a_cut_an_ice_restart_brings_the_audio_back_both_ways() {
    let mut turn = TestTurn::spawn();
    let mut call = Call::start(&turn);
    call.run(Duration::from_millis(3_000));
    let connected = call.received();
    assert!(connected.0 > 50 && connected.1 > 50, "{connected:?}");

    // Both sides' paths die (a network change on each, say).
    turn.command("cut-all");
    call.run(Duration::from_millis(1_500));
    let cut = call.received();
    call.run(Duration::from_millis(1_000));
    let still_cut = call.received();
    assert!(
        still_cut.0 - cut.0 < 5 && still_cut.1 - cut.1 < 5,
        "{cut:?} {still_cut:?}"
    );
    let before_restart = turn.lines().len();

    // The offerer restarts; the answerer re-gathers on the new credentials.
    // Both get new sockets, so new allocations the cut doesn't cover.
    call.restart();
    call.run(Duration::from_millis(4_000));
    let back = call.received();
    assert!(
        back.0 - still_cut.0 > 50 && back.1 - still_cut.1 > 50,
        "audio didn't come back: {still_cut:?} -> {back:?}"
    );
    let fresh = turn
        .lines()
        .iter()
        .filter(|l| l.starts_with("allocated "))
        .count();
    assert!(
        fresh >= 2,
        "the restart made no new allocations ({before_restart} lines before)"
    );

    // Candidates carry our ufrag, so the peer can tell generations apart.
    let trickled: Vec<_> = call
        .offerer_seen
        .iter()
        .filter(|e| e["event"] == "call_signal" && e["type"] == "ice_candidate")
        .collect();
    assert!(!trickled.is_empty());
    assert!(
        trickled
            .iter()
            .all(|e| e["payload"]["candidate"]["usernameFragment"].is_string()),
        "{trickled:?}"
    );
    call.stop();
}

#[test]
fn call_restart_without_a_call_is_an_error() {
    let mut helper = Helper::spawn();
    let reply = helper.request(json!({"id": 1, "cmd": "call_restart"}), &mut Vec::new());
    assert_eq!(reply["error"], "no call running");
    assert_eq!(helper.close(), 0);
}

/// How long after its path dies a helper says so (`call_state`
/// `disconnected`): the server's recovery only starts then. Chrome takes
/// about 5 s; so should we.
#[test]
fn a_dead_path_is_noticed_within_seconds() {
    let mut turn = TestTurn::spawn();
    let mut call = Call::start(&turn);
    call.run(Duration::from_millis(3_500));
    turn.command("cut-all");
    let cut = Instant::now();

    let disconnected = |seen: &[Value]| {
        seen.iter()
            .any(|e| e["event"] == "call_state" && e["state"] == "disconnected")
    };
    let mut noticed = (None, None);
    while cut.elapsed() < Duration::from_secs(20) && (noticed.0.is_none() || noticed.1.is_none()) {
        call.run(Duration::from_millis(100));
        if noticed.0.is_none() && disconnected(&call.offerer_seen) {
            noticed.0 = Some(cut.elapsed());
        }
        if noticed.1.is_none() && disconnected(&call.answerer_seen) {
            noticed.1 = Some(cut.elapsed());
        }
    }
    eprintln!(
        "dead path noticed after: offerer {:?}, answerer {:?}",
        noticed.0, noticed.1
    );
    let limit = Duration::from_secs(7);
    assert!(
        noticed.0.is_some_and(|t| t < limit) && noticed.1.is_some_and(|t| t < limit),
        "noticed after {noticed:?} (limit {limit:?})"
    );
    call.stop();
}
