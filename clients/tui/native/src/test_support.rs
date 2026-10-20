//! Test doubles shared by the helper's tests: a STUN reply built by hand
//! from the RFC (not by the library under test), and fake STUN and TURN
//! servers on loopback.

use std::net::{SocketAddr, UdpSocket};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::{Duration, Instant};

/// A Binding success response to `request` (RFC 8489 §5, §14.2), built by
/// hand from the spec rather than by the library under test: the header
/// with the request's transaction id, and XOR-MAPPED-ADDRESS (IPv4).
pub fn stun_reply(request: &[u8], mapped: SocketAddr) -> Vec<u8> {
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

/// A STUN server on loopback that answers every Binding request with
/// `mapped` (as a NAT would report an outside address).
pub fn fake_stun_server(mapped: SocketAddr) -> SocketAddr {
    let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    let addr = socket.local_addr().unwrap();
    thread::spawn(move || {
        let mut buf = [0u8; 1500];
        while let Ok((n, from)) = socket.recv_from(&mut buf) {
            let reply = stun_reply(&buf[..n], mapped);
            let _ = socket.send_to(&reply, from);
        }
    });
    addr
}

/// What the fake TURN server saw from its client.
#[derive(Default)]
pub struct TurnSeen {
    pub create_permissions: AtomicUsize,
    pub send_indications: AtomicUsize,
}

/// A TURN server on loopback (`turn-server-proto`, the same sans-IO
/// family as our client), user `user`/`pass`. Returns its address.
pub fn fake_turn_server() -> (SocketAddr, Arc<TurnSeen>) {
    use turn_server_proto::api::{Transmit, TurnServerApi, TurnServerPollRet};
    use turn_server_proto::server::TurnServer;
    use turn_server_proto::stun::types::TransportType;
    use turn_server_proto::types::Instant as TurnInstant;

    let listen = UdpSocket::bind("127.0.0.1:0").unwrap();
    let listen_addr = listen.local_addr().unwrap();
    listen.set_nonblocking(true).unwrap();
    let seen = Arc::new(TurnSeen::default());
    let counts = Arc::clone(&seen);
    thread::spawn(move || {
        let base = Instant::now();
        let mut server = TurnServer::new(TransportType::Udp, listen_addr, "randos".into());
        server.add_user("user".into(), "pass".into());
        let mut relayed: Option<UdpSocket> = None;
        let mut buf = [0u8; 1500];
        loop {
            let now = TurnInstant::from_std(base);
            let mut got = Vec::new();
            if let Ok((n, from)) = listen.recv_from(&mut buf) {
                match u16::from_be_bytes([buf[0], buf[1]]) {
                    0x0008 => counts.create_permissions.fetch_add(1, Ordering::Relaxed),
                    0x0016 => counts.send_indications.fetch_add(1, Ordering::Relaxed),
                    _ => 0,
                };
                got.push((buf[..n].to_vec(), from, listen_addr));
            }
            if let Some(socket) = &relayed
                && let Ok((n, from)) = socket.recv_from(&mut buf)
            {
                got.push((buf[..n].to_vec(), from, socket.local_addr().unwrap()));
            }
            let mut out = Vec::new();
            for (data, from, to) in got {
                let transmit = Transmit {
                    data,
                    transport: TransportType::Udp,
                    from,
                    to,
                };
                if let Some(reply) = server.recv(transmit, now) {
                    let reply = reply.build();
                    out.push((reply.data, reply.from, reply.to));
                }
            }
            if let TurnServerPollRet::AllocateSocket {
                transport,
                listen_addr,
                client_addr,
                allocation_transport,
                family,
            } = server.poll(now)
            {
                let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
                socket.set_nonblocking(true).unwrap();
                let addr = socket.local_addr().unwrap();
                relayed = Some(socket);
                server.allocated_socket(
                    transport,
                    listen_addr,
                    client_addr,
                    allocation_transport,
                    family,
                    Ok(addr),
                    now,
                );
            }
            while let Some(transmit) = server.poll_transmit(now) {
                out.push((transmit.data, transmit.from, transmit.to));
            }
            for (data, from, to) in out {
                let socket = if from == listen_addr {
                    Some(&listen)
                } else {
                    relayed.as_ref()
                };
                if let Some(socket) = socket {
                    let _ = socket.send_to(&data, to);
                }
            }
            thread::sleep(Duration::from_millis(1));
        }
    });
    (listen_addr, seen)
}
