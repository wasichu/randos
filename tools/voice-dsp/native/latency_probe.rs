//! File/synthetic-only research probe. Stdout is bounded JSON, never a media Port.
#![deny(unsafe_code)]

use randos_voice_native::{Masker, Style, FRAME, FRAME_PREFIX_SAMPLES};
use std::error::Error;
use std::io::{Read, Write};
use std::sync::mpsc::{self, TrySendError};
use std::time::{Duration, Instant};

type Failure = Box<dyn Error>;

fn state(masker: &Masker) -> Option<(usize, usize, bool)> {
    #[cfg(research_copy)]
    {
        Some(masker.research_state())
    }
    #[cfg(not(research_copy))]
    {
        let _ = masker;
        None
    }
}

fn sleep_until(due: Instant) {
    if let Some(left) = due.checked_duration_since(Instant::now()) {
        std::thread::sleep(left);
    }
}

fn main() -> Result<(), Failure> {
    // Parent's open control pipe owns this process, including parent SIGKILL.
    std::thread::spawn(|| {
        let mut byte = [0_u8; 1];
        loop {
            match std::io::stdin().read(&mut byte) {
                Ok(0) => std::process::exit(72),
                Err(e) if e.kind() != std::io::ErrorKind::Interrupted => std::process::exit(72),
                _ => {}
            }
        }
    });
    let mut args = std::env::args().skip(1);
    let style = match args.next().as_deref() {
        Some("0") => Style::LowerResonance,
        Some("1") => Style::LowerResonancePitch,
        Some("2") => Style::HigherResonance,
        Some("3") => Style::HigherResonancePitch,
        _ => return Err("style 0..3 required".into()),
    };
    let path = args.next().ok_or("input file required")?;
    let output_path = args.next().ok_or("output file required")?;
    let seconds: usize = args.next().ok_or("duration required")?.parse()?;
    let jitter = args.next().ok_or("jitter none|phases|bursts required")?;
    if seconds > 120 || !["none", "phases", "bursts"].contains(&jitter.as_str()) {
        return Err("invalid probe configuration".into());
    }
    let bytes = std::fs::read(path)?;
    if bytes.is_empty() || bytes.len() > 4_000_000 || bytes.len() % 4 != 0 {
        return Err("invalid fixture bytes".into());
    }
    let input: Vec<f32> = bytes
        .as_chunks::<4>()
        .0
        .iter()
        .map(|b| f32::from_le_bytes(*b))
        .collect();
    if !input.iter().all(|v| v.is_finite()) || input.len() % FRAME != 0 {
        return Err("fixture must have complete finite frames".into());
    }
    let setup = Instant::now();
    let mut masker = Masker::new(style)?;
    let setup_ms = setup.elapsed().as_secs_f64() * 1000.;
    let mut first_primed = None;
    let mut min_queued = usize::MAX;
    let mut max_queued = 0;
    let mut compute = Vec::new();
    let mut rendered = Vec::new();
    let mut max_capture_backlog = 0.;
    let mut max_completion_late = 0.;
    let mut late_completions = 0;
    let mut catchup_bursts = 0;
    let mut previous_completion: Option<Instant> = None;
    let mut ages = Vec::new();
    let origin = Instant::now();
    let frames = if seconds == 0 {
        input.len() / FRAME + 48
    } else {
        seconds * 50
    };
    let producer = if seconds > 0 {
        let (tx, rx) = mpsc::sync_channel(8);
        let fixture = input.clone();
        let producer = std::thread::spawn(move || -> Result<f64, String> {
            let mut worst_late: f64 = 0.;
            for frame in 0..frames {
                let due = origin + Duration::from_millis((frame as u64 + 1) * 20);
                sleep_until(due);
                worst_late = worst_late
                    .max(Instant::now().saturating_duration_since(due).as_secs_f64() * 1000.);
                let mut block = [0.; FRAME];
                for (at, value) in block.iter_mut().enumerate() {
                    *value = *fixture
                        .get((frame * FRAME + at) % fixture.len())
                        .ok_or("fixture range")?;
                }
                match tx.try_send((due, block)) {
                    Ok(()) => {}
                    Err(TrySendError::Full(_)) => {
                        return Err("bounded synthetic capture queue overflow".into())
                    }
                    Err(TrySendError::Disconnected(_)) => {
                        return Err("capture consumer stopped".into())
                    }
                }
            }
            Ok(worst_late)
        });
        Some((producer, rx))
    } else {
        None
    };
    for frame in 0..frames {
        let (due, block) = if let Some((_, rx)) = &producer {
            rx.recv()?
        } else {
            let mut block = [0.; FRAME];
            if let Some(chunk) = input.get(frame * FRAME..(frame + 1) * FRAME) {
                block.copy_from_slice(chunk);
            }
            (origin, block)
        };
        let stall = match jitter.as_str() {
            // Exercise all four positions in the unchanged 80 ms batch cycle.
            "phases" if frame >= 50 && frame % 100 < 4 => 12,
            "bursts" if frame >= 50 && frame % 150 < 2 => 35,
            _ => 0,
        };
        if stall > 0 {
            std::thread::sleep(Duration::from_millis(stall));
        }
        if seconds > 0 {
            max_capture_backlog = f64::max(
                max_capture_backlog,
                Instant::now().saturating_duration_since(due).as_secs_f64() * 1000.,
            );
        }
        let began = Instant::now();
        let mut out = [0.; FRAME];
        masker.process(&block, &mut out)?;
        compute.push(began.elapsed().as_secs_f64() * 1000.);
        if let Some((_, queued, primed)) = state(&masker) {
            max_queued = max_queued.max(queued);
            if primed {
                first_primed.get_or_insert(frame);
                min_queued = min_queued.min(queued);
            }
        }
        if seconds == 0 {
            rendered.extend_from_slice(&out);
        } else {
            let completed = Instant::now();
            let late = completed
                .saturating_duration_since(due + Duration::from_millis(20))
                .as_secs_f64()
                * 1000.;
            max_completion_late = f64::max(max_completion_late, late);
            if late > 0. {
                late_completions += 1;
            }
            if previous_completion.is_some_and(|previous| {
                completed.duration_since(previous) < Duration::from_millis(10)
            }) {
                catchup_bursts += 1;
            }
            previous_completion = Some(completed);
            if let Some(prefix) = first_primed {
                let original_capture_end =
                    origin + Duration::from_millis(((frame + 1 - prefix) as u64) * 20);
                ages.push(
                    completed
                        .saturating_duration_since(original_capture_end)
                        .as_secs_f64()
                        * 1000.,
                );
            }
        }
    }
    let producer_late = if let Some((producer, _)) = producer {
        producer
            .join()
            .map_err(|_| "capture producer panicked")?
            .map_err(|e| -> Failure { e.into() })?
    } else {
        0.
    };
    let prefix = first_primed.unwrap_or(FRAME_PREFIX_SAMPLES / FRAME);
    if seconds == 0 {
        let aligned = rendered
            .get(prefix * FRAME..prefix * FRAME + input.len())
            .ok_or("incomplete drain")?;
        let mut out = std::io::BufWriter::new(std::fs::File::create(output_path)?);
        for sample in aligned {
            out.write_all(&sample.to_le_bytes())?;
        }
        out.flush()?;
    }
    // Sticky invalid-input failure must emit silence; reset must erase history.
    let mut bad = [0.; FRAME];
    *bad.first_mut().ok_or("frame")? = f32::NAN;
    let mut out = [0.5; FRAME];
    if masker.process(&bad, &mut out).is_ok() || out.iter().any(|v| *v != 0.) {
        return Err("nonfinite input leaked".into());
    }
    if masker.process(&[0.; FRAME], &mut out).is_ok() || out.iter().any(|v| *v != 0.) {
        return Err("failure was not sticky".into());
    }
    masker.reset()?;
    for _ in 0..20 {
        masker.process(&[0.; FRAME], &mut out)?;
        if out.iter().any(|v| *v != 0.) {
            return Err("reset retained speech".into());
        }
    }
    compute.sort_by(f64::total_cmp);
    ages.sort_by(f64::total_cmp);
    let quantile = |v: &[f64], q: f64| {
        v.get(((v.len().saturating_sub(1)) as f64 * q) as usize)
            .copied()
            .unwrap_or(0.)
    };
    let mean = compute.iter().sum::<f64>() / compute.len() as f64;
    println!("{{\"frames\":{frames},\"setup_ms\":{setup_ms},\"first_delivery_ms\":{},\"additional_frame_offset_ms\":{},\"compute_mean_ms\":{mean},\"compute_p95_ms\":{},\"compute_max_ms\":{},\"min_queue_after_pop_samples\":{},\"max_queue_after_pop_samples\":{max_queued},\"producer_late_max_ms\":{producer_late},\"capture_backlog_max_ms\":{max_capture_backlog},\"completion_late_max_ms\":{max_completion_late},\"late_completions\":{late_completions},\"catchup_bursts\":{catchup_bursts},\"send_equivalent_age_p95_ms\":{},\"send_equivalent_age_max_ms\":{},\"failure_reset_pass\":true}}",(prefix+1)*20,prefix*20,quantile(&compute,0.95),quantile(&compute,1.),if min_queued==usize::MAX{0}else{min_queued},quantile(&ages,0.95),quantile(&ages,1.));
    Ok(())
}
