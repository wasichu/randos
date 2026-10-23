//! A relay-only helper↔helper call through the test TURN server
//! (`examples/test_turn.rs`): the relay carries the call, and a cut stops
//! it, as a network change does. ICE restart recovers it (`call_restart`).
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]

use std::time::{Duration, Instant};

use serde_json::{Value, json};

mod common;
use common::{Call, Helper, TestTurn};

#[test]
fn the_test_relay_carries_a_relay_only_call_and_a_cut_stops_it() {
    let mut turn = TestTurn::spawn();
    let mut call = Call::start(&turn.ice_servers(), true);
    call.connect();
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
    let mut call = Call::start(&turn.ice_servers(), true);
    call.connect();

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
    let came_back = call.run_until(Duration::from_secs(10), |call| {
        let now = call.received();
        now.0 - still_cut.0 > 50 && now.1 - still_cut.1 > 50
    });
    let back = call.received();
    assert!(
        came_back,
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
        .offerer
        .seen
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
    let mut call = Call::start(&turn.ice_servers(), true);
    call.connect();
    turn.command("cut-all");
    let cut = Instant::now();

    let disconnected = |seen: &[Value]| {
        seen.iter()
            .any(|e| e["event"] == "call_state" && e["state"] == "disconnected")
    };
    let mut noticed = (None, None);
    while cut.elapsed() < Duration::from_secs(20) && (noticed.0.is_none() || noticed.1.is_none()) {
        call.run(Duration::from_millis(100));
        if noticed.0.is_none() && disconnected(&call.offerer.seen) {
            noticed.0 = Some(cut.elapsed());
        }
        if noticed.1.is_none() && disconnected(&call.answerer.seen) {
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
