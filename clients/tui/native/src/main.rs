//! Randos media helper, run by the TUI as an Erlang Port (`{:packet, 4}`).
//!
//! Stage 0: answers `ping` with `pong` and exits when stdin closes. With
//! `--loopback` it also runs mic → Opus → speaker (see `loopback`), for
//! measuring latency and checking mic permission by hand.
//! The message protocol is documented in `clients/tui/native/README.md`.

mod codec;
mod frame;
mod loopback;

use std::io::{self, BufReader, BufWriter};
use std::path::PathBuf;
use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use loopback::{Input, Loopback, Output};

pub type Error = Box<dyn std::error::Error + Send + Sync>;

const USAGE: &str = "usage: randos_media [--loopback [--in device|sine] \
                     [--out device|null|wav:PATH] [--seconds N]]";

struct Args {
    loopback: Option<(Input, Output)>,
    seconds: Option<u64>,
}

fn main() -> ExitCode {
    match parse_args(std::env::args().skip(1)).and_then(run) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("randos_media: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: Args) -> Result<(), Error> {
    let loopback = args
        .loopback
        .map(|(input, output)| Loopback::start(input, output))
        .transpose()?;

    match args.seconds {
        Some(seconds) => thread::sleep(Duration::from_secs(seconds)),
        None => serve_port()?,
    }

    loopback.map(Loopback::stop).transpose()?;
    Ok(())
}

/// Answers Port messages until the TUI closes stdin.
fn serve_port() -> io::Result<()> {
    let mut input = BufReader::new(io::stdin().lock());
    let mut output = BufWriter::new(io::stdout().lock());

    while let Some(message) = frame::read_frame(&mut input)? {
        let reply = match message.as_slice() {
            b"ping" => b"pong".as_slice(),
            _ => b"error:unknown_message".as_slice(),
        };
        frame::write_frame(&mut output, reply)?;
    }

    Ok(())
}

fn parse_args(mut args: impl Iterator<Item = String>) -> Result<Args, Error> {
    let mut loopback = false;
    let (mut input, mut output, mut seconds) = (Input::Device, Output::Device, None);

    while let Some(arg) = args.next() {
        let mut value = || {
            args.next()
                .ok_or_else(|| format!("{arg} needs a value\n{USAGE}"))
        };

        match arg.as_str() {
            "--loopback" => loopback = true,
            "--in" => {
                input = match value()?.as_str() {
                    "device" => Input::Device,
                    "sine" => Input::Sine,
                    other => return Err(format!("unknown --in {other}\n{USAGE}").into()),
                }
            }
            "--out" => {
                output = match value()?.as_str() {
                    "device" => Output::Device,
                    "null" => Output::Null,
                    other => match other.strip_prefix("wav:") {
                        Some(path) => Output::Wav(PathBuf::from(path)),
                        None => return Err(format!("unknown --out {other}\n{USAGE}").into()),
                    },
                }
            }
            "--seconds" => seconds = Some(value()?.parse()?),
            _ => return Err(format!("unknown argument {arg}\n{USAGE}").into()),
        }
    }

    Ok(Args {
        loopback: loopback.then_some((input, output)),
        seconds,
    })
}
