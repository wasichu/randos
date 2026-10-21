//! The TCP connection under a TLS relay (`turns:`), for the call session.

use std::io::{ErrorKind, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;
use std::time::Duration;

/// The TCP side of a TLS relay: connected on a thread of its own (a
/// blocking connect mustn't stall the call loop), then read and written
/// without blocking. The bytes are TLS; `Candidates` makes sense of them.
#[derive(Default)]
pub(crate) struct TlsStream {
    pub(crate) connecting: Option<Receiver<std::io::Result<TcpStream>>>,
    pub(crate) stream: Option<TcpStream>,
    /// Waiting to be written (a full socket buffer can't take it all at once).
    pub(crate) out: Vec<u8>,
}

/// Give up on reaching a `turns:` server after this long.
const TLS_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

impl TlsStream {
    pub(crate) fn connect(&mut self, server: SocketAddr) {
        let (done, connecting) = mpsc::channel();
        let started = thread::Builder::new()
            .name("turns-connect".into())
            .spawn(move || {
                let _ = done.send(TcpStream::connect_timeout(&server, TLS_CONNECT_TIMEOUT));
            });
        if started.is_ok() {
            self.connecting = Some(connecting);
        }
    }

    /// The connection's outcome, once: our local address, or a failure.
    pub(crate) fn connected(&mut self) -> Option<Result<SocketAddr, ()>> {
        let outcome = match self.connecting.as_ref()?.try_recv() {
            Err(TryRecvError::Empty) => return None,
            Ok(Ok(stream)) => stream
                .set_nonblocking(true)
                .and_then(|()| stream.set_nodelay(true))
                .and_then(|()| stream.local_addr())
                .map(|local| (stream, local)),
            Ok(Err(err)) => Err(err),
            Err(TryRecvError::Disconnected) => Err(ErrorKind::Other.into()),
        };
        self.connecting = None;
        Some(match outcome {
            Ok((stream, local)) => {
                self.stream = Some(stream);
                Ok(local)
            }
            Err(_) => Err(()),
        })
    }

    /// Whatever has arrived (empty if nothing, or the stream closed).
    pub(crate) fn read(&mut self) -> Vec<u8> {
        let Some(stream) = self.stream.as_mut() else {
            return Vec::new();
        };
        let mut read = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            match stream.read(&mut buf) {
                Ok(0) => {
                    self.stream = None;
                    break;
                }
                Ok(n) => read.extend_from_slice(&buf[..n]),
                Err(err) if err.kind() == ErrorKind::WouldBlock => break,
                Err(_) => {
                    self.stream = None;
                    break;
                }
            }
        }
        read
    }

    pub(crate) fn flush(&mut self) {
        let Some(stream) = self.stream.as_mut() else {
            self.out.clear();
            return;
        };
        while !self.out.is_empty() {
            match stream.write(&self.out) {
                Ok(0) => break,
                Ok(n) => {
                    self.out.drain(..n);
                }
                Err(err) if err.kind() == ErrorKind::WouldBlock => break,
                Err(_) => {
                    self.stream = None;
                    self.out.clear();
                    break;
                }
            }
        }
    }
}
