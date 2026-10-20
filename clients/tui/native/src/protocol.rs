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
    /// Starts a call. `ice_servers` is the channel's `ice_servers` push,
    /// accepted now and used once STUN/TURN gathering lands. `bind_ip` is for
    /// tests (`127.0.0.1`); by default the default route's address is used.
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
    },
    /// A signal from the peer, exactly as the channel's `signal` push has it.
    CallSignal {
        #[serde(rename = "type")]
        kind: String,
        #[serde(default)]
        payload: serde_json::Value,
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
}

/// Packets each way, concealment, and levels, so audio flow is visible
/// (and testable) in both directions. Counters are cumulative; peaks cover
/// the last second.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CallStats {
    pub packets_sent: u64,
    pub packets_received: u64,
    pub concealed: u64,
    pub dropped: u64,
    pub skipped_candidates: u64,
    /// UDP sends that failed (e.g. to an unreachable candidate); not fatal.
    pub send_errors: u64,
    /// Kinds of our candidates offered so far: "host", then "srflx" once a
    /// STUN server answered.
    pub local_candidates: Vec<String>,
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
    }
}
