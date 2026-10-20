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
use turn_client_proto::api::{TurnConfig, TurnEvent, TurnPollRet, TurnRecvRet};
use turn_client_proto::prelude::TurnClientApi;
use turn_client_proto::stun::Instant as TurnInstant;
use turn_client_proto::stun::agent::Transmit;
use turn_client_proto::stun::types::TransportType;
use turn_client_proto::types::TurnCredentials;
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
    /// The server refused or never answered. A wrong password shows up only
    /// after the crate's transaction timeout (~40 s): once it has sent
    /// credentials it ignores unauthenticated error replies, so a forged
    /// 401 can't knock the relay out. The call never waits on the relay.
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
        match self.client.recv(transmit, now) {
            TurnRecvRet::PeerData(peer_data) => Some((peer_data.peer, peer_data.data().to_vec())),
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
}
