//! Server-reflexive candidates: ask the call's STUN servers what address our
//! UDP socket has from outside our NAT, so peers on other networks can reach
//! us. Plain STUN Binding (RFC 8489): the call session sends the requests
//! from its call socket and hands back any reply before str0m sees it.
//!
//! Messages come from `stun-types` (already here for TURN), not str0m: str0m's
//! STUN parser is written for ICE connectivity checks and rejects any Binding
//! reply without MESSAGE-INTEGRITY, which public STUN servers never send.
//!
//! Sans-IO like str0m: this module never touches a socket or a clock; the
//! session passes `now` in and sends what `poll_transmit` returns.

use std::net::{SocketAddr, ToSocketAddrs};
use std::time::{Duration, Instant};

use serde_json::Value;
use stun_types::attribute::{AttributeType, MappedSocketAddr, XorMappedAddress};
use stun_types::message::{BINDING, Message, MessageClass, MessageWriteVec, TransactionId};
use stun_types::prelude::{MessageWrite, MessageWriteExt};

/// MAPPED-ADDRESS (RFC 5389 §15.1), which only old servers send instead of
/// XOR-MAPPED-ADDRESS; `stun-types` has the value type but no attribute.
const MAPPED_ADDRESS: AttributeType = AttributeType::new(0x0001);

/// Resend an unanswered request this often, this many times in all.
const RETRY_EVERY: Duration = Duration::from_millis(500);
const ATTEMPTS: u8 = 4;

/// `host:port` of every `stun:` URL in the channel's `ice_servers`
/// (`[{"urls": "stun:…" | ["…"], …}]`). `turn:`/`turns:` and `stuns:` are not
/// STUN-over-UDP servers and are skipped; the default port is 3478.
pub fn stun_servers(ice_servers: &Value) -> Vec<String> {
    let urls = ice_servers
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|server| match server.get("urls") {
            Some(Value::String(url)) => vec![url.as_str()],
            Some(Value::Array(urls)) => urls.iter().filter_map(Value::as_str).collect(),
            _ => vec![],
        });

    urls.filter_map(|url| url.strip_prefix("stun:"))
        .map(|rest| rest.split('?').next().unwrap_or(rest))
        .map(|host| {
            if host
                .rsplit_once(':')
                .is_some_and(|(_, port)| port.parse::<u16>().is_ok())
            {
                host.to_owned()
            } else {
                format!("{host}:3478")
            }
        })
        .collect()
}

/// Resolves `host:port`s to addresses of the same family as `local` (an IPv4
/// socket can't reach an IPv6 server). Unresolvable ones are skipped.
pub fn resolve(servers: &[String], local: SocketAddr) -> Vec<SocketAddr> {
    servers
        .iter()
        .filter_map(|server| server.to_socket_addrs().ok())
        .filter_map(|mut addrs| addrs.find(|addr| addr.is_ipv4() == local.is_ipv4()))
        .collect()
}

/// What a datagram was, as far as gathering is concerned.
#[derive(Debug, PartialEq, Eq)]
pub enum Reply {
    /// Not a reply to our requests: hand it to str0m.
    NotOurs,
    /// Our address as this server sees it.
    Mapped(SocketAddr),
    /// The server answered, but without an address (an error response).
    Failed,
}

struct Pending {
    server: SocketAddr,
    trans_id: TransactionId,
    /// Built once; every resend is the same request (same transaction).
    request: Vec<u8>,
    next_send: Instant,
    attempts: u8,
}

/// Binding requests in flight, one per server.
pub struct Gatherer {
    pending: Vec<Pending>,
}

impl Gatherer {
    pub fn new(servers: Vec<SocketAddr>, now: Instant) -> Self {
        let pending = servers
            .into_iter()
            .map(|server| {
                let (trans_id, request) = binding_request();
                Pending {
                    server,
                    trans_id,
                    request,
                    next_send: now,
                    attempts: 0,
                }
            })
            .collect();
        Self { pending }
    }

    /// Requests due now, as `(server, datagram)`. Servers that never answer
    /// are dropped after `ATTEMPTS` sends.
    pub fn poll_transmit(&mut self, now: Instant) -> Vec<(SocketAddr, Vec<u8>)> {
        let mut due = Vec::new();
        self.pending.retain_mut(|request| {
            if now < request.next_send {
                return true;
            }
            if request.attempts >= ATTEMPTS {
                return false;
            }
            request.attempts += 1;
            request.next_send = now + RETRY_EVERY;
            due.push((request.server, request.request.clone()));
            true
        });
        due
    }

    /// Whether `datagram` answers one of our requests (and stops it if so).
    pub fn handle(&mut self, datagram: &[u8]) -> Reply {
        let Some((trans_id, mapped)) = parse_binding_response(datagram) else {
            return Reply::NotOurs;
        };
        let Some(index) = self
            .pending
            .iter()
            .position(|request| request.trans_id == trans_id)
        else {
            return Reply::NotOurs;
        };
        self.pending.swap_remove(index);
        mapped.map_or(Reply::Failed, Reply::Mapped)
    }

    /// Nothing left to send or wait for.
    pub fn is_done(&self) -> bool {
        self.pending.is_empty()
    }
}

/// A plain Binding request (no attributes) and its transaction id.
fn binding_request() -> (TransactionId, Vec<u8>) {
    let request = Message::builder_request(BINDING, MessageWriteVec::new());
    (request.transaction_id(), request.finish())
}

/// A Binding response's transaction id and mapped address (`None` for an
/// error response, or a success without an address we can read).
fn parse_binding_response(datagram: &[u8]) -> Option<(TransactionId, Option<SocketAddr>)> {
    let message = Message::from_bytes(datagram).ok()?;
    if !message.has_method(BINDING) {
        return None;
    }
    let trans_id = message.transaction_id();
    match message.class() {
        MessageClass::Error => Some((trans_id, None)),
        MessageClass::Success => {
            let mapped = message
                .attribute::<XorMappedAddress>()
                .map(|xor| xor.addr(trans_id))
                .ok()
                .or_else(|| {
                    let raw = message.raw_attribute(MAPPED_ADDRESS)?;
                    Some(MappedSocketAddr::from_raw(&raw).ok()?.addr())
                });
            Some((trans_id, mapped))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::stun_reply;
    use serde_json::json;

    #[test]
    fn stun_urls_from_the_channels_ice_servers() {
        let ice = json!([
            {"urls": "stun:stun.l.google.com:19302"},
            {"urls": ["stun:turn.example.org", "turn:turn.example.org:3478?transport=udp"],
             "username": "u", "credential": "c"},
            {"urls": "turns:turn.example.org:5349"},
            {"urls": "stun:stun.example.org:3478?transport=udp"},
        ]);

        assert_eq!(
            stun_servers(&ice),
            vec![
                "stun.l.google.com:19302",
                "turn.example.org:3478",
                "stun.example.org:3478",
            ]
        );
        assert!(stun_servers(&json!(null)).is_empty());
    }

    #[test]
    fn a_reply_to_our_request_gives_the_mapped_address_once() {
        let server: SocketAddr = "127.0.0.1:3478".parse().unwrap();
        let now = Instant::now();
        let mut gatherer = Gatherer::new(vec![server], now);

        let sent = gatherer.poll_transmit(now);
        assert_eq!(sent.len(), 1);
        let request = &sent[0].1;
        assert_eq!(request.len(), 20);
        assert_eq!(&request[0..2], &[0x00, 0x01], "a Binding request");

        let mapped: SocketAddr = "203.0.113.7:40000".parse().unwrap();
        let reply = stun_reply(request, mapped);
        assert_eq!(gatherer.handle(&reply), Reply::Mapped(mapped));
        assert!(gatherer.is_done());
        // A duplicate (a retransmit's answer) is no longer ours.
        assert_eq!(gatherer.handle(&reply), Reply::NotOurs);
        assert_eq!(gatherer.handle(b"not stun"), Reply::NotOurs);
    }

    #[test]
    fn unanswered_requests_are_resent_then_given_up() {
        let server: SocketAddr = "127.0.0.1:3478".parse().unwrap();
        let start = Instant::now();
        let mut gatherer = Gatherer::new(vec![server], start);

        let mut sends = 0;
        for tick in 0..20 {
            sends += gatherer.poll_transmit(start + RETRY_EVERY * tick).len();
        }
        assert_eq!(sends, usize::from(ATTEMPTS));
        assert!(gatherer.is_done());
    }

    // RFC 5769 §2.2: the sample IPv4 Binding response (software name,
    // XOR-MAPPED-ADDRESS 192.0.2.1:32853, MESSAGE-INTEGRITY, FINGERPRINT).
    const RFC5769_IPV4_RESPONSE: [u8; 80] = [
        0x01, 0x01, 0x00, 0x3c, 0x21, 0x12, 0xa4, 0x42, 0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6,
        0x86, 0xfa, 0x87, 0xdf, 0xae, 0x80, 0x22, 0x00, 0x0b, 0x74, 0x65, 0x73, 0x74, 0x20, 0x76,
        0x65, 0x63, 0x74, 0x6f, 0x72, 0x20, 0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xa1, 0x47, 0xe1,
        0x12, 0xa6, 0x43, 0x00, 0x08, 0x00, 0x14, 0x2b, 0x91, 0xf5, 0x99, 0xfd, 0x9e, 0x90, 0xc3,
        0x8c, 0x74, 0x89, 0xf9, 0x2a, 0xf9, 0xba, 0x53, 0xf0, 0x6b, 0xe7, 0xd7, 0x80, 0x28, 0x00,
        0x04, 0xc0, 0x7d, 0x4c, 0x96,
    ];

    #[test]
    fn parses_the_rfc_5769_sample_response() {
        let (trans_id, mapped) = parse_binding_response(&RFC5769_IPV4_RESPONSE).unwrap();
        assert_eq!(
            trans_id,
            TransactionId::from(u128::from_be_bytes(
                [&[0; 4], &RFC5769_IPV4_RESPONSE[8..20]]
                    .concat()
                    .try_into()
                    .unwrap()
            ))
        );
        assert_eq!(mapped, Some("192.0.2.1:32853".parse().unwrap()));
    }

    #[test]
    fn an_old_servers_plain_mapped_address_is_read_too() {
        let mut reply = vec![0x01, 0x01, 0x00, 0x0c, 0x21, 0x12, 0xa4, 0x42];
        reply.extend_from_slice(&[9; 12]);
        // MAPPED-ADDRESS, IPv4, 198.51.100.4:3479, not XORed.
        reply.extend_from_slice(&[
            0x00, 0x01, 0x00, 0x08, 0x00, 0x01, 0x0d, 0x97, 198, 51, 100, 4,
        ]);
        let (_, mapped) = parse_binding_response(&reply).unwrap();
        assert_eq!(mapped, Some("198.51.100.4:3479".parse().unwrap()));
    }

    #[test]
    fn junk_and_other_stun_messages_are_not_responses() {
        assert_eq!(parse_binding_response(b"not stun"), None);
        assert_eq!(parse_binding_response(&binding_request().1), None);
        let mut truncated = RFC5769_IPV4_RESPONSE.to_vec();
        truncated.pop();
        assert_eq!(parse_binding_response(&truncated), None);
    }
}
