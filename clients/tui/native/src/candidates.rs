//! Our candidates beyond the host one, and the datagram routing they need.
//!
//! - **Server-reflexive** (`stun.rs`): our address outside the NAT, from the
//!   call's STUN servers.
//! - **Relayed** (`relay.rs`): an allocation on the call's TURN server.
//! - **Trickle**: each new candidate goes to the peer as an `ice_candidate`
//!   once our SDP is out.
//!
//! The call socket carries STUN, TURN and str0m's traffic, so this module
//! also routes datagrams both ways. Incoming, in this order: a reply to our
//! STUN request (by transaction id), then anything from the TURN server
//! (TURN's own business, or a peer's packet relayed to us), then str0m.
//! Outgoing: str0m's packets from the relay candidate are wrapped for the
//! TURN server; everything else goes out as is.
//!
//! Sans-IO like str0m: no socket, no `Rtc`. The session sends what this
//! returns and adds the candidates it finds to its `Rtc`.

use std::net::{IpAddr, SocketAddr};
use std::time::Instant;

use serde_json::{Value, json};
use str0m::Candidate;
use str0m::media::Mid;

use crate::Error;
use crate::relay::{self, Relay, RelayEvent};
use crate::stun::{self, Gatherer, Reply};

/// Datagrams to send, as `(to, datagram)`.
pub type Datagrams = Vec<(SocketAddr, Vec<u8>)>;

/// A candidate of ours to add to the `Rtc`, and its kind for `call_stats`.
pub struct Found {
    pub candidate: Candidate,
    pub kind: &'static str,
}

/// What to do with a datagram that arrived on the call socket.
pub enum Inbound {
    /// STUN or TURN business, done here.
    Handled,
    /// A new candidate of ours.
    Found(Found),
    /// A peer's packet relayed by TURN: str0m must see it as arriving at our
    /// relayed address, so ICE pairs it with the relay candidate.
    Relayed {
        source: SocketAddr,
        destination: SocketAddr,
        data: Vec<u8>,
    },
    /// For str0m, as it came.
    Direct,
}

/// How to send one of str0m's packets.
pub enum Outbound {
    /// As is, to its destination.
    Direct,
    /// Wrapped for the TURN server (str0m sent it from the relay candidate).
    Wrapped(Vec<u8>, SocketAddr),
    /// Not sendable yet (the peer's TURN permission is pending); ICE retries.
    Dropped,
}

pub struct Candidates {
    local: SocketAddr,
    stun: Gatherer,
    /// Our TURN allocation, if the call has a `turn:` server.
    relay: Option<Relay>,
    /// Added to the `Rtc` but not yet sent to the peer.
    unsent: Vec<String>,
    sdp_sent: bool,
}

impl Candidates {
    /// From the call's `ice_servers`: resolves the servers (DNS, so call it on
    /// the session thread) and starts STUN and the TURN allocation.
    /// `relay_only`: no STUN (only the relay candidate is wanted).
    pub fn from_ice_servers(ice_servers: &Value, local: SocketAddr, relay_only: bool) -> Self {
        let stun_servers = if relay_only {
            Vec::new()
        } else {
            stun::resolve(&stun::stun_servers(ice_servers), local)
        };
        let relay = relay::turn_servers(ice_servers).first().and_then(|server| {
            Some(Relay::allocate(
                local,
                relay::resolve(server, local)?,
                server,
            ))
        });
        Self::new(local, stun_servers, relay)
    }

    pub fn new(local: SocketAddr, stun_servers: Vec<SocketAddr>, relay: Option<Relay>) -> Self {
        Self {
            local,
            stun: Gatherer::new(stun_servers, Instant::now()),
            relay,
            unsent: Vec::new(),
            sdp_sent: false,
        }
    }

    /// STUN and TURN messages due now, and the relay
    /// candidate once the allocation is up.
    pub fn poll(&mut self, now: Instant) -> Result<(Datagrams, Option<Found>), Error> {
        let mut out = if self.stun.is_done() {
            Vec::new()
        } else {
            self.stun.poll_transmit(now)
        };
        let Some(relay) = self.relay.as_mut() else {
            return Ok((out, None));
        };
        let server = relay.server();
        out.extend(relay.poll_transmit().0.into_iter().map(|m| (server, m)));
        let found = match relay.poll_event() {
            Some(RelayEvent::Allocated(addr)) => Some(Found {
                candidate: Candidate::relayed(addr, self.local, "udp")?,
                kind: "relay",
            }),
            Some(RelayEvent::Failed) => {
                eprintln!("randos_media: TURN allocation failed; no relay candidate");
                self.relay = None;
                None
            }
            None => None,
        };
        Ok((out, found))
    }

    /// Routes a datagram that arrived from `source` (see the module docs).
    pub fn inbound(&mut self, source: SocketAddr, datagram: &[u8]) -> Result<Inbound, Error> {
        match self.stun.handle(datagram) {
            // Not behind a NAT (or a test): the host candidate covers it.
            Reply::Mapped(mapped) if mapped == self.local => return Ok(Inbound::Handled),
            Reply::Mapped(mapped) => {
                let candidate = Candidate::server_reflexive(mapped, self.local, "udp")?;
                return Ok(Inbound::Found(Found {
                    candidate,
                    kind: "srflx",
                }));
            }
            Reply::Failed => return Ok(Inbound::Handled),
            Reply::NotOurs => {}
        }
        let Some(relay) = self.relay.as_mut().filter(|r| r.server() == source) else {
            return Ok(Inbound::Direct);
        };
        let relayed = relay.relayed();
        Ok(match (relay.recv(datagram), relayed) {
            (Some((source, data)), Some(destination)) => Inbound::Relayed {
                source,
                destination,
                data,
            },
            _ => Inbound::Handled,
        })
    }

    /// Routes one of str0m's packets (see the module docs).
    pub fn outbound(
        &mut self,
        source: SocketAddr,
        destination: SocketAddr,
        data: &[u8],
    ) -> Outbound {
        match self.relay.as_mut() {
            Some(relay) if relay.relayed() == Some(source) => match relay.send(destination, data) {
                Ok(Some(wrapped)) => Outbound::Wrapped(wrapped, relay.server()),
                Ok(None) | Err(_) => Outbound::Dropped,
            },
            _ => Outbound::Direct,
        }
    }

    /// A remote candidate: let it reach our relayed address (coturn drops
    /// anything from an IP without a permission).
    pub fn permit(&mut self, peer: IpAddr) {
        if let Some(relay) = self.relay.as_mut() {
            relay.permit(peer);
        }
    }

    /// The `Rtc` took one of our `Found` candidates: trickle it.
    pub fn added(&mut self, sdp: String) {
        self.unsent.push(sdp);
    }

    /// Our offer or answer has gone out, so candidates may follow it.
    pub fn sdp_sent(&mut self) {
        self.sdp_sent = true;
    }

    /// `ice_candidate` payloads to send now. Not gated on knowing the mid:
    /// an answerer learns it only later (str0m's `MediaAdded`), and a
    /// candidate held back until then never reaches the peer, who then never
    /// permits it on TURN. One m-line, so `sdpMLineIndex` 0 identifies it.
    pub fn trickle(&mut self, mid: Option<Mid>) -> Vec<Value> {
        if !self.sdp_sent {
            return Vec::new();
        }
        let mid = mid.map(|mid| mid.to_string());
        std::mem::take(&mut self.unsent)
            .into_iter()
            .map(|candidate| {
                json!({"candidate": {
                    "candidate": candidate,
                    "sdpMid": mid,
                    "sdpMLineIndex": 0,
                    "usernameFragment": null,
                }})
            })
            .collect()
    }

    /// Frees the TURN allocation: the messages to send before the socket goes.
    pub fn close(&mut self) -> Datagrams {
        let Some(relay) = self.relay.as_mut() else {
            return Vec::new();
        };
        let server = relay.server();
        relay.close().into_iter().map(|m| (server, m)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::stun_reply;

    fn local() -> SocketAddr {
        "127.0.0.1:5000".parse().unwrap()
    }

    #[test]
    fn candidates_wait_for_our_sdp_but_not_for_the_mid() {
        let mut candidates = Candidates::new(local(), vec![], None);
        candidates.added("candidate:1 1 udp 1 203.0.113.7 4000 typ srflx".into());
        assert!(candidates.trickle(None).is_empty(), "before our SDP");

        // An answerer: SDP sent, mid not known yet.
        candidates.sdp_sent();
        let sent = candidates.trickle(None);
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0]["candidate"]["sdpMid"], Value::Null);
        assert_eq!(sent[0]["candidate"]["sdpMLineIndex"], 0);
        assert!(candidates.trickle(None).is_empty(), "sent once");
    }

    #[test]
    fn a_stun_reply_is_ours_anything_else_goes_to_str0m() {
        let server: SocketAddr = "192.0.2.10:3478".parse().unwrap();
        let mut candidates = Candidates::new(local(), vec![server], None);
        let (sent, _) = candidates.poll(Instant::now()).unwrap();
        let request = &sent[0].1;

        let reply = stun_reply(request, "203.0.113.7:4000".parse().unwrap());
        let Inbound::Found(found) = candidates.inbound(server, &reply).unwrap() else {
            panic!("a reply to our request is a candidate");
        };
        assert_eq!(found.kind, "srflx");
        assert_eq!(found.candidate.addr(), "203.0.113.7:4000".parse().unwrap());

        // The same reply again (a retransmit's answer) is no longer ours.
        assert!(matches!(
            candidates.inbound(server, &reply).unwrap(),
            Inbound::Direct
        ));
        assert!(matches!(
            candidates.inbound(server, b"rtp").unwrap(),
            Inbound::Direct
        ));
    }

    #[test]
    fn our_own_address_back_from_stun_adds_nothing() {
        let server: SocketAddr = "192.0.2.10:3478".parse().unwrap();
        let mut candidates = Candidates::new(local(), vec![server], None);
        let (sent, _) = candidates.poll(Instant::now()).unwrap();
        let reply = stun_reply(&sent[0].1, local());
        assert!(matches!(
            candidates.inbound(server, &reply).unwrap(),
            Inbound::Handled
        ));
    }

    #[test]
    fn without_a_relay_everything_goes_out_direct() {
        let mut candidates = Candidates::new(local(), vec![], None);
        let peer = "198.51.100.1:6000".parse().unwrap();
        assert!(matches!(
            candidates.outbound(local(), peer, b"x"),
            Outbound::Direct
        ));
        assert!(candidates.close().is_empty());
    }
}
