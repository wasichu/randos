//! The call's reports to the TUI: `call_stats` once a second (packets,
//! loss handling, levels, path) and `call_levels` every 50 ms (the meters).

use std::time::{Duration, Instant};

use crate::audio::{Capture, Notify, Playback};
use crate::candidates::Candidates;
use crate::codec::{FRAME, Peak};
use crate::protocol::{CallStats, Event};
use crate::spectrum::Analyser;

/// Once a second: packets each way and the levels, so a test (or the TUI)
/// can tell audio is flowing in both directions.
pub(crate) struct Report {
    pub(crate) since: Instant,
    pub(crate) packets_sent: u64,
    pub(crate) packets_received: u64,
    pub(crate) concealed: u64,
    /// Lost frames rebuilt from the next packet's FEC data.
    pub(crate) recovered: u64,
    pub(crate) dropped: u64,
    pub(crate) skipped_candidates: u64,
    pub(crate) send_errors: u64,
    /// Kinds of our candidates offered so far ("host", "srflx").
    pub(crate) local_candidates: Vec<String>,
    pub(crate) input_peak: Peak,
    pub(crate) output_peak: Peak,
    /// The meters' bars, each way, sent every `LEVELS_EVERY`.
    pub(crate) input_bars: Analyser,
    pub(crate) output_bars: Analyser,
    pub(crate) levels_since: Instant,
}

/// How often `call_levels` goes out: the website's visualizer frame rate.
pub(crate) const LEVELS_EVERY: Duration = Duration::from_millis(50);

impl Report {
    pub(crate) fn new() -> Self {
        Self {
            since: Instant::now(),
            packets_sent: 0,
            packets_received: 0,
            concealed: 0,
            recovered: 0,
            dropped: 0,
            skipped_candidates: 0,
            send_errors: 0,
            local_candidates: vec!["host".into()],
            input_peak: Peak::default(),
            output_peak: Peak::default(),
            input_bars: Analyser::new(),
            output_bars: Analyser::new(),
            levels_since: Instant::now(),
        }
    }

    pub(crate) fn sent(&mut self, frame: &[f32; FRAME]) {
        self.input_peak.add(frame);
        self.input_bars.push(frame);
    }

    pub(crate) fn received(&mut self, frame: &[f32; FRAME]) {
        self.packets_received += 1;
        self.output_peak.add(frame);
        self.output_bars.push(frame);
    }

    pub(crate) fn tick(
        &mut self,
        capture: &Capture,
        playback: &Playback,
        notify: &Notify,
        candidates: &mut Candidates,
    ) {
        if self.levels_since.elapsed() >= LEVELS_EVERY {
            self.levels_since = Instant::now();
            // A failed FFT only skips one meter frame; it never ends the call.
            if let (Ok(you), Ok(peer)) = (self.input_bars.bars(), self.output_bars.bars()) {
                notify(Event::CallLevels {
                    you: rounded(&you),
                    peer: rounded(&peer),
                });
            }
        }
        if self.since.elapsed() < Duration::from_secs(1) {
            return;
        }
        notify(Event::CallStats(CallStats {
            packets_sent: self.packets_sent,
            packets_received: self.packets_received,
            concealed: self.concealed,
            recovered: self.recovered,
            dropped: self.dropped,
            skipped_candidates: self.skipped_candidates,
            send_errors: self.send_errors,
            local_candidates: self.local_candidates.clone(),
            input_peak_dbfs: self.input_peak.dbfs(),
            output_peak_dbfs: self.output_peak.dbfs(),
            capture_ring_ms: capture.queued_ms(),
            playback_ring_ms: playback.queued_ms(),
            path: candidates.take_path().map(String::from),
        }));
        // Counters are cumulative; peaks are per report.
        self.since = Instant::now();
        self.input_peak = Peak::default();
        self.output_peak = Peak::default();
    }
}

/// Two decimals are plenty for a meter, and keep the Port messages short.
pub(crate) fn rounded(bars: &[f32]) -> Vec<f32> {
    bars.iter()
        .map(|bar| (bar * 100.0).round() / 100.0)
        .collect()
}
