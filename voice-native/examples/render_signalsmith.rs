//! Finite test renderer: bounded little-endian f32 stdin/stdout, no devices.
use randos_voice_native::{BATCH, CORE_DELAY, Engine, FRAME, Masker, Style};
use std::io::{self, Read, Write};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let style = match args.next().as_deref() {
        Some("0") => Style::LowerResonance,
        Some("1") => Style::LowerResonancePitch,
        Some("2") => Style::HigherResonance,
        Some("3") => Style::HigherResonancePitch,
        _ => return Err("style 0..3 required".into()),
    };
    let mode = args.next().ok_or("raw|stream required")?;
    let mut bytes = Vec::new();
    io::stdin().take(4_000_001).read_to_end(&mut bytes)?;
    if bytes.is_empty() || bytes.len() > 4_000_000 || !bytes.len().is_multiple_of(4) {
        return Err("invalid bounded PCM".into());
    }
    let input: Vec<f32> = bytes
        .as_chunks::<4>()
        .0
        .iter()
        .map(|chunk| f32::from_le_bytes(*chunk))
        .collect();
    let (output, skip) = match mode.as_str() {
        "raw" => {
            let mut engine = Engine::new(style)?;
            let mut output = Vec::new();
            for chunk in input.chunks(BATCH) {
                let mut block = vec![0.0; chunk.len()];
                engine.process(chunk, &mut block)?;
                output.extend(block);
            }
            let mut tail = [0.0; 1920];
            engine.process(&[0.0; 1920], &mut tail)?;
            output.extend(tail);
            engine.finish(&mut tail)?;
            output.extend(tail);
            (output, CORE_DELAY)
        }
        "stream" => {
            let mut masker = Masker::new(style)?;
            let mut output = Vec::new();
            for chunk in input.chunks(FRAME) {
                let mut frame = [0.0; FRAME];
                frame
                    .get_mut(..chunk.len())
                    .ok_or("input range")?
                    .copy_from_slice(chunk);
                let mut block = [0.0; FRAME];
                masker.process(&frame, &mut block)?;
                output.extend(block);
            }
            // Only this finite test feeds silence to observe the complete tail.
            for _ in 0..12 {
                let mut block = [0.0; FRAME];
                masker.process(&[0.0; FRAME], &mut block)?;
                output.extend(block);
            }
            (output, 11 * FRAME)
        }
        _ => return Err("raw|stream required".into()),
    };
    let aligned = output
        .get(skip..skip + input.len())
        .ok_or("incomplete output")?;
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    for sample in aligned {
        stdout.write_all(&sample.to_le_bytes())?;
    }
    stdout.flush()?;
    Ok(())
}
