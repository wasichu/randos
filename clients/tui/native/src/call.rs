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
    stun: Gatherer,
    /// Our candidates found after the SDP went out, waiting for the media id
    /// they're trickled under.
    unsent_candidates: Vec<String>,
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
        rtc.add_local_candidate(Candidate::host(local, "udp")?);

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
            report: Report::new(),
            notify,
            buf: vec![0; 2000],
            ice_servers: config.ice_servers.clone(),
            stun: Gatherer::new(Vec::new(), Instant::now()),
            unsent_candidates: Vec::new(),
        })
    }

    fn run(&mut self, role: Role, inbox: &Receiver<Command>) -> Result<(), Error> {
        // Resolve the STUN servers here, not in `Call::start`: DNS can be
        // slow, and the Port must keep answering meanwhile.
        let servers = stun::resolve(&stun::stun_servers(&self.ice_servers), self.local);
        self.stun = Gatherer::new(servers, Instant::now());

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
        self.drain()
    }

    fn send_offer(&mut self) -> Result<(), Error> {
        let mut change = self.rtc.sdp_api();
        let mid = change.add_media(MediaKind::Audio, Direction::SendRecv, None, None, None);
        let (offer, pending) = change.apply().ok_or("no offer to send")?;
        self.mid = Some(mid);
        self.pending_offer = Some(pending);
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

    /// Polls the `Rtc` until it has nothing more to do right now.
    fn drain(&mut self) -> Result<(), Error> {
        loop {
            match self.rtc.poll_output()? {
                RtcOutput::Timeout(at) => {
                    self.next_timeout = at;
                    return Ok(());
                }
                RtcOutput::Transmit(transmit) => {
                    // UDP is best-effort: an unreachable candidate (or a
                    // network change) fails one send, not the call.
                    if self
                        .socket
                        .send_to(&transmit.contents, transmit.destination)
                        .is_err()
                    {
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

    /// Sends due STUN requests and trickles any of our candidates still
    /// waiting for the media id.
    fn gather(&mut self) -> Result<(), Error> {
        if !self.stun.is_done() {
            for (server, request) in self.stun.poll_transmit(Instant::now())? {
                if self.socket.send_to(&request, server).is_err() {
                    self.report.send_errors += 1;
                }
            }
        }

        if let (Some(mid), false) = (self.mid, self.unsent_candidates.is_empty()) {
            for candidate in std::mem::take(&mut self.unsent_candidates) {
                self.signal_out(
                    "ice_candidate",
                    json!({"candidate": {
                        "candidate": candidate,
                        "sdpMid": mid.to_string(),
                        "sdpMLineIndex": 0,
                        "usernameFragment": null,
                    }}),
                );
            }
        }
        Ok(())
    }

    /// A STUN server told us our outside address: offer it as a candidate.
    /// The SDP has already gone out, so it's trickled (`gather`).
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
    use std::sync::Mutex;

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
        let config = CallConfig {
            role,
            bind_ip: Some(IpAddr::V4(Ipv4Addr::LOCALHOST)),
            ice_servers,
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
}
