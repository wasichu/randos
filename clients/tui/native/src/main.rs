//! Randos media helper, run by the TUI as an Erlang Port (`{:packet, 4}`).
//!
//! Stage 0 skeleton: answers `ping` with `pong` and exits when stdin closes.
//! The message protocol is documented in `clients/tui/native/README.md`.

mod frame;

use std::io::{self, BufReader, BufWriter};
use std::process::ExitCode;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("randos_media: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> io::Result<()> {
    let mut input = BufReader::new(io::stdin().lock());
    let mut output = BufWriter::new(io::stdout().lock());

    while let Some(message) = frame::read_frame(&mut input)? {
        let reply: &[u8] = match message.as_slice() {
            b"ping" => b"pong",
            _ => b"error:unknown_message",
        };
        frame::write_frame(&mut output, reply)?;
    }

    Ok(())
}
