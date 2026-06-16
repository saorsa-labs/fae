//! Verify `AudioManager::play_start` / `play_stop` (voice spine V3a): a
//! non-blocking start returns immediately, the realtime callback streams the
//! playback RMS envelope, and `play_stop` barges in mid-clip (the `level`
//! channel closes and levels stop arriving).
//!
//! Synthesises a long (~3 s) signal, starts it, lets a few levels stream, then
//! stops it mid-clip and asserts the collector thread's channel closed promptly
//! (well before the clip would have finished). Run on a machine with an output
//! device:
//!
//! `cargo run -p fae-audio --example play_level_interruptible`

use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use fae_audio::{encode_wav_pcm16, AudioManager};

fn main() {
    let sample_rate = 24_000u32;
    // ~3 s of continuous tone so there is plenty of audio to interrupt.
    let total = (sample_rate as f32 * 3.0) as usize;
    let mut samples = Vec::with_capacity(total);
    for i in 0..total {
        let t = i as f32 / sample_rate as f32;
        // A gentle swell every ~0.4 s so the envelope visibly rises/falls.
        let env = (std::f32::consts::PI * 2.5 * t).sin().abs();
        samples.push((2.0 * std::f32::consts::PI * 220.0 * t).sin() * 0.5 * env);
    }
    let wav = encode_wav_pcm16(&samples, sample_rate);

    let (tx, rx) = mpsc::channel::<f32>();
    // The collector owns `rx` exclusively: it drains levels until the worker
    // drops the `level` sender (on `play_stop` or natural end-of-samples).
    let collector = thread::spawn(move || {
        let mut levels = Vec::new();
        while let Ok(level) = rx.recv() {
            levels.push(level);
        }
        levels
    });

    let manager = AudioManager::new();

    // `play_start` must be non-blocking: time it and assert it returns well
    // before the clip finishes.
    let started = Instant::now();
    let id = match manager.play_start(&wav, tx) {
        Ok(id) => id,
        Err(error) => {
            eprintln!("play_start error: {error:?}");
            std::process::exit(1);
        }
    };
    let start_ms = started.elapsed().as_millis();
    println!("play_start returned id={id} in {start_ms} ms (non-blocking)");

    // Let the realtime callback stream a few levels before barging in.
    thread::sleep(Duration::from_millis(350));

    // Barge in mid-clip (the clip is ~3000 ms; we stop at ~350 ms).
    let stopped_at = Instant::now();
    if let Err(error) = manager.play_stop(&id) {
        eprintln!("play_stop error: {error:?}");
        std::process::exit(1);
    }

    // The collector thread's `rx.recv()` returns Err once the worker drops the
    // `level` sender (on `play_stop`). join() should therefore return promptly.
    let levels = match collector.join() {
        Ok(levels) => levels,
        Err(panic) => {
            eprintln!("level collector thread panicked: {panic:?}");
            std::process::exit(1);
        }
    };
    let stop_to_close_ms = stopped_at.elapsed().as_millis();
    let max_seen = levels.iter().copied().fold(0.0_f32, f32::max);
    let above = levels.iter().filter(|level| **level > 0.05).count();
    println!(
        "after stop: {} total levels ({} > 0.05), max={:.3}, channel closed {} ms after play_stop",
        levels.len(),
        above,
        max_seen,
        stop_to_close_ms,
    );

    // Stopping an already-stopped clip must report not-found.
    match manager.play_stop(&id) {
        Err(fae_audio::AudioError::PlaybackNotFound) => {
            println!("double-stop correctly reports PlaybackNotFound");
        }
        other => {
            eprintln!("expected PlaybackNotFound on double-stop, got {other:?}");
            std::process::exit(1);
        }
    }

    assert!(
        start_ms < 500,
        "play_start should be non-blocking (returned in {start_ms} ms)"
    );
    assert!(
        max_seen > 0.05,
        "expected a streamed level above 0.05 before stop, got max {max_seen}"
    );
    assert!(
        stop_to_close_ms < 1500,
        "level channel should close shortly after play_stop (closed in {stop_to_close_ms} ms)"
    );
    println!("OK: non-blocking start, streamed levels, and prompt barge-in");
}
