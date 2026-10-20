//! Server-reflexive candidates: ask the call's STUN servers what address our
//! UDP socket has from outside our NAT, so peers on other networks can reach
//! us. Plain STUN Binding (RFC 8489): the call session sends the requests
//! from its call socket and hands back any reply before str0m sees it.
//!
//! A small codec of our own, not str0m's: str0m's STUN parser is written for
//! ICE connectivity checks and rejects any Binding reply without
//! MESSAGE-INTEGRITY, which public STUN servers never send.
//!
//! Sans-IO like str0m: this module never touches a socket or a clock; the
//! session passes `now` in and sends what `poll_transmit` returns.

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs};
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::Error;

const MAGIC_COOKIE: u32 = 0x2112_A442;
const BINDING_REQUEST: u16 = 0x0001;
const BINDING_SUCCESS: u16 = 0x0101;
const BINDING_ERROR: u16 = 0x0111;
const MAPPED_ADDRESS: u16 = 0x0001;
const XOR_MAPPED_ADDRESS: u16 = 0x0020;

type TransId = [u8; 12];

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
    trans_id: TransId,
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
            .map(|server| Pending {
                server,
                trans_id: new_trans_id(),
                next_send: now,
                attempts: 0,
            })
            .collect();
        Self { pending }
    }

    /// Requests due now, as `(server, datagram)`. Servers that never answer
    /// are dropped after `ATTEMPTS` sends.
    pub fn poll_transmit(&mut self, now: Instant) -> Result<Vec<(SocketAddr, Vec<u8>)>, Error> {
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
            due.push((request.server, request.trans_id));
            true
        });

        Ok(due
            .into_iter()
            .map(|(server, trans_id)| (server, binding_request(trans_id)))
            .collect())
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

/// A plain Binding request: just the header (RFC 8489 §5), no attributes.
fn binding_request(trans_id: TransId) -> Vec<u8> {
    let mut request = Vec::with_capacity(20);
    request.extend_from_slice(&BINDING_REQUEST.to_be_bytes());
    request.extend_from_slice(&0u16.to_be_bytes());
    request.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
    request.extend_from_slice(&trans_id);
    request
}

/// A random transaction id (std's per-process random hash keys; unguessable
/// enough that an off-path host can't forge a reply).
fn new_trans_id() -> TransId {
    let mut id = [0u8; 12];
    let a = RandomState::new().build_hasher().finish().to_be_bytes();
    let b = RandomState::new().build_hasher().finish().to_be_bytes();
    id[..8].copy_from_slice(&a);
    id[8..].copy_from_slice(&b[..4]);
    id
}

/// A Binding response's transaction id and mapped address (`None` for an
/// error response, or a success without an address we can read).
fn parse_binding_response(datagram: &[u8]) -> Option<(TransId, Option<SocketAddr>)> {
    let header = datagram.get(..20)?;
    let kind = u16::from_be_bytes([header[0], header[1]]);
    let len = usize::from(u16::from_be_bytes([header[2], header[3]]));
    let cookie = u32::from_be_bytes([header[4], header[5], header[6], header[7]]);
    if cookie != MAGIC_COOKIE || datagram.len() != 20 + len {
        return None;
    }
    let trans_id: TransId = header[8..20].try_into().ok()?;
    match kind {
        BINDING_ERROR => return Some((trans_id, None)),
        BINDING_SUCCESS => {}
        _ => return None,
    }

    let mut attributes = datagram.get(20..)?;
    let (mut xor_mapped, mut mapped) = (None, None);
    while attributes.len() >= 4 {
        let kind = u16::from_be_bytes([attributes[0], attributes[1]]);
        let len = usize::from(u16::from_be_bytes([attributes[2], attributes[3]]));
        let value = attributes.get(4..4 + len)?;
        match kind {
            XOR_MAPPED_ADDRESS => xor_mapped = address(value, Some(&trans_id)),
            MAPPED_ADDRESS => mapped = address(value, None),
            _ => {}
        }
        // Attributes are padded to a multiple of 4 bytes.
        attributes = attributes
            .get(4 + len.div_ceil(4) * 4..)
            .unwrap_or_default();
    }
    Some((trans_id, xor_mapped.or(mapped)))
}

/// A (XOR-)MAPPED-ADDRESS value; `xor` is the transaction id when the address
/// is XORed with the magic cookie (and, for IPv6, the transaction id).
fn address(value: &[u8], xor: Option<&TransId>) -> Option<SocketAddr> {
    let family = *value.get(1)?;
    let cookie = MAGIC_COOKIE.to_be_bytes();
    let mut port = u16::from_be_bytes([*value.get(2)?, *value.get(3)?]);
    if xor.is_some() {
        port ^= u16::from_be_bytes([cookie[0], cookie[1]]);
    }

    let mut ip = value.get(4..)?.to_vec();
    if let Some(trans_id) = xor {
        let mask: Vec<u8> = cookie.iter().chain(trans_id.iter()).copied().collect();
        ip.iter_mut().zip(mask).for_each(|(byte, m)| *byte ^= m);
    }

    let ip = match (family, ip.len()) {
        (0x01, 4) => IpAddr::V4(Ipv4Addr::from(<[u8; 4]>::try_from(ip).ok()?)),
        (0x02, 16) => IpAddr::V6(Ipv6Addr::from(<[u8; 16]>::try_from(ip).ok()?)),
        _ => return None,
    };
    Some(SocketAddr::new(ip, port))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
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

        let sent = gatherer.poll_transmit(now).unwrap();
        assert_eq!(sent.len(), 1);
        let request = &sent[0].1;
        assert_eq!(request.len(), 20);
        assert_eq!(&request[0..2], &[0x00, 0x01], "a Binding request");

        let mapped: SocketAddr = "203.0.113.7:40000".parse().unwrap();
        let reply = reply_to(request, mapped);
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
            sends += gatherer
                .poll_transmit(start + RETRY_EVERY * tick)
                .unwrap()
                .len();
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
        assert_eq!(trans_id, RFC5769_IPV4_RESPONSE[8..20]);
        assert_eq!(mapped, Some("192.0.2.1:32853".parse().unwrap()));
    }

    #[test]
    fn junk_and_other_stun_messages_are_not_responses() {
        assert_eq!(parse_binding_response(b"not stun"), None);
        assert_eq!(parse_binding_response(&binding_request([7; 12])), None);
        let mut truncated = RFC5769_IPV4_RESPONSE.to_vec();
        truncated.pop();
        assert_eq!(parse_binding_response(&truncated), None);
    }

    /// A Binding success response to `request` (RFC 8489 §5, §14.2), built by
    /// hand from the spec rather than by the library under test: the header
    /// with the request's transaction id, and XOR-MAPPED-ADDRESS (IPv4).
    pub(crate) fn reply_to(request: &[u8], mapped: SocketAddr) -> Vec<u8> {
        const COOKIE: u32 = 0x2112_A442;
        let SocketAddr::V4(mapped) = mapped else {
            panic!("IPv4 only")
        };
        let mut reply = vec![0x01, 0x01, 0x00, 0x0C]; // success response, 12 bytes of attributes
        reply.extend_from_slice(&COOKIE.to_be_bytes());
        reply.extend_from_slice(&request[8..20]); // transaction id
        reply.extend_from_slice(&[0x00, 0x20, 0x00, 0x08, 0x00, 0x01]); // XOR-MAPPED-ADDRESS, IPv4
        reply.extend_from_slice(&(mapped.port() ^ (COOKIE >> 16) as u16).to_be_bytes());
        reply.extend_from_slice(&(u32::from(*mapped.ip()) ^ COOKIE).to_be_bytes());
        reply
    }
}
