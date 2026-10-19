//! Port framing: each message is a 4-byte big-endian length followed by that
//! many bytes, matching Erlang's `{:packet, 4}` Port option.

use std::io::{self, Read, Write};

/// Largest frame we accept (a 20 ms 48 kHz mono s16 frame is 1920 bytes; SDP
/// is a few KB). Anything bigger is a protocol error, not an allocation.
pub const MAX_FRAME: usize = 1 << 20;

/// Reads one frame. `Ok(None)` means the peer closed the stream cleanly.
pub fn read_frame(reader: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0u8; 4];
    match reader.read_exact(&mut header) {
        Ok(()) => {}
        Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(err),
    }

    let len = u32::from_be_bytes(header) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame of {len} bytes exceeds {MAX_FRAME}"),
        ));
    }

    let mut body = vec![0u8; len];
    reader.read_exact(&mut body)?;
    Ok(Some(body))
}

/// Writes one frame and flushes it.
pub fn write_frame(writer: &mut impl Write, body: &[u8]) -> io::Result<()> {
    let len = u32::try_from(body.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "frame too large"))?;
    writer.write_all(&len.to_be_bytes())?;
    writer.write_all(body)?;
    writer.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_frames() {
        let mut buf = Vec::new();
        write_frame(&mut buf, b"hello").unwrap();
        write_frame(&mut buf, b"").unwrap();

        let mut reader = buf.as_slice();
        assert_eq!(read_frame(&mut reader).unwrap(), Some(b"hello".to_vec()));
        assert_eq!(read_frame(&mut reader).unwrap(), Some(Vec::new()));
        assert_eq!(read_frame(&mut reader).unwrap(), None);
    }

    #[test]
    fn rejects_oversized_frames_without_allocating() {
        let header = u32::try_from(MAX_FRAME + 1).unwrap().to_be_bytes();
        let err = read_frame(&mut header.as_slice()).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn truncated_body_is_an_error() {
        let mut buf = Vec::new();
        write_frame(&mut buf, b"hello").unwrap();
        buf.truncate(6);
        assert!(read_frame(&mut buf.as_slice()).is_err());
    }
}
