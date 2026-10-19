//! Randos media helper, run by the TUI as an Erlang Port (`{:packet, 4}`,
//! JSON bodies). The protocol is documented in `clients/tui/native/README.md`.
//!
//! Stage 0: `ping`, and a mic → Opus → speaker loopback (`loopback_start`/
//! `loopback_stop`) for checking audio before WebRTC exists. Run with
//! `--loopback` for the same loopback straight from a terminal.

mod codec;
mod frame;
mod loopback;
mod protocol;
mod resample;

use std::io::{self, BufReader, BufWriter};
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::Duration;

use loopback::{Loopback, Notify};
use protocol::{Command, Event, Outgoing};

pub type Error = Box<dyn std::error::Error + Send + Sync>;

const USAGE: &str = "usage: randos_media                (Port mode: JSON frames on stdin/stdout)\n       \
                     randos_media --loopback [--in device|sine] [--out device|null|wav:PATH] [--seconds N]";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        None => serve_port(),
        Some("--loopback") => run_cli_loopback(args.get(1..).unwrap_or_default()),
        Some(_) => Err(USAGE.into()),
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("randos_media: {err}");
            ExitCode::FAILURE
        }
    }
}

/// Serves requests until the TUI closes stdin. One writer thread owns stdout,
/// so replies (from here) and events (from the loopback) never interleave.
fn serve_port() -> Result<(), Error> {
    let (outgoing, to_write) = mpsc::channel();
    let writer = thread::Builder::new()
        .name("port-writer".into())
        .spawn(move || write_outgoing(to_write))?;

    let served = read_requests(&outgoing);
    // The writer exits once every sender is gone: ours, and the loopback's
    // (dropped with it in `read_requests`).
    drop(outgoing);
    let written = writer.join().map_err(|_| "port writer panicked")?;
    served.and(written)
}

fn read_requests(outgoing: &Sender<Outgoing>) -> Result<(), Error> {
    let notify: Notify = {
        let outgoing = outgoing.clone();
        Arc::new(move |event| {
            // Only fails once the writer is gone, i.e. while shutting down.
            let _ = outgoing.send(Outgoing::Event(event));
        })
    };
    let mut input = BufReader::new(io::stdin().lock());
    let mut loopback = None;

    while let Some(body) = frame::read_frame(&mut input)? {
        let reply = match protocol::parse(&body) {
            Ok(request) => match handle(request.command, &mut loopback, &notify) {
                Ok(ok) => Outgoing::Ok {
                    reply: request.id,
                    ok,
                },
                Err(err) => Outgoing::Error {
                    reply: Some(request.id),
                    error: err.to_string(),
                },
            },
            Err((reply, error)) => Outgoing::Error { reply, error },
        };
        outgoing.send(reply).map_err(|_| "port writer stopped")?;
    }

    // stdin closed: the TUI is gone, so there's nobody to report a
    // loopback failure to (it was already sent as an event, if any).
    if let Some(running) = loopback {
        let _ = Loopback::stop(running);
    }
    Ok(())
}

fn handle(
    command: Command,
    loopback: &mut Option<Loopback>,
    notify: &Notify,
) -> Result<serde_json::Value, Error> {
    match command {
        Command::Ping => Ok("pong".into()),
        Command::LoopbackStart { input, out } => {
            // A loopback that failed on its own already reported it; clear it.
            if let Some(failed) = loopback.take_if(|running| !running.is_running()) {
                let _ = failed.stop();
            }
            if loopback.is_some() {
                return Err("loopback already running".into());
            }
            let (running, started) =
                Loopback::start(input.parse()?, out.parse()?, Arc::clone(notify))?;
            *loopback = Some(running);
            Ok(serde_json::to_value(started)?)
        }
        Command::LoopbackStop => {
            loopback.take().map(Loopback::stop).transpose()?;
            Ok(true.into())
        }
    }
}

fn write_outgoing(messages: Receiver<Outgoing>) -> Result<(), Error> {
    let mut output = BufWriter::new(io::stdout().lock());
    for message in messages {
        frame::write_frame(&mut output, &protocol::encode(&message)?)?;
    }
    Ok(())
}

/// `--loopback`: the same loopback from a terminal, events printed to stderr.
fn run_cli_loopback(args: &[String]) -> Result<(), Error> {
    let (mut input, mut output, mut seconds) = ("device", "device", 20);
    let mut args = args.iter();

    while let Some(arg) = args.next() {
        let value = args
            .next()
            .ok_or_else(|| format!("{arg} needs a value\n{USAGE}"))?;
        match arg.as_str() {
            "--in" => input = value,
            "--out" => output = value,
            "--seconds" => seconds = value.parse()?,
            _ => return Err(format!("unknown argument {arg}\n{USAGE}").into()),
        }
    }

    let notify: Notify = Arc::new(|event: Event| eprintln!("randos_media: {event}"));
    let (running, started) = Loopback::start(input.parse()?, output.parse()?, notify)?;
    eprintln!("randos_media: input: {}", started.input);
    eprintln!("randos_media: output: {}", started.output);

    thread::sleep(Duration::from_secs(seconds));
    running.stop()
}
