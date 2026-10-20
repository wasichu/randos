//! Relayed candidates: a TURN allocation (RFC 8656) on one of the call's
//! `turn:` servers, for networks where peers can't reach each other directly
//! (symmetric NATs, strict firewalls). The relay gives us an address on the
//! TURN server; peers send to it, and the server forwards to us.
//!
//! A thin wrapper over `turn-client-proto` (sans-IO, like str0m): it owns no
//! socket and no timers. The call session sends what `poll_transmit` returns
//! from its call socket, hands back datagrams from the TURN server via `recv`,
//! and routes str0m's packets whose source is the relayed address through
//! `send`. It also hides the crate's own clock: everything here takes and
//! returns std `Instant`s.
//!
//! One allocation per call, on the first UDP `turn:` server: one relay is
//! enough to reach any peer, and each allocation holds a port on coturn.
//! Data goes in Send/Data indications (no channel binding: 36 bytes more per
//! packet is nothing at 50 packets a second).

use std::net::{IpAddr, SocketAddr, ToSocketAddrs};
use std::time::Instant as StdInstant;

use serde_json::Value;
use stun_types::attribute::ErrorCode;
use stun_types::message::{Message, MessageClass, TransactionId};
use turn_client_proto::api::{TurnConfig, TurnEvent, TurnPollRet, TurnRecvRet};
use turn_client_proto::prelude::TurnClientApi;
use turn_client_proto::stun::Instant as TurnInstant;
use turn_client_proto::stun::agent::Transmit;
use turn_client_proto::stun::types::TransportType;
use turn_client_proto::types::TurnCredentials;
use turn_client_proto::types::message::ALLOCATE;
use turn_client_proto::udp::TurnClientUdp;

use crate::Error;

/// A `turn:` server from the call's `ice_servers`, with its credentials.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnServer {
    /// `host:port`.
    pub host: String,
    pub username: String,
    pub credential: String,
}

/// Every UDP `turn:` server in the channel's `ice_servers`
/// (`[{"urls": "turn:…" | ["…"], "username", "credential"}]`). `turns:`
/// (TLS) and `?transport=tcp` aren't UDP and are skipped; the default port
/// is 3478. Entries without credentials are skipped (TURN requires them).
pub fn turn_servers(ice_servers: &Value) -> Vec<TurnServer> {
    let mut servers = Vec::new();
    for entry in ice_servers.as_array().into_iter().flatten() {
        let (Some(username), Some(credential)) = (
            entry.get("username").and_then(Value::as_str),
            entry.get("credential").and_then(Value::as_str),
        ) else {
            continue;
        };
        let urls = match entry.get("urls") {
            Some(Value::String(url)) => vec![url.as_str()],
            Some(Value::Array(urls)) => urls.iter().filter_map(Value::as_str).collect(),
            _ => vec![],
        };
        for url in urls {
            let Some(rest) = url.strip_prefix("turn:") else {
                continue;
            };
            let (host, query) = rest.split_once('?').unwrap_or((rest, ""));
            if query.split('&').any(|param| param == "transport=tcp") {
                continue;
            }
            let has_port = host
                .rsplit_once(':')
                .is_some_and(|(_, port)| port.parse::<u16>().is_ok());
            servers.push(TurnServer {
                host: if has_port {
                    host.to_owned()
                } else {
                    format!("{host}:3478")
                },
                username: username.to_owned(),
                credential: credential.to_owned(),
            });
        }
    }
    servers
}

/// The server's address, in the same family as `local`.
pub fn resolve(server: &TurnServer, local: SocketAddr) -> Option<SocketAddr> {
    server
        .host
        .to_socket_addrs()
        .ok()?
        .find(|addr| addr.is_ipv4() == local.is_ipv4())
}

/// What happened to the allocation since the last `poll_event`s.
#[derive(Debug, PartialEq, Eq)]
pub enum RelayEvent {
    /// The relay is up: peers can reach us at this address.
    Allocated(SocketAddr),
    /// The server refused our credentials, or never answered (after the
    /// crate's transaction timeout, ~40 s). The call never waits on the relay.
    Failed,
}

/// One TURN allocation.
pub struct Relay {
    client: TurnClientUdp,
    server: SocketAddr,
    local: SocketAddr,
    /// The TURN crate's clock counts from here.
    base: StdInstant,
    relayed: Option<SocketAddr>,
    /// The 401 that answered our first, unauthenticated Allocate (the
    /// normal start: it carries the realm and nonce).
    challenge: Option<TransactionId>,
    /// coturn refused our credentials: reported as `Failed` right away.
    refused: bool,
}

impl Relay {
    pub fn allocate(local: SocketAddr, server: SocketAddr, credentials: &TurnServer) -> Self {
        let config = TurnConfig::new(TurnCredentials::new(
            &credentials.username,
            &credentials.credential,
        ));
        Self {
            client: TurnClientUdp::allocate(local, server, config),
            server,
            local,
            base: StdInstant::now(),
            relayed: None,
            challenge: None,
            refused: false,
        }
    }

    fn now(&self) -> TurnInstant {
        TurnInstant::from_std(self.base)
    }

    pub fn server(&self) -> SocketAddr {
        self.server
    }

    /// Our address on the TURN server, once allocated.
    pub fn relayed(&self) -> Option<SocketAddr> {
        self.relayed
    }

    /// Messages for the TURN server due now (allocate, refresh, permissions,
    /// retransmits), and when to call again.
    pub fn poll_transmit(&mut self) -> (Vec<Vec<u8>>, Option<StdInstant>) {
        let now = self.now();
        let wake = match self.client.poll(now) {
            TurnPollRet::WaitUntil(at) => Some(at.to_std(self.base)),
            _ => None,
        };
        let mut out = Vec::new();
        while let Some(transmit) = self.client.poll_transmit(now) {
            out.push(transmit.data.as_ref().to_vec());
        }
        (out, wake)
    }

    pub fn poll_event(&mut self) -> Option<RelayEvent> {
        if self.refused && self.relayed.is_none() {
            self.refused = false;
            return Some(RelayEvent::Failed);
        }
        loop {
            return match self.client.poll_event()? {
                TurnEvent::AllocationCreated(TransportType::Udp, addr) => {
                    self.relayed = Some(addr);
                    Some(RelayEvent::Allocated(addr))
                }
                // Allocations are per address family: an IPv6 failure after
                // an IPv4 success isn't a failed relay.
                TurnEvent::AllocationCreateFailed(_) if self.relayed.is_none() => {
                    Some(RelayEvent::Failed)
                }
                // Permissions are created on demand in `send`; nothing to report.
                _ => continue,
            };
        }
    }

    /// A datagram from the TURN server. Returns peer data relayed to us, as
    /// `(peer, data)`, for str0m; `None` if it was TURN's own business.
    pub fn recv(&mut self, datagram: &[u8]) -> Option<(SocketAddr, Vec<u8>)> {
        let now = self.now();
        let transmit = Transmit {
            data: datagram,
            transport: TransportType::Udp,
            from: self.server,
            to: self.local,
        };
        let unauthorized = allocate_unauthorized(datagram);
        match self.client.recv(transmit, now) {
            TurnRecvRet::PeerData(peer_data) => Some((peer_data.peer, peer_data.data().to_vec())),
            TurnRecvRet::Handled if self.challenge.is_none() => {
                self.challenge = unauthorized;
                None
            }
            // Fail fast on refused credentials. The crate ignores a 401 to
            // its authenticated Allocate (it can't verify an unsigned reply)
            // and retries until its transaction timeout, ~40 s; coturn holds
            // no allocation either way, so we stop now. A 401 for the first
            // transaction is only a late reply to a resend of it.
            TurnRecvRet::Ignored(_) => {
                if unauthorized.is_some() && unauthorized != self.challenge {
                    self.refused = true;
                }
                None
            }
            _ => None,
        }
    }

    /// Lets `peer` send to our relayed address (coturn drops anything from
    /// an address without a permission). Called for each remote candidate,
    /// so the peer's first checks get through.
    pub fn permit(&mut self, peer: IpAddr) {
        if !self.client.have_permission(TransportType::Udp, peer) {
            // Already pending is fine; a real failure shows as no relay pair.
            let _ = self
                .client
                .create_permission(TransportType::Udp, peer, self.now());
        }
    }

    /// Frees the allocation on the server (a Refresh with lifetime 0), so it
    /// doesn't hold a port there for its remaining lifetime. Returns the
    /// messages to send.
    pub fn close(&mut self) -> Vec<Vec<u8>> {
        let _ = self.client.delete(self.now());
        self.poll_transmit().0
    }

    /// Wraps `data` for `peer` (a str0m packet from the relayed address) as a
    /// message for the TURN server. Creates the peer's permission first if
    /// needed; until it's installed, `None` (ICE retries the check).
    pub fn send(&mut self, peer: SocketAddr, data: &[u8]) -> Result<Option<Vec<u8>>, Error> {
        if !self.client.have_permission(TransportType::Udp, peer.ip()) {
            self.permit(peer.ip());
            return Ok(None);
        }
        let now = self.now();
        Ok(self
            .client
            .send_to(TransportType::Udp, peer, data, now)
            .map_err(|err| format!("relay send: {err:?}"))?
            .map(|transmit| transmit.build().data))
    }
}

/// The transaction of an Allocate error response with 401 Unauthorized.
fn allocate_unauthorized(datagram: &[u8]) -> Option<TransactionId> {
    let message = Message::from_bytes(datagram).ok()?;
    let unauthorized = message.has_method(ALLOCATE)
        && message.has_class(MessageClass::Error)
        && message
            .attribute::<ErrorCode>()
            .is_ok_and(|error| error.code() == ErrorCode::UNAUTHORIZED);
    unauthorized.then(|| message.transaction_id())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::net::UdpSocket;
    use std::thread;
    use std::time::{Duration, Instant};

    #[test]
    fn udp_turn_servers_with_credentials_from_the_channels_ice_servers() {
        let ice = json!([
            {"urls": "stun:stun.l.google.com:19302"},
            {"urls": ["turn:turn.example.org", "turn:turn.example.org:3478?transport=udp",
                      "turn:turn.example.org:3478?transport=tcp", "turns:turn.example.org:5349"],
             "username": "1700000000:anon", "credential": "secret"},
            {"urls": "turn:no-credentials.example.org"},
        ]);

        let servers = turn_servers(&ice);
        assert_eq!(
            servers.iter().map(|s| s.host.as_str()).collect::<Vec<_>>(),
            vec!["turn.example.org:3478", "turn.example.org:3478"]
        );
        assert_eq!(servers[0].username, "1700000000:anon");
        assert_eq!(servers[0].credential, "secret");
        assert!(turn_servers(&json!(null)).is_empty());
    }

    /// Drives a lone `Relay` over a real socket for up to `time`, until it
    /// reports an event. Also returns how many datagrams the server sent us.
    fn allocate(
        server: SocketAddr,
        user: &str,
        pass: &str,
        time: Duration,
    ) -> (Option<RelayEvent>, usize) {
        let bind = if server.ip().is_loopback() {
            "127.0.0.1:0"
        } else {
            "0.0.0.0:0"
        };
        let socket = UdpSocket::bind(bind).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_millis(20)))
            .unwrap();
        let local = socket.local_addr().unwrap();
        let creds = TurnServer {
            host: server.to_string(),
            username: user.into(),
            credential: pass.into(),
        };
        let mut relay = Relay::allocate(local, server, &creds);
        let deadline = Instant::now() + time;
        let (mut buf, mut received) = ([0u8; 1500], 0);
        while Instant::now() < deadline {
            for message in relay.poll_transmit().0 {
                socket.send_to(&message, server).unwrap();
            }
            if let Some(event) = relay.poll_event() {
                return (Some(event), received);
            }
            if let Ok((n, _)) = socket.recv_from(&mut buf) {
                received += 1;
                relay.recv(&buf[..n]);
            }
        }
        (None, received)
    }

    #[test]
    fn a_relay_needs_the_right_credentials() {
        let (turn, _) = crate::test_support::fake_turn_server();
        let (event, _) = allocate(turn, "user", "pass", Duration::from_secs(2));
        assert!(matches!(event, Some(RelayEvent::Allocated(_))), "{event:?}");
        // Refused: reported at once, not after the crate's ~40 s timeout.
        let (event, _) = allocate(turn, "user", "wrong", Duration::from_secs(1));
        assert_eq!(event, Some(RelayEvent::Failed));
    }

    #[test]
    fn a_late_copy_of_the_first_challenge_is_not_a_refusal() {
        let (turn, _) = crate::test_support::fake_turn_server();
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let creds = TurnServer {
            host: turn.to_string(),
            username: "user".into(),
            credential: "pass".into(),
        };
        let mut relay = Relay::allocate(socket.local_addr().unwrap(), turn, &creds);
        let mut buf = [0u8; 1500];

        // The unauthenticated Allocate and its 401 challenge.
        for message in relay.poll_transmit().0 {
            socket.send_to(&message, turn).unwrap();
        }
        let n = socket.recv_from(&mut buf).unwrap().0;
        let challenge = buf[..n].to_vec();
        assert!(allocate_unauthorized(&challenge).is_some());
        relay.recv(&challenge);

        // The same 401 again (a reply to a resend of the first request).
        relay.recv(&challenge);
        assert_eq!(relay.poll_event(), None);
    }

    /// The reachability check that needs no secret: coturn answers, and
    /// refuses made-up credentials.
    #[test]
    #[ignore = "talks to the real coturn (bogus credentials, no secret)"]
    fn production_turn_answers_and_refuses_bogus_credentials() {
        let server = "turn.slowinput.org:3478"
            .to_socket_addrs()
            .unwrap()
            .find(SocketAddr::is_ipv4)
            .unwrap();
        let (event, received) = allocate(server, "0:bogus", "bogus", Duration::from_secs(3));
        assert_eq!(
            event,
            Some(RelayEvent::Failed),
            "coturn answered {received} times"
        );
    }

    /// The checkpoint: two relays on the real coturn, one sending to the
    /// other's relayed address (allocate, permissions, Send/Data
    /// indications, all against the server we run). Credentials from
    /// `TURN_TEST_USERNAME`/`TURN_TEST_CREDENTIAL` (TURN REST, as the
    /// server issues them); see the README for the command.
    #[test]
    #[ignore = "needs coturn credentials in the environment"]
    fn production_turn_relays_data_between_two_allocations() {
        let user = std::env::var("TURN_TEST_USERNAME").unwrap();
        let pass = std::env::var("TURN_TEST_CREDENTIAL").unwrap();
        let server = "turn.slowinput.org:3478"
            .to_socket_addrs()
            .unwrap()
            .find(SocketAddr::is_ipv4)
            .unwrap();
        let creds = TurnServer {
            host: server.to_string(),
            username: user,
            credential: pass,
        };

        let peers: Vec<(UdpSocket, Relay)> = (0..2)
            .map(|_| {
                let socket = UdpSocket::bind("0.0.0.0:0").unwrap();
                socket.set_nonblocking(true).unwrap();
                let relay = Relay::allocate(socket.local_addr().unwrap(), server, &creds);
                (socket, relay)
            })
            .collect();
        let mut peers = peers;
        let mut buf = [0u8; 1500];
        let mut received = None;
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline && received.is_none() {
            let relayed: Vec<Option<SocketAddr>> = peers.iter().map(|(_, r)| r.relayed()).collect();
            for (i, (socket, relay)) in peers.iter_mut().enumerate() {
                for message in relay.poll_transmit().0 {
                    socket.send_to(&message, server).unwrap();
                }
                if let Some(RelayEvent::Failed) = relay.poll_event() {
                    panic!("allocation {i} failed");
                }
                if let Ok((n, _)) = socket.recv_from(&mut buf)
                    && let Some((from, data)) = relay.recv(&buf[..n])
                {
                    received = Some((i, from, data));
                }
                // Each lets the other in; peer 0 keeps sending to peer 1.
                if let Some(other) = relayed[1 - i] {
                    relay.permit(other.ip());
                    if i == 0
                        && let Some(wrapped) = relay.send(other, b"hello through coturn").unwrap()
                    {
                        socket.send_to(&wrapped, server).unwrap();
                    }
                }
            }
            thread::sleep(Duration::from_millis(20));
        }

        let (to, from, data) = received.expect("no data relayed within 10 s");
        assert_eq!(
            (to, data.as_slice()),
            (1, b"hello through coturn".as_slice())
        );
        assert_eq!(Some(from), peers[0].1.relayed());
        for (socket, relay) in &mut peers {
            for message in relay.close() {
                let _ = socket.send_to(&message, server);
            }
        }
    }
}
