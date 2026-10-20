//! One WebRTC call with a browser (or another helper): str0m for ICE, DTLS,
//! and RTP; Opus between the mic and the network; signals in the browser's
//! JSON shapes so `Tui.Media` relays them untouched.
//!
//! str0m is sans-IO: it owns no sockets, threads, or timers. A session
//! thread owns the UDP socket, the `Rtc`, the codec, and the audio ends, and
//! runs one loop: apply the peer's signals, send a frame when the mic has
//! one, read the socket until str0m's next deadline (at most a few ms, so
//! the 20 ms audio cadence is kept). Every change to the `Rtc` is followed
//! by `drain`, str0m's one rule (mutate, then poll until `Timeout`).

use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use cpal::Stream;
use serde_json::{Value, json};
use str0m::change::{SdpAnswer, SdpOffer, SdpPendingOffer};
use str0m::media::{Direction, Frequency, MediaKind, MediaTime, Mid, Pt};
use str0m::net::{Protocol, Receive};
use str0m::{
    Candidate, Event as RtcEvent, IceConnectionState, Input as RtcInput, Output as RtcOutput, Rtc,
    RtcConfig,
};

use crate::Error;
use crate::audio::{Capture, Devices, Input, Notify, Output, Playback, Started};
use crate::codec::{Decoder, Encoder, FRAME, Peak};
use crate::protocol::{CallStats, Event};
use crate::relay::{self, Relay, RelayEvent};
use crate::stun::{self, Gatherer, Reply};

/// The longest the loop waits on the socket, so mic frames and commands are
/// serviced well inside one 20 ms frame.
const MAX_WAIT: Duration = Duration::from_millis(5);

/// Who sends the offer; the server assigns it (`webrtc_role`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Offerer,
    Answerer,
}

impl std::str::FromStr for Role {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "offerer" => Ok(Role::Offerer),
            "answerer" => Ok(Role::Answerer),
            other => Err(format!("unknown role {other:?} (offerer|answerer)")),
        }
    }
}

pub struct CallConfig {
    pub role: Role,
    /// The local address to bind and advertise. `None` picks the address of
    /// the default route; tests pass loopback.
    pub bind_ip: Option<IpAddr>,
    /// The channel's `ice_servers` for this call: `stun:` servers give us a
    /// server-reflexive candidate (our address outside the NAT).
    pub ice_servers: Value,
    /// Offer only the relay candidate (no host or STUN), like a browser's
    /// `iceTransportPolicy: "relay"`, so every packet goes through TURN.
    /// Not in the Port protocol: tests use it to prove the relay path.
    pub relay_only: bool,
}

/// A signal from the peer, as the participant channel delivers it.
pub struct RemoteSignal {
    pub kind: String,
    pub payload: Value,
}

enum Command {
    Remote(RemoteSignal),
    Stop,
}

/// A running call. Dropping the streams stops the devices; `stop` also
/// joins the session thread and surfaces its error, if any.
pub struct Call {
    _streams: Vec<Stream>,
    commands: Sender<Command>,
    worker: JoinHandle<Result<(), Error>>,
}

impl Call {
    pub fn start(
        config: CallConfig,
        input: Input,
        output: Output,
        notify: Notify,
    ) -> Result<(Self, Started), Error> {
        let Devices {
            capture,
            playback,
            streams,
            started,
            ..
        } = Devices::open(input, output, &notify)?;
        let mut session = Session::new(&config, capture, playback, Arc::clone(&notify))?;

        let (commands, inbox) = mpsc::channel();
        let worker = thread::Builder::new().name("call".into()).spawn(move || {
            let result = session.run(config.role, &inbox);
            if let Err(err) = &result {
                notify(Event::CallState {
                    state: "failed".into(),
                    reason: Some(err.to_string()),
                });
            }
            result
        })?;

        Ok((
            Self {
                _streams: streams,
                commands,
                worker,
            },
            started,
        ))
    }

    /// Hands the session a signal from the peer.
    pub fn signal(&self, signal: RemoteSignal) -> Result<(), Error> {
        self.commands
            .send(Command::Remote(signal))
            .map_err(|_| "the call has ended".into())
    }

    /// False once the session has stopped on its own (it reported `failed`).
    pub fn is_running(&self) -> bool {
        !self.worker.is_finished()
    }

    pub fn stop(self) -> Result<(), Error> {
        // Fails only if the session already exited; join reports why.
        let _ = self.commands.send(Command::Stop);
        self.worker.join().map_err(|_| "call session panicked")?
    }
}

struct Session {
    rtc: Rtc,
    socket: UdpSocket,
    local: SocketAddr,
    mid: Option<Mid>,
    pt: Option<Pt>,
    pending_offer: Option<SdpPendingOffer>,
    /// Remote candidates that arrived before the remote description.
    early_candidates: Vec<Candidate>,
    remote_description_set: bool,
    /// ICE and DTLS came up at least once (`Event::Connected`).
    dtls_up: bool,
    /// Currently connected: media flows. False again while ICE is disconnected.
    connected: bool,
    encoder: Encoder,
    decoder: Decoder,
    capture: Capture,
    playback: Playback,
    rtp_time: u64,
    next_timeout: Instant,
    report: Report,
    notify: Notify,
    buf: Vec<u8>,
    ice_servers: Value,
    relay_only: bool,
    stun: Gatherer,
    /// Our TURN allocation, if the call has a `turn:` server.
    relay: Option<Relay>,
    /// Our candidates found since the last `gather`, trickled once our SDP
    /// (offer or answer) has gone out.
    unsent_candidates: Vec<String>,
    sdp_sent: bool,
}

impl Session {
    fn new(
        config: &CallConfig,
        capture: Capture,
        playback: Playback,
        notify: Notify,
    ) -> Result<Self, Error> {
        let ip = match config.bind_ip {
            Some(ip) => ip,
            None => default_route_ip()?,
        };
        let socket = UdpSocket::bind(SocketAddr::new(ip, 0))?;
        let local = socket.local_addr()?;

        let mut rtc = RtcConfig::new()
            .clear_codecs()
            .enable_opus(true, false)
            .build(Instant::now());
        if !config.relay_only {
            rtc.add_local_candidate(Candidate::host(local, "udp")?);
        }
        let mut report = Report::new();
        if config.relay_only {
            report.local_candidates.clear();
        }

        Ok(Self {
            rtc,
            socket,
            local,
            mid: None,
            pt: None,
            pending_offer: None,
            early_candidates: Vec::new(),
            remote_description_set: false,
            dtls_up: false,
            connected: false,
            encoder: Encoder::new()?,
            decoder: Decoder::new()?,
            capture,
            playback,
            rtp_time: 0,
            next_timeout: Instant::now(),
            report,
            notify,
            buf: vec![0; 2000],
            ice_servers: config.ice_servers.clone(),
            relay_only: config.relay_only,
            stun: Gatherer::new(Vec::new(), Instant::now()),
            relay: None,
            unsent_candidates: Vec::new(),
            sdp_sent: false,
        })
    }

    fn run(&mut self, role: Role, inbox: &Receiver<Command>) -> Result<(), Error> {
        // Resolve the STUN servers here, not in `Call::start`: DNS can be
        // slow, and the Port must keep answering meanwhile.
        let servers = if self.relay_only {
            Vec::new()
        } else {
            stun::resolve(&stun::stun_servers(&self.ice_servers), self.local)
        };
        self.stun = Gatherer::new(servers, Instant::now());
        self.relay = relay::turn_servers(&self.ice_servers)
            .first()
            .and_then(|server| {
                let addr = relay::resolve(server, self.local)?;
                Some(Relay::allocate(self.local, addr, server))
            });

        if role == Role::Offerer {
            self.send_offer()?;
        }
        self.drain()?;

        loop {
            self.gather()?;

            match inbox.try_recv() {
                Ok(Command::Remote(signal)) => {
                    self.apply_remote(signal)?;
                    self.drain()?;
                    continue;
                }
                Ok(Command::Stop) | Err(TryRecvError::Disconnected) => break,
                Err(TryRecvError::Empty) => {}
            }

            let mut frame = [0.0; FRAME];
            if self.capture.read(&mut frame)? {
                self.send_frame(&frame)?;
                self.drain()?;
                continue;
            }

            self.receive()?;
            self.drain()?;
            self.report
                .tick(&self.capture, &self.playback, &self.notify);
        }

        // Send the teardown packets too, so the peer sees a clean close
        // instead of waiting out its own disconnect timer.
        self.rtc.disconnect();
        let drained = self.drain();
        if let Some(relay) = self.relay.as_mut() {
            for message in relay.close() {
                let _ = self.socket.send_to(&message, relay.server());
            }
        }
        drained
    }

    fn send_offer(&mut self) -> Result<(), Error> {
        let mut change = self.rtc.sdp_api();
        let mid = change.add_media(MediaKind::Audio, Direction::SendRecv, None, None, None);
        let (offer, pending) = change.apply().ok_or("no offer to send")?;
        self.mid = Some(mid);
        self.pending_offer = Some(pending);
        self.sdp_sent = true;
        self.signal_out(
            "offer",
            json!({"sdp": {"type": "offer", "sdp": offer.to_sdp_string()}}),
        );
        Ok(())
    }

    /// One signal from the peer, in the channel's shapes:
    /// `{"sdp": {"type", "sdp"}}` and `{"candidate": {"candidate", …}}`.
    fn apply_remote(&mut self, signal: RemoteSignal) -> Result<(), Error> {
        match signal.kind.as_str() {
            "offer" => {
                let offer = SdpOffer::from_sdp_string(sdp_text(&signal.payload)?)?;
                let answer = self.rtc.sdp_api().accept_offer(offer)?;
                self.signal_out(
                    "answer",
                    json!({"sdp": {"type": "answer", "sdp": answer.to_sdp_string()}}),
                );
                self.sdp_sent = true;
                self.remote_description_set()
            }
            "answer" => {
                let pending = self
                    .pending_offer
                    .take()
                    .ok_or("an answer without an offer")?;
                let answer = SdpAnswer::from_sdp_string(sdp_text(&signal.payload)?)?;
                self.rtc.sdp_api().accept_answer(pending, answer)?;
                self.remote_description_set()
            }
            "ice_candidate" => {
                let Some(candidate) = remote_candidate(&signal.payload, &mut self.report) else {
                    return Ok(());
                };
                if let Some(relay) = self.relay.as_mut() {
                    relay.permit(candidate.addr().ip());
                }
                if self.remote_description_set {
                    self.rtc.add_remote_candidate(candidate);
                } else {
                    self.early_candidates.push(candidate);
                }
                Ok(())
            }
            // Call lifecycle signals are the TUI's business, not the media's.
            _ => Ok(()),
        }
    }

    fn remote_description_set(&mut self) -> Result<(), Error> {
        self.remote_description_set = true;
        // Each candidate is a mutation; drain between them (str0m's rule).
        for candidate in std::mem::take(&mut self.early_candidates) {
            self.rtc.add_remote_candidate(candidate);
            self.drain()?;
        }
        Ok(())
    }

    fn send_frame(&mut self, frame: &[f32; FRAME]) -> Result<(), Error> {
        let (Some(mid), true) = (self.mid, self.connected) else {
            // Not connected yet: drop mic audio rather than queue it.
            return Ok(());
        };
        self.report.sent(frame);
        let Some(writer) = self.rtc.writer(mid) else {
            return Ok(());
        };
        let pt = match self.pt {
            Some(pt) => pt,
            None => {
                let pt = writer
                    .payload_params()
                    .next()
                    .ok_or("no negotiated Opus payload type")?
                    .pt();
                self.pt = Some(pt);
                pt
            }
        };

        let packet = self.encoder.encode(frame)?.to_vec();
        let time = MediaTime::new(self.rtp_time, Frequency::FORTY_EIGHT_KHZ);
        self.rtp_time += FRAME as u64;
        writer.write(pt, Instant::now(), time, packet)?;
        self.report.packets_sent += 1;
        Ok(())
    }

    /// Waits for one datagram, at most until str0m's next deadline (or
    /// `MAX_WAIT`), and feeds it (or the timeout) to the `Rtc`.
    fn receive(&mut self) -> Result<(), Error> {
        let wait = self
            .next_timeout
            .saturating_duration_since(Instant::now())
            .clamp(Duration::from_millis(1), MAX_WAIT);
        self.socket.set_read_timeout(Some(wait))?;
        self.buf.resize(2000, 0);

        let input = match self.socket.recv_from(&mut self.buf) {
            Ok((n, source)) => {
                self.buf.truncate(n);
                // A STUN server answering us, not something for str0m.
                match self.stun.handle(&self.buf) {
                    Reply::Mapped(mapped) => return self.add_server_reflexive(mapped),
                    Reply::Failed => return Ok(()),
                    Reply::NotOurs => {}
                }
                // From the TURN server: its own business, or a peer's packet
                // relayed to us, which str0m sees as arriving at the relayed
                // address (so it pairs it with our relay candidate).
                if let Some(relay) = self.relay.as_mut().filter(|r| r.server() == source) {
                    let relayed = relay.relayed();
                    return match (relay.recv(&self.buf), relayed) {
                        (Some((peer, data)), Some(destination)) => {
                            self.handle_datagram(peer, destination, &data)
                        }
                        _ => Ok(()),
                    };
                }
                RtcInput::Receive(
                    Instant::now(),
                    Receive {
                        proto: Protocol::Udp,
                        source,
                        destination: self.local,
                        contents: self.buf.as_slice().try_into()?,
                    },
                )
            }
            Err(err)
                if matches!(
                    err.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                RtcInput::Timeout(Instant::now())
            }
            Err(err) => return Err(err.into()),
        };

        // Not every datagram is for us (e.g. stray STUN); str0m says so.
        if self.rtc.accepts(&input) {
            self.rtc.handle_input(input)?;
        } else if let RtcInput::Receive(..) = input {
            self.rtc.handle_input(RtcInput::Timeout(Instant::now()))?;
        }
        Ok(())
    }

    /// A relayed datagram for str0m, as if it arrived at `destination`.
    fn handle_datagram(
        &mut self,
        source: SocketAddr,
        destination: SocketAddr,
        data: &[u8],
    ) -> Result<(), Error> {
        let input = RtcInput::Receive(
            Instant::now(),
            Receive {
                proto: Protocol::Udp,
                source,
                destination,
                contents: data.try_into()?,
            },
        );
        if self.rtc.accepts(&input) {
            self.rtc.handle_input(input)?;
        }
        Ok(())
    }

    /// Polls the `Rtc` until it has nothing more to do right now.
    fn drain(&mut self) -> Result<(), Error> {
        loop {
            match self.rtc.poll_output()? {
                RtcOutput::Timeout(at) => {
                    self.next_timeout = at;
                    return Ok(());
                }
                RtcOutput::Transmit(transmit) => {
                    // From our relay candidate: wrap it for the TURN server.
                    let (contents, destination) = match self.relay.as_mut() {
                        Some(relay) if relay.relayed() == Some(transmit.source) => {
                            match relay.send(transmit.destination, &transmit.contents) {
                                Ok(Some(wrapped)) => (wrapped, relay.server()),
                                // No permission yet (or a relay error): ICE
                                // retries the check.
                                Ok(None) | Err(_) => {
                                    self.report.send_errors += 1;
                                    continue;
                                }
                            }
                        }
                        _ => (transmit.contents.to_vec(), transmit.destination),
                    };
                    // UDP is best-effort: an unreachable candidate (or a
                    // network change) fails one send, not the call.
                    if self.socket.send_to(&contents, destination).is_err() {
                        self.report.send_errors += 1;
                    }
                }
                RtcOutput::Event(event) => self.handle_event(event)?,
            }
        }
    }

    fn handle_event(&mut self, event: RtcEvent) -> Result<(), Error> {
        match event {
            RtcEvent::Connected => {
                self.dtls_up = true;
                self.connected = true;
                self.state("connected", None);
            }
            RtcEvent::IceConnectionStateChange(IceConnectionState::Disconnected) => {
                self.connected = false;
                self.state("disconnected", None);
            }
            // ICE recovered after a disconnect (DTLS is still up): report it,
            // so the TUI cancels its grace timer like the browser does.
            RtcEvent::IceConnectionStateChange(
                IceConnectionState::Connected | IceConnectionState::Completed,
            ) if self.dtls_up && !self.connected => {
                self.connected = true;
                self.state("connected", None);
            }
            RtcEvent::MediaAdded(added) => {
                self.mid.get_or_insert(added.mid);
            }
            RtcEvent::MediaData(data) => {
                let mut frame = [0.0; FRAME];
                if !data.contiguous {
                    // A gap before this packet: conceal one frame.
                    self.decoder.conceal(&mut frame)?;
                    self.playback.write(&frame)?;
                    self.report.concealed += 1;
                }
                self.decoder.decode(&data.data, &mut frame)?;
                self.report.received(&frame);
                if !self.playback.write(&frame)? {
                    self.report.dropped += 1;
                }
            }
            _ => {}
        }
        Ok(())
    }

    /// Sends due STUN and TURN messages and trickles our new candidates
    /// once our SDP is out.
    fn gather(&mut self) -> Result<(), Error> {
        if !self.stun.is_done() {
            for (server, request) in self.stun.poll_transmit(Instant::now())? {
                if self.socket.send_to(&request, server).is_err() {
                    self.report.send_errors += 1;
                }
            }
        }

        if let Some(relay) = self.relay.as_mut() {
            let (messages, _wake) = relay.poll_transmit();
            for message in messages {
                if self.socket.send_to(&message, relay.server()).is_err() {
                    self.report.send_errors += 1;
                }
            }
            match relay.poll_event() {
                Some(RelayEvent::Allocated(addr)) => self.add_relayed(addr)?,
                Some(RelayEvent::Failed) => {
                    eprintln!("randos_media: TURN allocation failed; no relay candidate");
                    self.relay = None;
                }
                None => {}
            }
        }

        // Not gated on knowing the mid: an answerer learns it only later
        // (str0m's `MediaAdded`), and a candidate held back until then
        // never reaches the peer, who then never permits it on TURN. One
        // m-line, so `sdpMLineIndex` 0 identifies it.
        if self.sdp_sent && !self.unsent_candidates.is_empty() {
            let mid = self.mid.map(|mid| mid.to_string());
            for candidate in std::mem::take(&mut self.unsent_candidates) {
                self.signal_out(
                    "ice_candidate",
                    json!({"candidate": {
                        "candidate": candidate,
                        "sdpMid": mid,
                        "sdpMLineIndex": 0,
                        "usernameFragment": null,
                    }}),
                );
            }
        }
        Ok(())
    }

    /// A STUN server told us our outside address: offer it as a candidate,
    /// trickled (`gather`).
    fn add_server_reflexive(&mut self, mapped: SocketAddr) -> Result<(), Error> {
        // Not behind a NAT (or a test): the host candidate already covers it.
        if mapped == self.local {
            return Ok(());
        }
        let candidate = Candidate::server_reflexive(mapped, self.local, "udp")?;
        if let Some(added) = self.rtc.add_local_candidate(candidate) {
            self.unsent_candidates.push(added.to_sdp_string());
            self.report.local_candidates.push("srflx".into());
        }
        self.drain()
    }

    /// The TURN server gave us a relayed address: offer it (trickled).
    fn add_relayed(&mut self, addr: SocketAddr) -> Result<(), Error> {
        let candidate = Candidate::relayed(addr, self.local, "udp")?;
        if let Some(added) = self.rtc.add_local_candidate(candidate) {
            self.unsent_candidates.push(added.to_sdp_string());
            self.report.local_candidates.push("relay".into());
        }
        self.drain()
    }

    fn signal_out(&self, kind: &str, payload: Value) {
        (self.notify)(Event::CallSignal {
            kind: kind.into(),
            payload,
        });
    }

    fn state(&self, state: &str, reason: Option<String>) {
        (self.notify)(Event::CallState {
            state: state.into(),
            reason,
        });
    }
}

fn sdp_text(payload: &Value) -> Result<&str, Error> {
    payload
        .pointer("/sdp/sdp")
        .and_then(Value::as_str)
        .ok_or_else(|| "signal without sdp.sdp".into())
}

/// The candidate in an `ice_candidate` payload, or `None` for ones we skip:
/// end-of-candidates (`null` or `""`) and browsers' mDNS host candidates
/// (`….local`), which we can't resolve. ICE still connects: the browser's
/// checks reach our host candidate and str0m learns its address from them.
fn remote_candidate(payload: &Value, report: &mut Report) -> Option<Candidate> {
    let text = payload
        .pointer("/candidate/candidate")
        .and_then(Value::as_str)?;
    let text = text.strip_prefix("a=").unwrap_or(text);
    if text.is_empty() {
        return None;
    }
    match Candidate::from_sdp_string(text) {
        Ok(candidate) => Some(candidate),
        Err(_) => {
            report.skipped_candidates += 1;
            None
        }
    }
}

/// The local address of the default route: what peers on the network can
/// reach. Connecting a UDP socket sends nothing; it only picks a route.
fn default_route_ip() -> Result<IpAddr, Error> {
    let probe = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?;
    match probe.connect((Ipv4Addr::new(192, 0, 2, 1), 9)) {
        Ok(()) => Ok(probe.local_addr()?.ip()),
        // No route at all: only this machine is reachable.
        Err(_) => Ok(IpAddr::V4(Ipv4Addr::LOCALHOST)),
    }
}

/// Once a second: packets each way and the levels, so a test (or the TUI)
/// can tell audio is flowing in both directions.
struct Report {
    since: Instant,
    packets_sent: u64,
    packets_received: u64,
    concealed: u64,
    dropped: u64,
    skipped_candidates: u64,
    send_errors: u64,
    /// Kinds of our candidates offered so far ("host", "srflx").
    local_candidates: Vec<String>,
    input_peak: Peak,
    output_peak: Peak,
}

impl Report {
    fn new() -> Self {
        Self {
            since: Instant::now(),
            packets_sent: 0,
            packets_received: 0,
            concealed: 0,
            dropped: 0,
            skipped_candidates: 0,
            send_errors: 0,
            local_candidates: vec!["host".into()],
            input_peak: Peak::default(),
            output_peak: Peak::default(),
        }
    }

    fn sent(&mut self, frame: &[f32; FRAME]) {
        self.input_peak.add(frame);
    }

    fn received(&mut self, frame: &[f32; FRAME]) {
        self.packets_received += 1;
        self.output_peak.add(frame);
    }

    fn tick(&mut self, capture: &Capture, playback: &Playback, notify: &Notify) {
        if self.since.elapsed() < Duration::from_secs(1) {
            return;
        }
        notify(Event::CallStats(CallStats {
            packets_sent: self.packets_sent,
            packets_received: self.packets_received,
            concealed: self.concealed,
            dropped: self.dropped,
            skipped_candidates: self.skipped_candidates,
            send_errors: self.send_errors,
            local_candidates: self.local_candidates.clone(),
            input_peak_dbfs: self.input_peak.dbfs(),
            output_peak_dbfs: self.output_peak.dbfs(),
            capture_ring_ms: capture.queued_ms(),
            playback_ring_ms: playback.queued_ms(),
        }));
        // Counters are cumulative; peaks are per report.
        self.since = Instant::now();
        self.input_peak = Peak::default();
        self.output_peak = Peak::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::ToSocketAddrs;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// What one test peer reported, collected from its `Notify`.
    #[derive(Default)]
    struct Seen {
        signals: Vec<RemoteSignal>,
        /// Every candidate string this peer trickled (signals are consumed by
        /// the relay).
        trickled: Vec<String>,
        states: Vec<String>,
        stats: Vec<CallStats>,
    }

    fn peer(role: Role) -> (Call, Arc<Mutex<Seen>>) {
        peer_with(role, json!([]))
    }

    fn peer_with(role: Role, ice_servers: Value) -> (Call, Arc<Mutex<Seen>>) {
        peer_from(CallConfig {
            role,
            bind_ip: Some(IpAddr::V4(Ipv4Addr::LOCALHOST)),
            ice_servers,
            relay_only: false,
        })
    }

    fn peer_from(config: CallConfig) -> (Call, Arc<Mutex<Seen>>) {
        let seen = Arc::new(Mutex::new(Seen::default()));
        let notify: Notify = {
            let seen = Arc::clone(&seen);
            Arc::new(move |event| {
                let mut seen = seen.lock().unwrap();
                match event {
                    Event::CallSignal { kind, payload } => {
                        if let Some(c) = payload
                            .pointer("/candidate/candidate")
                            .and_then(Value::as_str)
                        {
                            seen.trickled.push(c.to_owned());
                        }
                        seen.signals.push(RemoteSignal { kind, payload })
                    }
                    Event::CallState { state, .. } => seen.states.push(state),
                    Event::CallStats(stats) => seen.stats.push(stats),
                    _ => {}
                }
            })
        };
        let (call, _started) = Call::start(config, Input::Sine, Output::Null, notify).unwrap();
        (call, seen)
    }

    /// Passes each peer's outgoing signals to the other, like the server's
    /// relay, for `duration`.
    fn relay(a: (&Call, &Mutex<Seen>), b: (&Call, &Mutex<Seen>), duration: Duration) {
        let until = Instant::now() + duration;
        while Instant::now() < until {
            for (from, to) in [(a.1, b.0), (b.1, a.0)] {
                for signal in std::mem::take(&mut from.lock().unwrap().signals) {
                    to.signal(signal).unwrap();
                }
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn two_peers_connect_and_carry_audio_both_ways() {
        let (offerer, offerer_seen) = peer(Role::Offerer);
        let (answerer, answerer_seen) = peer(Role::Answerer);

        relay(
            (&offerer, &offerer_seen),
            (&answerer, &answerer_seen),
            Duration::from_millis(3_500),
        );

        for (name, seen) in [("offerer", &offerer_seen), ("answerer", &answerer_seen)] {
            let seen = seen.lock().unwrap();
            assert!(
                seen.states.contains(&"connected".to_owned()),
                "{name} states: {:?}",
                seen.states
            );
            let last = seen
                .stats
                .last()
                .unwrap_or_else(|| panic!("{name} sent no stats"));
            assert!(
                last.packets_sent > 50,
                "{name} sent {} packets",
                last.packets_sent
            );
            assert!(
                last.packets_received > 50,
                "{name} received {} packets",
                last.packets_received
            );
            // The peer's 440 Hz tone (about -9 dBFS) came through Opus and RTP.
            assert!(
                last.output_peak_dbfs > -15.0,
                "{name} heard {} dBFS",
                last.output_peak_dbfs
            );
        }

        offerer.stop().unwrap();
        answerer.stop().unwrap();
    }

    /// A STUN server on loopback that answers every Binding request with
    /// `mapped` (as a NAT would report an outside address).
    fn fake_stun_server(mapped: SocketAddr) -> SocketAddr {
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        let addr = socket.local_addr().unwrap();
        thread::spawn(move || {
            let mut buf = [0u8; 1500];
            while let Ok((n, from)) = socket.recv_from(&mut buf) {
                let reply = crate::stun::tests::reply_to(&buf[..n], mapped);
                let _ = socket.send_to(&reply, from);
            }
        });
        addr
    }

    #[test]
    fn a_stun_server_gives_a_trickled_srflx_candidate_and_the_call_still_connects() {
        let outside: SocketAddr = "203.0.113.7:45678".parse().unwrap();
        let stun = fake_stun_server(outside);
        let ice = json!([{"urls": format!("stun:{stun}")}]);

        let (offerer, offerer_seen) = peer_with(Role::Offerer, ice);
        let (answerer, answerer_seen) = peer(Role::Answerer);
        relay(
            (&offerer, &offerer_seen),
            (&answerer, &answerer_seen),
            Duration::from_millis(3_500),
        );

        let seen = offerer_seen.lock().unwrap();
        assert!(
            seen.trickled
                .iter()
                .any(|c| c.contains("typ srflx") && c.contains("203.0.113.7 45678")),
            "trickled: {:?}",
            seen.trickled
        );
        let last = seen.stats.last().expect("stats");
        assert_eq!(last.local_candidates, vec!["host", "srflx"]);
        assert!(
            seen.states.contains(&"connected".to_owned()),
            "states: {:?}",
            seen.states
        );
        assert!(
            last.output_peak_dbfs > -15.0,
            "heard {} dBFS",
            last.output_peak_dbfs
        );

        // The answerer tried the unreachable srflx address: counted, not fatal.
        let answerer_last = answerer_seen
            .lock()
            .unwrap()
            .stats
            .last()
            .cloned()
            .expect("stats");
        assert!(answerer_last.packets_received > 50);

        drop(seen);
        offerer.stop().unwrap();
        answerer.stop().unwrap();
    }

    /// What the fake TURN server saw from its client.
    #[derive(Default)]
    struct TurnSeen {
        create_permissions: AtomicUsize,
        send_indications: AtomicUsize,
    }

    /// A TURN server on loopback (`turn-server-proto`, the same sans-IO
    /// family as our client), user `user`/`pass`. Returns its address.
    fn fake_turn_server() -> (SocketAddr, Arc<TurnSeen>) {
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

    #[test]
    fn a_turn_server_gives_a_trickled_relay_candidate_and_the_call_still_connects() {
        let (turn, turn_seen) = fake_turn_server();
        let ice =
            json!([{"urls": format!("turn:{turn}"), "username": "user", "credential": "pass"}]);

        let (offerer, offerer_seen) = peer_with(Role::Offerer, ice);
        let (answerer, answerer_seen) = peer(Role::Answerer);
        relay(
            (&offerer, &offerer_seen),
            (&answerer, &answerer_seen),
            Duration::from_millis(3_500),
        );

        let seen = offerer_seen.lock().unwrap();
        assert!(
            seen.trickled
                .iter()
                .any(|c| c.contains("typ relay") && c.contains("127.0.0.1")),
            "trickled: {:?}",
            seen.trickled
        );
        let last = seen.stats.last().expect("stats");
        assert_eq!(last.local_candidates, vec!["host", "relay"]);
        assert!(
            seen.states.contains(&"connected".to_owned()),
            "states: {:?}",
            seen.states
        );
        assert!(
            last.output_peak_dbfs > -15.0,
            "heard {} dBFS",
            last.output_peak_dbfs
        );
        drop(seen);

        // ICE checks the relay pair too (the host pair wins on loopback, so
        // this proves the plumbing, not that media went through the relay).
        assert!(turn_seen.create_permissions.load(Ordering::Relaxed) >= 1);
        assert!(turn_seen.send_indications.load(Ordering::Relaxed) >= 1);

        offerer.stop().unwrap();
        answerer.stop().unwrap();
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
        let creds = relay::TurnServer {
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
        let (turn, _) = fake_turn_server();
        let (event, _) = allocate(turn, "user", "pass", Duration::from_secs(2));
        assert!(matches!(event, Some(RelayEvent::Allocated(_))), "{event:?}");
        // Refused: no relay (the failure itself is reported only after the
        // crate's ~40 s transaction timeout; see `RelayEvent::Failed`).
        let (event, received) = allocate(turn, "user", "wrong", Duration::from_secs(1));
        assert_eq!(event, None);
        assert!(received >= 2, "the server answered both requests");
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
        assert_eq!(event, None);
        assert!(received >= 2, "coturn answered {received} times");
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
        let creds = relay::TurnServer {
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

    /// The checkpoint, end to end: two relay-only peers (no host or STUN
    /// candidates), so the whole call, ICE, DTLS and audio, goes through
    /// the real coturn. Credentials as in the test above.
    #[test]
    #[ignore = "needs coturn credentials in the environment"]
    fn production_turn_carries_a_whole_relay_only_call() {
        let ice = json!([{
            "urls": "turn:turn.slowinput.org:3478",
            "username": std::env::var("TURN_TEST_USERNAME").unwrap(),
            "credential": std::env::var("TURN_TEST_CREDENTIAL").unwrap(),
        }]);
        // The default route's address: coturn must be reachable.
        let relay_only = |role| {
            peer_from(CallConfig {
                role,
                bind_ip: None,
                ice_servers: ice.clone(),
                relay_only: true,
            })
        };
        let (offerer, offerer_seen) = relay_only(Role::Offerer);
        let (answerer, answerer_seen) = relay_only(Role::Answerer);
        relay(
            (&offerer, &offerer_seen),
            (&answerer, &answerer_seen),
            Duration::from_secs(8),
        );

        for seen in [&offerer_seen, &answerer_seen] {
            let seen = seen.lock().unwrap();
            assert!(
                seen.states.contains(&"connected".to_owned()),
                "states: {:?}",
                seen.states
            );
            let last = seen.stats.last().expect("stats");
            assert_eq!(last.local_candidates, vec!["relay"]);
            assert!(
                last.packets_received > 100,
                "received {}",
                last.packets_received
            );
            assert!(
                last.output_peak_dbfs > -15.0,
                "heard {} dBFS",
                last.output_peak_dbfs
            );
        }
        offerer.stop().unwrap();
        answerer.stop().unwrap();
    }
}
