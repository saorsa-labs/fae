//! Verify `AudioManager::play_wav_streaming` emits a playback RMS envelope that
//! tracks the audio (gap C/D5 voice-spine V1). Synthesizes a 3-burst signal
//! (≈ three spoken "words" separated by silence), plays it through the default
//! output device, and asserts the streamed level envelope shows bursts + gaps.
//!
//! Run on a machine with an output device: `cargo run -p fae-audio --example play_level`.

use std::sync::mpsc;
use std::thread;

use fae_audio::{encode_wav_pcm16, AudioManager};

fn main() {
    let sample_rate = 24_000u32;
    let mut samples = Vec::new();
    for word in 0..3 {
        let freq = 180.0 + word as f32 * 80.0;
        let burst = (sample_rate as f32 * 0.25) as usize;
        for i in 0..burst {
            let t = i as f32 / sample_rate as f32;
            // Hann-shaped burst so each "word" swells and fades like speech.
            let env = (std::f32::consts::PI * i as f32 / burst as f32).sin();
            samples.push((2.0 * std::f32::consts::PI * freq * t).sin() * 0.6 * env);
        }
        let gap = (sample_rate as f32 * 0.15) as usize;
        samples.extend(std::iter::repeat_n(0.0, gap));
    }
    let wav = encode_wav_pcm16(&samples, sample_rate);

    let (tx, rx) = mpsc::channel::<f32>();
    let collector = thread::spawn(move || {
        let mut levels = Vec::new();
        while let Ok(level) = rx.recv() {
            levels.push(level);
        }
        levels
    });

    let manager = AudioManager::new();
    println!(
        "playing {} ms test signal (3 bursts)...",
        samples.len() * 1000 / sample_rate as usize
    );
    match manager.play_wav_streaming(&wav, tx) {
        Ok(ms) => println!("played {ms} ms"),
        Err(error) => {
            eprintln!("play error: {error:?}");
            std::process::exit(1);
        }
    }

    let levels = match collector.join() {
        Ok(levels) => levels,
        Err(panic) => {
            eprintln!("level collector thread panicked: {panic:?}");
            std::process::exit(1);
        }
    };
    let max = levels.iter().copied().fold(0.0f32, f32::max);
    let above = levels.iter().filter(|level| **level > 0.05).count();
    let near_zero = levels.iter().filter(|level| **level < 0.01).count();

    let bars = [
        ' ', '\u{2581}', '\u{2582}', '\u{2583}', '\u{2584}', '\u{2585}', '\u{2586}', '\u{2587}',
        '\u{2588}',
    ];
    let spark: String = levels
        .iter()
        .map(|level| {
            let idx = ((level / max.max(1e-6)) * 8.0).round().clamp(0.0, 8.0) as usize;
            bars[idx]
        })
        .collect();

    println!(
        "levels: {} readings, max={:.3}, >0.05: {}, <0.01: {}",
        levels.len(),
        max,
        above,
        near_zero
    );
    println!("envelope: |{spark}|");

    assert!(
        max > 0.1,
        "expected a non-trivial playback level, got {max}"
    );
    assert!(
        above >= 3 && near_zero >= 2,
        "expected bursts and gaps in the envelope (>0.05: {above}, <0.01: {near_zero})"
    );
    println!("OK: level envelope rides the signal (bursts + gaps visible)");
}
