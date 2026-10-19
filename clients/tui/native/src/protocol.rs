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
}

/// Where the loopback's latency goes, in milliseconds, plus health counters.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LoopbackStats {
    pub latency_ms: f64,
    pub capture_device_ms: f64,
    pub capture_ring_ms: f64,
    pub codec_ms: f64,
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
                "≈{:.1} ms = capture {:.1} + ring {:.1} + codec {} + ring {:.1} + playback {:.1} | \
                 {:.0} kbps, input peak {:.0} dBFS | underruns {} overruns {} dropped {}",
                s.latency_ms,
                s.capture_device_ms,
                s.capture_ring_ms,
                s.codec_ms,
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
