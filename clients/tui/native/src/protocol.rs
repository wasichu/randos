//! Port message shapes: one JSON object per `frame`. The contract is the
//! README's "Port protocol"; the Elixir side is `Tui.Media.Protocol`.
//!
//! Requests carry an `id`; each gets exactly one reply echoing it. Events are
//! unsolicited and have no id.

use std::fmt;

use serde::{Deserialize, Serialize};

#[derive(Debug, PartialEq, Deserialize)]
pub struct Request {
    pub id: u64,
    #[serde(flatten)]
    pub command: Command,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    Ping,
    LoopbackStart {
        #[serde(rename = "in")]
        input: String,
        out: String,
    },
    LoopbackStop,
    /// Starts a call. `ice_servers` are the call's, from the channel's state
    /// push (STUN and TURN). `bind_ip` is for tests (`127.0.0.1`); by default
    /// the default route's address is used.
    CallStart {
        role: String,
        #[serde(default)]
        ice_servers: serde_json::Value,
        #[serde(rename = "in", default = "device")]
        input: String,
        #[serde(default = "device")]
        out: String,
        #[serde(default)]
        bind_ip: Option<String>,
        /// Only the TURN relay, never a direct connection (the call map's
        /// `ice_transport_policy` `"relay"`), so the peer never sees our IP.
        #[serde(default)]
        relay_only: bool,
    },
    /// A signal from the peer, exactly as the channel's `signal` push has it.
    CallSignal {
        #[serde(rename = "type")]
        kind: String,
        #[serde(default)]
        payload: serde_json::Value,
    },
    /// The audio devices there are: names to pass as `device:NAME`.
    Devices,
    /// Mute or unmute the mic for the running call: while muted, silence is
    /// sent (RTP keeps flowing, so the peer sees a quiet call, not a stall).
    CallMute {
        muted: bool,
    },
    /// ICE restart for the running call (obligation 10; the TUI sends it as
    /// offerer when the server's `ice_generation` grows): a new socket on
    /// the current route, fresh candidates, and a restart offer. Optional
    /// fresh `ice_servers` (a resume reply's). An answerer re-gathers by
    /// itself when a restart offer arrives.
    CallRestart {
        #[serde(default)]
        ice_servers: Option<serde_json::Value>,
    },
    CallStop,
}

fn device() -> String {
    "device".into()
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Outgoing {
    Ok {
        reply: u64,
        ok: serde_json::Value,
    },
    /// `reply` is `None` when the request was too malformed to have an id.
    Error {
        reply: Option<u64>,
        error: String,
    },
    Event(Event),
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    /// Once a second while the loopback runs.
    LoopbackStats(LoopbackStats),
    /// The loopback stopped on its own; it is no longer running.
    LoopbackFailed { error: String },
    /// Every 50 ms while the loopback runs: the mic's meter bars (`you`, as
    /// in `CallLevels`), so the TUI's mic test can be a silent meter.
    LoopbackLevels { you: Vec<f32> },
    /// A device stream reported an error (it may recover).
    StreamError { error: String },
    /// A WebRTC signal for the peer, in the participant channel's shape
    /// (`type` is `offer`, `answer`, or `ice_candidate`); relay it as-is.
    CallSignal {
        #[serde(rename = "type")]
        kind: String,
        payload: serde_json::Value,
    },
    /// `connected`, `disconnected` (may recover), or `failed` (the call's
    /// session has stopped; `reason` says why).
    CallState {
        state: String,
        reason: Option<String>,
    },
    /// Once a second during a call.
    CallStats(CallStats),
    /// Every 50 ms during a call: the audio meters' bars, each 0..1, lowest
    /// frequencies first (12 each, the website visualizer's numbers): `you`
    /// as sent, `peer` as played.
    CallLevels { you: Vec<f32>, peer: Vec<f32> },
}

/// Packets each way, concealment, and levels, so audio flow is visible
/// (and testable) in both directions. Counters are cumulative; peaks cover
/// the last second.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CallStats {
    pub packets_sent: u64,
    pub packets_received: u64,
    pub concealed: u64,
    /// Lost frames rebuilt from the next packet's in-band FEC.
    pub recovered: u64,
    pub dropped: u64,
    pub skipped_candidates: u64,
    /// UDP sends that failed (e.g. to an unreachable candidate); not fatal.
    pub send_errors: u64,
    /// Kinds of our candidates offered since the call started or its latest
    /// restart: "host" (not in a relay-only call), then "srflx" once a STUN
    /// server answered and "relay" once a TURN allocation succeeded.
    pub local_candidates: Vec<String>,
    /// How this second's packets went: "direct", or "relay" (through a TURN
    /// server, ours or the peer's); `null` if nothing was sent.
    pub path: Option<String>,
    pub input_peak_dbfs: f64,
    pub output_peak_dbfs: f64,
    pub capture_ring_ms: f64,
    pub playback_ring_ms: f64,
}

/// Where the loopback's latency goes, in milliseconds, plus health counters.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LoopbackStats {
    pub latency_ms: f64,
    pub capture_device_ms: f64,
    pub capture_ring_ms: f64,
    pub codec_ms: f64,
    /// Added by converting a non-48 kHz device to and from Opus's rate.
    pub resample_ms: f64,
    pub playback_ring_ms: f64,
    pub playback_device_ms: f64,
    pub kbps: f64,
    pub input_peak_dbfs: f64,
    pub underruns: u64,
    pub overruns: u64,
    pub dropped: u64,
}

/// Parses a request. On failure, returns the request's id if one could be
/// read, so the error can still be paired with its caller.
pub fn parse(body: &[u8]) -> Result<Request, (Option<u64>, String)> {
    serde_json::from_slice(body).map_err(|err| {
        let id = serde_json::from_slice::<serde_json::Value>(body)
            .ok()
            .and_then(|value| value.get("id")?.as_u64());
        (id, format!("invalid request: {err}"))
    })
}

pub fn encode(message: &Outgoing) -> serde_json::Result<Vec<u8>> {
    serde_json::to_vec(message)
}

impl fmt::Display for Event {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Event::LoopbackStats(s) => write!(
                f,
                "≈{:.1} ms = capture {:.1} + ring {:.1} + codec {} + resample {:.1} + ring {:.1} + \
                 playback {:.1} | {:.0} kbps, input peak {:.0} dBFS | underruns {} overruns {} dropped {}",
                s.latency_ms,
                s.capture_device_ms,
                s.capture_ring_ms,
                s.codec_ms,
                s.resample_ms,
                s.playback_ring_ms,
                s.playback_device_ms,
                s.kbps,
                s.input_peak_dbfs,
                s.underruns,
                s.overruns,
                s.dropped
            ),
            Event::LoopbackFailed { error } => write!(f, "loopback failed: {error}"),
            Event::LoopbackLevels { .. } => write!(f, "loopback levels"),
            Event::StreamError { error } => write!(f, "stream error: {error}"),
            Event::CallSignal { kind, .. } => write!(f, "signal out: {kind}"),
            Event::CallState { state, reason } => match reason {
                Some(reason) => write!(f, "call {state}: {reason}"),
                None => write!(f, "call {state}"),
            },
            Event::CallStats(s) => write!(
                f,
                "call: sent {} received {} concealed {} | in {:.0} dBFS out {:.0} dBFS",
                s.packets_sent,
                s.packets_received,
                s.concealed,
                s.input_peak_dbfs,
                s.output_peak_dbfs
            ),
            Event::CallLevels { .. } => write!(f, "call levels"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_commands() {
        assert_eq!(
            parse(br#"{"id":1,"cmd":"ping"}"#),
            Ok(Request {
                id: 1,
                command: Command::Ping
            })
        );
        assert_eq!(
            parse(br#"{"id":2,"cmd":"loopback_start","in":"sine","out":"null"}"#),
            Ok(Request {
                id: 2,
                command: Command::LoopbackStart {
                    input: "sine".into(),
                    out: "null".into()
                }
            })
        );
        assert_eq!(
            parse(br#"{"id":4,"cmd":"devices"}"#),
            Ok(Request {
                id: 4,
                command: Command::Devices
            })
        );
        assert_eq!(
            parse(br#"{"id":3,"cmd":"call_mute","muted":true}"#),
            Ok(Request {
                id: 3,
                command: Command::CallMute { muted: true }
            })
        );
        assert_eq!(
            parse(br#"{"id":5,"cmd":"call_restart"}"#),
            Ok(Request {
                id: 5,
                command: Command::CallRestart { ice_servers: None }
            })
        );
        assert_eq!(
            parse(br#"{"id":6,"cmd":"call_restart","ice_servers":[{"urls":"stun:x"}]}"#),
            Ok(Request {
                id: 6,
                command: Command::CallRestart {
                    ice_servers: Some(serde_json::json!([{"urls": "stun:x"}]))
                }
            })
        );
    }

    #[test]
    fn call_start_is_direct_unless_relay_only() {
        let relay_only = |line: &[u8]| match parse(line) {
            Ok(Request {
                command: Command::CallStart { relay_only, .. },
                ..
            }) => Some(relay_only),
            _ => None,
        };
        assert_eq!(
            relay_only(br#"{"id":5,"cmd":"call_start","role":"offerer","relay_only":true}"#),
            Some(true)
        );
        assert_eq!(
            relay_only(br#"{"id":6,"cmd":"call_start","role":"offerer"}"#),
            Some(false)
        );
    }

    #[test]
    fn bad_requests_keep_their_id_when_they_have_one() {
        assert!(matches!(
            parse(br#"{"id":7,"cmd":"dance"}"#),
            Err((Some(7), _))
        ));
        assert!(matches!(parse(b"not json"), Err((None, _))));
    }

    #[test]
    fn encodes_replies_and_events() {
        let as_json = |message| {
            serde_json::from_slice::<serde_json::Value>(&encode(&message).unwrap()).unwrap()
        };

        assert_eq!(
            as_json(Outgoing::Ok {
                reply: 1,
                ok: json!("pong")
            }),
            json!({"reply": 1, "ok": "pong"})
        );
        assert_eq!(
            as_json(Outgoing::Error {
                reply: None,
                error: "nope".into()
            }),
            json!({"reply": null, "error": "nope"})
        );
        assert_eq!(
            as_json(Outgoing::Event(Event::LoopbackFailed {
                error: "gone".into()
            })),
            json!({"event": "loopback_failed", "error": "gone"})
        );
        assert_eq!(
            as_json(Outgoing::Event(Event::LoopbackLevels {
                you: vec![0.5, 0.0]
            })),
            json!({"event": "loopback_levels", "you": [0.5, 0.0]})
        );
    }
}
