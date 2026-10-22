//! A TURN relay for tests that can cut a client's media path, the way a
//! network change does (ICE restart, `docs/architecture/ice_restart.md`).
//!
//! ```text
//! cargo run -p randos_media --example test_turn -- [--user U] [--pass P] [--realm R]
//! ```
//!
//! A real UDP TURN server on 127.0.0.1 (Allocate, Refresh, CreatePermission,
//! ChannelBind, Send/Data; `turn-server-proto` does the protocol), with
//! fixed long-term credentials (default `randos` / `randos`). Not the Port
//! helper, so it may print: stdout is its report to the test that started
//! it, one line per event:
//!
//! ```text
//! listening 127.0.0.1:PORT
//! allocated CLIENT_ADDR RELAYED_ADDR
//! cut CLIENT_ADDR            (in reply to a cut command)
//! ```
//!
//! Commands, one per line on stdin:
//!
//! - `cut ADDR`: drop everything from and to that client address (its
//!   5-tuple is dead, as after a network change); new allocations from
//!   other addresses still work, so a restart can recover;
//! - `cut-all`: cut every client address seen so far;
//! - `heal`: undo all cuts.
//!
//! It exits when stdin closes, so it never outlives the test that started it
//! (AGENTS.md, Testing).

#![allow(clippy::print_stdout)] // stdout is this tool's report, not a Port

use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::io::{self, BufRead, Write};
use std::net::{SocketAddr, UdpSocket};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;
use std::time::{Duration, Instant};

use turn_server_proto::api::{Transmit, TurnServerApi, TurnServerPollRet};
use turn_server_proto::server::TurnServer;
use turn_server_proto::stun::types::TransportType;
use turn_server_proto::types::Instant as TurnInstant;

enum Command {
    Cut(SocketAddr),
    CutAll,
    Heal,
    Quit,
}

fn main() -> Result<(), Box<dyn Error>> {
    let mut user = "randos".to_string();
    let mut pass = "randos".to_string();
    let mut realm = "randos".to_string();
    let mut args = std::env::args().skip(1);
    while let Some(flag) = args.next() {
        let value = args.next().ok_or(format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--user" => user = value,
            "--pass" => pass = value,
            "--realm" => realm = value,
            _ => return Err(format!("unknown argument {flag}").into()),
        }
    }

    let listen = UdpSocket::bind("127.0.0.1:0")?;
    listen.set_nonblocking(true)?;
    let listen_addr = listen.local_addr()?;
    let mut server = TurnServer::new(TransportType::Udp, listen_addr, realm);
    server.add_user(user, pass);
    report(&format!("listening {listen_addr}"))?;

    let commands = read_commands();
    let base = Instant::now();
    // Relayed address => its socket; client address => its relayed address.
    let mut relayed: HashMap<SocketAddr, UdpSocket> = HashMap::new();
    let mut clients: HashMap<SocketAddr, SocketAddr> = HashMap::new();
    let mut cut: HashSet<SocketAddr> = HashSet::new();
    let mut buf = [0u8; 1500];

    loop {
        match commands.try_recv() {
            Ok(Command::Cut(addr)) => {
                cut.insert(addr);
                report(&format!("cut {addr}"))?;
            }
            Ok(Command::CutAll) => {
                for addr in clients.keys() {
                    cut.insert(*addr);
                    report(&format!("cut {addr}"))?;
                }
            }
            Ok(Command::Heal) => cut.clear(),
            Ok(Command::Quit) | Err(TryRecvError::Disconnected) => return Ok(()),
            Err(TryRecvError::Empty) => {}
        }

        let now = TurnInstant::from_std(base);
        let mut incoming = Vec::new();
        while let Ok((n, from)) = listen.recv_from(&mut buf) {
            if !cut.contains(&from) {
                incoming.push((buf.get(..n).unwrap_or_default().to_vec(), from, listen_addr));
            }
        }
        for (addr, socket) in &relayed {
            while let Ok((n, from)) = socket.recv_from(&mut buf) {
                incoming.push((buf.get(..n).unwrap_or_default().to_vec(), from, *addr));
            }
        }

        let mut out = Vec::new();
        for (data, from, to) in incoming {
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

        loop {
            match server.poll(now) {
                TurnServerPollRet::AllocateSocket {
                    transport,
                    listen_addr,
                    client_addr,
                    allocation_transport,
                    family,
                } => {
                    let socket = UdpSocket::bind("127.0.0.1:0")?;
                    socket.set_nonblocking(true)?;
                    let addr = socket.local_addr()?;
                    relayed.insert(addr, socket);
                    clients.insert(client_addr, addr);
                    report(&format!("allocated {client_addr} {addr}"))?;
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
                TurnServerPollRet::SocketClose { listen_addr, .. } => {
                    relayed.remove(&listen_addr);
                    clients.retain(|_, relayed_addr| *relayed_addr != listen_addr);
                }
                _ => break,
            }
        }
        while let Some(transmit) = server.poll_transmit(now) {
            out.push((transmit.data, transmit.from, transmit.to));
        }

        for (data, from, to) in out {
            if cut.contains(&to) {
                continue;
            }
            let socket = if from == listen_addr {
                Some(&listen)
            } else {
                relayed.get(&from)
            };
            if let Some(socket) = socket {
                let _ = socket.send_to(&data, to);
            }
        }
        thread::sleep(Duration::from_millis(1));
    }
}

fn report(line: &str) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    writeln!(stdout, "{line}")?;
    stdout.flush()
}

// Commands from stdin; the channel closes (Disconnected) with stdin.
fn read_commands() -> Receiver<Command> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        for line in io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            let mut words = line.split_whitespace();
            let command = match (words.next(), words.next().map(str::parse)) {
                (Some("cut"), Some(Ok(addr))) => Command::Cut(addr),
                (Some("cut-all"), None) => Command::CutAll,
                (Some("heal"), None) => Command::Heal,
                (Some("quit"), None) => Command::Quit,
                _ => {
                    eprintln!("test_turn: unknown command {line:?}");
                    continue;
                }
            };
            if tx.send(command).is_err() {
                break;
            }
        }
    });
    rx
}
