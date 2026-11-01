//! Opt-in, local numeric input diagnostics. Never PCM or participant/network data.
use std::fs::{File, OpenOptions};
use std::io::Write;

use crate::Error;
use crate::codec::{FRAME, Peak};
use crate::protocol::CallStats;

pub(crate) struct InputDiagnostics<W = File> {
    writer: W,
    frames: u64,
    raw: Peak,
    after_echo: Peak,
}

impl InputDiagnostics<File> {
    pub(crate) fn from_env() -> Result<Option<Self>, Error> {
        let Some(path) = std::env::var_os("RANDOS_AUDIO_DIAGNOSTICS") else {
            return Ok(None);
        };
        let writer = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Some(Self::new(writer)))
    }
}

impl<W: Write> InputDiagnostics<W> {
    fn new(writer: W) -> Self {
        Self {
            writer,
            frames: 0,
            raw: Peak::default(),
            after_echo: Peak::default(),
        }
    }

    pub(crate) fn captured(&mut self, frame: &[f32; FRAME]) {
        self.frames = self.frames.saturating_add(1);
        self.raw.add(frame);
    }

    pub(crate) fn after_echo(&mut self, frame: &[f32; FRAME]) {
        self.after_echo.add(frame);
    }

    pub(crate) fn write_snapshot(
        &mut self,
        stats: &CallStats,
        connected: bool,
        muted: bool,
    ) -> Result<(), Error> {
        serde_json::to_writer(
            &mut self.writer,
            &serde_json::json!({
                "captured_frames": self.frames,
                "raw_peak_dbfs": self.raw.dbfs(),
                "post_aec_peak_dbfs": self.after_echo.dbfs(),
                "sent_peak_dbfs": stats.input_peak_dbfs,
                "received_peak_dbfs": stats.output_peak_dbfs,
                "packets_sent": stats.packets_sent,
                "packets_received": stats.packets_received,
                "playback_dropped": stats.dropped,
                "capture_ring_ms": stats.capture_ring_ms,
                "playback_ring_ms": stats.playback_ring_ms,
                "connected": connected,
                "muted": muted,
            }),
        )?;
        self.writer.write_all(b"\n")?;
        self.writer.flush()?;
        self.raw = Peak::default();
        self.after_echo = Peak::default();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stats() -> CallStats {
        CallStats {
            packets_sent: 50,
            packets_received: 50,
            concealed: 0,
            recovered: 0,
            dropped: 2,
            skipped_candidates: 0,
            send_errors: 0,
            local_candidates: Vec::new(),
            path: None,
            input_peak_dbfs: -120.0,
            output_peak_dbfs: -120.0,
            capture_ring_ms: 0.0,
            playback_ring_ms: 20.0,
        }
    }

    struct Full;

    impl Write for Full {
        fn write(&mut self, _bytes: &[u8]) -> std::io::Result<usize> {
            Err(std::io::Error::other("diagnostic disk full"))
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn a_failed_diagnostic_write_is_explicit() {
        let mut diagnostics = InputDiagnostics::new(Full);
        let error = diagnostics
            .write_snapshot(&stats(), true, false)
            .unwrap_err();
        assert!(error.to_string().contains("diagnostic disk full"));
    }

    #[test]
    fn separates_raw_capture_from_echo_suppression_without_saving_samples() {
        let mut diagnostics = InputDiagnostics::new(Vec::new());
        diagnostics.captured(&[0.5; FRAME]);
        diagnostics.after_echo(&[0.0; FRAME]);
        assert_eq!(diagnostics.frames, 1);
        assert!(diagnostics.raw.dbfs() > -7.0);
        assert!(diagnostics.after_echo.dbfs() < -100.0);
        diagnostics.write_snapshot(&stats(), true, false).unwrap();
        let record: serde_json::Value = serde_json::from_slice(&diagnostics.writer).unwrap();
        assert_eq!(record["captured_frames"], 1);
        assert!(record["raw_peak_dbfs"].as_f64().unwrap() > -7.0);
        assert_eq!(record["post_aec_peak_dbfs"], -120.0);
        assert_eq!(record["sent_peak_dbfs"], -120.0);
        assert_eq!(record["muted"], false);
        assert_eq!(record.as_object().unwrap().len(), 12);
        assert!(
            record
                .as_object()
                .unwrap()
                .values()
                .all(|v| v.is_number() || v.is_boolean())
        );
        assert!(
            diagnostics.raw.dbfs() < -100.0,
            "peaks reset after each report"
        );
    }
}
