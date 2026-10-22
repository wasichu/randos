//! Our candidates beyond the host one, and the routing they need.
//!
//! - **Server-reflexive** (`stun.rs`): our address outside the NAT, from the
//!   call's STUN servers.
//! - **Relayed** (`relay.rs`): an allocation on the call's TURN server, over
//!   UDP (`turn:`), or over TLS (`turns:`) when UDP isn't there: no `turn:`
//!   URL, or no UDP allocation within `TLS_FALLBACK_AFTER` (networks that
//!   block UDP; the UDP one keeps trying, and whichever comes up is used).
//! - **Trickle**: each new candidate goes to the peer as an `ice_candidate`
//!   once our SDP is out.
//!
//! The call socket carries STUN, TURN and str0m's traffic, so this module
//! also routes datagrams both ways. Incoming, in this order: a reply to our
//! STUN request (by transaction id), then anything from the TURN server
//! (TURN's own business, or a peer's packet relayed to us), then str0m.
//! Outgoing: str0m's packets from a relay candidate are wrapped for its TURN
//! server; everything else goes out as is. The TLS relay's traffic is a byte
//! stream instead (`Polled::stream`, `inbound_stream`, `Outbound::Stream`).
//!
//! Sans-IO like str0m: no socket, no `Rtc`. The session sends what this
//! returns, opens the TLS connection when asked, and adds the candidates it
//! finds to its `Rtc`.

use std::net::{IpAddr, SocketAddr};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use str0m::media::Mid;
use str0m::{Candidate, CandidateKind};

use crate::Error;
use crate::relay::{self, Relay, RelayEvent, TurnServer};
use crate::stun::{self, Gatherer, Reply};

/// How long a UDP allocation may take before TLS is tried as well. A
/// client-side timer that can't live on the server: it's about this
/// network's path to the TURN server. UDP answers in well under a second
/// when it works at all.
pub const TLS_FALLBACK_AFTER: Duration = Duration::from_secs(3);

/// Datagrams to send, as `(to, datagram)`.
pub type Datagrams = Vec<(SocketAddr, Vec<u8>)>;

/// A candidate of ours to add to the `Rtc`, and its kind for `call_stats`.
pub struct Found {
    pub candidate: Candidate,
    pub kind: &'static str,
}

/// What `poll` has for the session.
#[derive(Default)]
pub struct Polled {
    pub datagrams: Datagrams,
    /// Bytes for the TLS relay's stream.
    pub stream: Vec<u8>,
    /// Our new candidates (a relay, once allocated).
    pub found: Vec<Found>,
    /// Open a TCP connection to this `turns:` server, then report back with
    /// `tls_connected` (or `tls_failed`).
    pub connect_tls: Option<SocketAddr>,
}

/// What to do with something that arrived from the network.
pub enum Inbound {
    /// STUN or TURN business, done here.
    Handled,
    /// A new candidate of ours.
    Found(Found),
    /// Peers' packets relayed by TURN, as `(peer, data)`: str0m must see them
    /// as arriving at our relayed address, so ICE pairs them with the relay
    /// candidate.
    Relayed {
        destination: SocketAddr,
        packets: Vec<(SocketAddr, Vec<u8>)>,
    },
    /// For str0m, as it came.
    Direct,
}

/// How to send one of str0m's packets.
pub enum Outbound {
    /// As is, to its destination.
    Direct,
    /// Wrapped for the UDP TURN server (str0m sent it from that relay).
    Wrapped(Vec<u8>, SocketAddr),
    /// Bytes for the TLS relay's stream (str0m sent it from that relay).
    Stream(Vec<u8>),
    /// Not sendable yet (the peer's TURN permission is pending); ICE retries.
    Dropped,
}

/// The `turns:` relay, from "a server we might use" to "up".
enum Tls {
    None,
    /// Used if UDP isn't up by `TLS_FALLBACK_AFTER` after `since`.
    Standby {
        server: TurnServer,
        addr: SocketAddr,
        since: Instant,
    },
    /// The session is opening the TCP connection.
    Connecting {
        server: TurnServer,
        addr: SocketAddr,
    },
    Up(Box<Relay>),
}

pub struct Candidates {
    local: SocketAddr,
    stun: Gatherer,
    /// Our UDP TURN allocation, if the call has a `turn:` server.
    relay: Option<Relay>,
    tls: Tls,
    /// Added to the `Rtc` but not yet sent to the peer.
    unsent: Vec<String>,
    sdp_sent: bool,
    /// Every remote candidate's IP so far, to permit on a relay as soon as
    /// it's allocated (a permission asked for earlier fails quietly).
    remote_ips: Vec<IpAddr>,
    /// The peer's relayed addresses: sending to one means the call is
    /// relayed even when we aren't.
    remote_relays: Vec<SocketAddr>,
    /// Bytes str0m sent each way since the last `take_path`.
    sent_relayed: u64,
    sent_direct: u64,
}

impl Candidates {
    /// From the call's `ice_servers`: resolves the servers (DNS, so call it on
    /// the session thread) and starts STUN and the UDP TURN allocation; a
    /// `turns:` server waits as the fallback. `relay_only`: no STUN (only
    /// the relay candidate is wanted).
    pub fn from_ice_servers(ice_servers: &Value, local: SocketAddr, relay_only: bool) -> Self {
        let stun_servers = if relay_only {
            Vec::new()
        } else {
            stun::resolve(&stun::stun_servers(ice_servers), local)
        };
        let servers = relay::turn_servers(ice_servers);
        let relay = servers
            .iter()
            .find(|server| !server.tls)
            .and_then(|server| {
                Some(Relay::allocate(
                    local,
                    relay::resolve(server, local)?,
                    server,
                ))
            });
        let mut candidates = Self::new(local, stun_servers, relay);
        if let Some((server, addr)) = servers
            .into_iter()
            .filter(|server| server.tls)
            .find_map(|server| Some((relay::resolve(&server, local)?, server)).map(|(a, s)| (s, a)))
        {
            candidates.tls = Tls::Standby {
                server,
                addr,
                since: Instant::now(),
            };
        }
        candidates
    }

    pub fn new(local: SocketAddr, stun_servers: Vec<SocketAddr>, relay: Option<Relay>) -> Self {
        Self {
            local,
            stun: Gatherer::new(stun_servers, Instant::now()),
            relay,
            tls: Tls::None,
            unsent: Vec::new(),
            sdp_sent: false,
            remote_ips: Vec::new(),
            remote_relays: Vec::new(),
            sent_relayed: 0,
            sent_direct: 0,
        }
    }

    /// STUN and TURN messages due now, relay candidates once allocated, and
    /// whether to open the TLS fallback.
    pub fn poll(&mut self, now: Instant) -> Result<Polled, Error> {
        let mut polled = Polled::default();
        if !self.stun.is_done() {
            polled.datagrams = self.stun.poll_transmit(now);
        }

        if let Some(relay) = self.relay.as_mut() {
            let server = relay.server();
            polled
                .datagrams
                .extend(relay.poll_transmit().0.into_iter().map(|m| (server, m)));
            match Self::relay_event(relay, &self.remote_ips, self.local)? {
                Some(Ok(found)) => polled.found.push(found),
                Some(Err(())) => {
                    eprintln!("randos_media: TURN allocation failed (UDP)");
                    self.relay = None;
                }
                None => {}
            }
        }

        let udp_up = self.relay.as_ref().and_then(Relay::relayed).is_some();
        match std::mem::replace(&mut self.tls, Tls::None) {
            Tls::Standby {
                server,
                addr,
                since,
            } if !udp_up && (self.relay.is_none() || now >= since + TLS_FALLBACK_AFTER) => {
                polled.connect_tls = Some(addr);
                self.tls = Tls::Connecting { server, addr };
            }
            Tls::Up(mut relay) => {
                for message in relay.poll_transmit().0 {
                    polled.stream.extend(message);
                }
                match Self::relay_event(&mut relay, &self.remote_ips, self.local)? {
                    Some(Ok(found)) => polled.found.push(found),
                    Some(Err(())) => {
                        eprintln!("randos_media: TURN allocation failed (TLS)");
                        return Ok(polled);
                    }
                    None => {}
                }
                self.tls = Tls::Up(relay);
            }
            other => self.tls = other,
        }
        Ok(polled)
    }

    /// A relay's news: its candidate once allocated (permitting the remote
    /// candidates already known), or `Err` if it failed.
    fn relay_event(
        relay: &mut Relay,
        remote_ips: &[IpAddr],
        local: SocketAddr,
    ) -> Result<Option<Result<Found, ()>>, Error> {
        Ok(match relay.poll_event() {
            Some(RelayEvent::Allocated(addr)) => {
                // Candidates that arrived before the allocation: their
                // permissions couldn't be installed then. Without them the
                // peer's checks to our relayed address are dropped until
                // ICE happens to send to them first.
                for &ip in remote_ips {
                    relay.permit(ip);
                }
                Some(Ok(Found {
                    candidate: Candidate::relayed(addr, local, "udp")?,
                    kind: "relay",
                }))
            }
            Some(RelayEvent::Failed) => Some(Err(())),
            None => None,
        })
    }

    /// The session's TCP connection to the `turns:` server is open, from
    /// `local`: start the TLS allocation over it.
    pub fn tls_connected(&mut self, local: SocketAddr) -> Result<(), Error> {
        if let Tls::Connecting { server, addr } = std::mem::replace(&mut self.tls, Tls::None) {
            self.tls = Tls::Up(Box::new(Relay::allocate_tls(local, addr, &server)?));
        }
        Ok(())
    }

    /// The TCP connection to the `turns:` server couldn't be opened.
    pub fn tls_failed(&mut self) {
        eprintln!("randos_media: couldn't reach the TURN server over TLS");
        self.tls = Tls::None;
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
        Ok(Self::relayed(relay, datagram))
    }

    /// Bytes that arrived on the TLS relay's stream.
    pub fn inbound_stream(&mut self, bytes: &[u8]) -> Inbound {
        match &mut self.tls {
            Tls::Up(relay) => Self::relayed(relay, bytes),
            _ => Inbound::Handled,
        }
    }

    fn relayed(relay: &mut Relay, bytes: &[u8]) -> Inbound {
        let packets = relay.recv(bytes);
        match relay.relayed() {
            Some(destination) if !packets.is_empty() => Inbound::Relayed {
                destination,
                packets,
            },
            _ => Inbound::Handled,
        }
    }

    /// Routes one of str0m's packets (see the module docs).
    pub fn outbound(
        &mut self,
        source: SocketAddr,
        destination: SocketAddr,
        data: &[u8],
    ) -> Outbound {
        let tls_relay = match &mut self.tls {
            Tls::Up(relay) if relay.relayed() == Some(source) => Some(relay),
            _ => None,
        };
        let udp_relay = self
            .relay
            .as_mut()
            .filter(|relay| relay.relayed() == Some(source));
        let ours = tls_relay.is_some() || udp_relay.is_some();
        if ours || self.remote_relays.contains(&destination) {
            self.sent_relayed += data.len() as u64;
        } else {
            self.sent_direct += data.len() as u64;
        }
        match (udp_relay, tls_relay) {
            (Some(relay), _) => match relay.send(destination, data) {
                Ok(Some(wrapped)) => Outbound::Wrapped(wrapped, relay.server()),
                Ok(None) | Err(_) => Outbound::Dropped,
            },
            (None, Some(relay)) => match relay.send(destination, data) {
                Ok(Some(bytes)) => Outbound::Stream(bytes),
                Ok(None) | Err(_) => Outbound::Dropped,
            },
            (None, None) => Outbound::Direct,
        }
    }

    /// A remote candidate: let it reach our relayed addresses (coturn drops
    /// anything from an IP without a permission), and note whether it's the
    /// peer's relay (for `take_path`).
    pub fn remote(&mut self, candidate: &Candidate) {
        let peer = candidate.addr().ip();
        if !self.remote_ips.contains(&peer) {
            self.remote_ips.push(peer);
        }
        if candidate.kind() == CandidateKind::Relayed {
            self.remote_relays.push(candidate.addr());
        }
        if let Some(relay) = self.relay.as_mut() {
            relay.permit(peer);
        }
        if let Tls::Up(relay) = &mut self.tls {
            relay.permit(peer);
        }
    }

    /// How the call's packets went since the last call: "relay" when most
    /// bytes went through a TURN server (ours or the peer's), "direct"
    /// otherwise, `None` if nothing was sent. str0m doesn't say which pair
    /// ICE chose, so this goes by what was actually sent.
    pub fn take_path(&mut self) -> Option<&'static str> {
        let (relayed, direct) = (self.sent_relayed, self.sent_direct);
        (self.sent_relayed, self.sent_direct) = (0, 0);
        match (relayed, direct) {
            (0, 0) => None,
            (relayed, direct) if relayed > direct => Some("relay"),
            _ => Some("direct"),
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
    /// `ufrag` is our current ICE ufrag, so after a restart the peer can tell
    /// the generations apart.
    pub fn trickle(&mut self, mid: Option<Mid>, ufrag: &str) -> Vec<Value> {
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
                    "usernameFragment": ufrag,
                }})
            })
            .collect()
    }

    /// Frees the TURN allocations: what to send (datagrams, and TLS stream
    /// bytes) before the sockets go.
    pub fn close(&mut self) -> (Datagrams, Vec<u8>) {
        let datagrams = match self.relay.as_mut() {
            Some(relay) => {
                let server = relay.server();
                relay.close().into_iter().map(|m| (server, m)).collect()
            }
            None => Vec::new(),
        };
        let stream = match &mut self.tls {
            Tls::Up(relay) => relay.close().concat(),
            _ => Vec::new(),
        };
        (datagrams, stream)
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
        assert!(candidates.trickle(None, "u").is_empty(), "before our SDP");

        // An answerer: SDP sent, mid not known yet.
        candidates.sdp_sent();
        let sent = candidates.trickle(None, "u");
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0]["candidate"]["sdpMid"], Value::Null);
        assert_eq!(sent[0]["candidate"]["sdpMLineIndex"], 0);
        assert!(candidates.trickle(None, "u").is_empty(), "sent once");
    }

    #[test]
    fn a_stun_reply_is_ours_anything_else_goes_to_str0m() {
        let server: SocketAddr = "192.0.2.10:3478".parse().unwrap();
        let mut candidates = Candidates::new(local(), vec![server], None);
        let sent = candidates.poll(Instant::now()).unwrap().datagrams;
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
        let sent = candidates.poll(Instant::now()).unwrap().datagrams;
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
        let (datagrams, stream) = candidates.close();
        assert!(datagrams.is_empty() && stream.is_empty());
    }

    #[test]
    fn candidates_known_before_the_allocation_are_permitted_once_it_is_up() {
        use std::net::UdpSocket;
        use std::sync::atomic::Ordering;
        use std::time::Duration;

        let (server, seen) = crate::test_support::fake_turn_server();
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        socket
            .set_read_timeout(Some(Duration::from_millis(20)))
            .unwrap();
        let local = socket.local_addr().unwrap();
        let creds = crate::relay::TurnServer {
            host: server.to_string(),
            username: "user".into(),
            credential: "pass".into(),
            tls: false,
        };
        let mut candidates =
            Candidates::new(local, vec![], Some(Relay::allocate(local, server, &creds)));

        // The peer's candidate arrives before our allocation is up.
        let host = Candidate::host("127.0.0.1:9".parse().unwrap(), "udp").unwrap();
        candidates.remote(&host);

        let mut buf = [0u8; 1500];
        let mut allocated = false;
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline && seen.create_permissions.load(Ordering::Relaxed) == 0 {
            let polled = candidates.poll(Instant::now()).unwrap();
            allocated |= polled.found.iter().any(|f| f.kind == "relay");
            for (to, datagram) in polled.datagrams {
                socket.send_to(&datagram, to).unwrap();
            }
            if let Ok((n, from)) = socket.recv_from(&mut buf) {
                candidates.inbound(from, &buf[..n]).unwrap();
            }
        }

        assert!(allocated, "the relay came up");
        assert!(
            seen.create_permissions.load(Ordering::Relaxed) >= 1,
            "the early candidate's permission was asked for, with nothing sent to it"
        );
    }

    #[test]
    fn the_path_follows_the_bytes_through_the_peers_relay_too() {
        let mut candidates = Candidates::new(local(), vec![], None);
        assert_eq!(candidates.take_path(), None, "nothing sent yet");

        let peer_relay: SocketAddr = "198.51.100.9:50000".parse().unwrap();
        let peer_host: SocketAddr = "192.0.2.4:6000".parse().unwrap();
        let relayed = Candidate::relayed(peer_relay, "192.0.2.4:1".parse().unwrap(), "udp");
        candidates.remote(&relayed.unwrap());
        candidates.remote(&Candidate::host(peer_host, "udp").unwrap());

        // We have no relay, but the peer's relay candidate carries the media.
        candidates.outbound(local(), peer_relay, &[0; 160]);
        candidates.outbound(local(), peer_host, &[0; 40]);
        assert_eq!(candidates.take_path(), Some("relay"));

        candidates.outbound(local(), peer_host, &[0; 160]);
        assert_eq!(candidates.take_path(), Some("direct"));
        assert_eq!(candidates.take_path(), None, "counts reset each time");
    }

    #[test]
    fn tls_is_tried_only_if_udp_isnt_up_in_time() {
        // TEST-NET addresses: nothing answers (and nothing is contacted:
        // the session would open the TCP connection, not this).
        let ice = json!([{
            "urls": ["turn:192.0.2.1:3478", "turns:192.0.2.1:5349"],
            "username": "u", "credential": "c"
        }]);
        let mut candidates = Candidates::from_ice_servers(&ice, local(), true);
        let start = Instant::now();
        assert_eq!(
            candidates.poll(start).unwrap().connect_tls,
            None,
            "UDP gets its chance"
        );
        let later = start + TLS_FALLBACK_AFTER + Duration::from_millis(10);
        assert_eq!(
            candidates.poll(later).unwrap().connect_tls,
            Some("192.0.2.1:5349".parse().unwrap())
        );
        assert_eq!(
            candidates.poll(later).unwrap().connect_tls,
            None,
            "asked once"
        );

        // No turn: at all: TLS right away.
        let tls_only =
            json!([{"urls": "turns:192.0.2.1:5349", "username": "u", "credential": "c"}]);
        let mut candidates = Candidates::from_ice_servers(&tls_only, local(), true);
        assert!(
            candidates
                .poll(Instant::now())
                .unwrap()
                .connect_tls
                .is_some()
        );
    }
}
