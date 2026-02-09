//! Records wake word reference WAV files for the MFCC+DTW spotter.
//!
//! Usage: `cargo run --bin fae-record-wakeword`
//!
//! Records 5 samples of the wake word (default "Fae"), saves them as
//! 16kHz mono WAV files in `~/.fae/wakeword/`.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::collections::VecDeque;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Number of reference recordings to capture.
const NUM_RECORDINGS: usize = 5;
/// Duration of each recording in seconds.
const RECORD_SECONDS: f32 = 2.0;
/// Target sample rate for the pipeline.
const TARGET_RATE: u32 = 16_000;

fn main() {
    let wakeword_dir = wakeword_dir();
    if let Err(e) = std::fs::create_dir_all(&wakeword_dir) {
        eprintln!("Error creating directory {}: {e}", wakeword_dir.display());
        std::process::exit(1);
    }

    println!("=== Fae Wake Word Recorder ===");
    println!();
    println!("This will record {NUM_RECORDINGS} samples of you saying the wake word.");
    println!("Each recording is {RECORD_SECONDS} seconds.");
    println!("Speak clearly, at normal volume, about arm's length from the mic.");
    println!();
    println!("Saving to: {}", wakeword_dir.display());
    println!();

    let host = cpal::default_host();
    let device = match host.default_input_device() {
        Some(d) => d,
        None => {
            eprintln!("Error: no default input device found");
            std::process::exit(1);
        }
    };

    let device_name = device
        .description()
        .map(|d| d.name().to_owned())
        .unwrap_or_else(|_| "<unknown>".into());
    println!("Using mic: {device_name}");
    println!();

    let default_config = match device.default_input_config() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: no default input config: {e}");
            std::process::exit(1);
        }
    };

    let native_rate = default_config.sample_rate();
    let native_channels = default_config.channels();
    let stream_config = cpal::StreamConfig {
        channels: native_channels,
        sample_rate: native_rate,
        buffer_size: cpal::BufferSize::Default,
    };

    for i in 0..NUM_RECORDINGS {
        let filename = format!("fae_ref_{}.wav", i + 1);
        let path = wakeword_dir.join(&filename);

        println!(
            "Recording {}/{NUM_RECORDINGS}: Press ENTER when ready, then say \"Fae\"...",
            i + 1
        );
        wait_for_enter();

        // Countdown.
        for n in (1..=3).rev() {
            print!("  {n}...");
            let _ = std::io::stdout().flush();
            std::thread::sleep(std::time::Duration::from_millis(600));
        }
        println!(" GO!");

        match record_clip(&device, &stream_config, native_rate, native_channels) {
            Ok(samples) => {
                // Trim leading/trailing silence (< 0.005 RMS).
                let trimmed = trim_silence(&samples, 0.005);
                if trimmed.len() < (TARGET_RATE as usize / 10) {
                    println!("  Warning: very short or silent recording, saving anyway.");
                }

                match fae::wakeword::save_reference_wav(&path, &trimmed, TARGET_RATE) {
                    Ok(()) => {
                        let duration = trimmed.len() as f32 / TARGET_RATE as f32;
                        println!(
                            "  Saved: {filename} ({duration:.1}s, {} samples)",
                            trimmed.len()
                        );
                    }
                    Err(e) => {
                        eprintln!("  Error saving {filename}: {e}");
                    }
                }
            }
            Err(e) => {
                eprintln!("  Recording error: {e}");
            }
        }
        println!();
    }

    println!(
        "Done! {NUM_RECORDINGS} references saved to {}",
        wakeword_dir.display()
    );
    println!();
    println!("To enable the wake word spotter, add to ~/.config/fae/config.toml:");
    println!();
    println!("  [wakeword]");
    println!("  enabled = true");
    println!();
}

/// Record a clip from the microphone and return 16kHz mono f32 samples.
fn record_clip(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    native_rate: u32,
    native_channels: u16,
) -> Result<Vec<f32>, String> {
    let total_samples = (TARGET_RATE as f32 * RECORD_SECONDS) as usize;
    let buffer: Arc<Mutex<VecDeque<f32>>> =
        Arc::new(Mutex::new(VecDeque::with_capacity(total_samples + 1024)));
    let done = Arc::new(AtomicBool::new(false));

    let buf_clone = Arc::clone(&buffer);
    let done_clone = Arc::clone(&done);
    let nr = native_rate;
    let nc = native_channels;

    let stream = device
        .build_input_stream(
            config,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                if done_clone.load(Ordering::Relaxed) {
                    return;
                }

                // Convert to mono.
                let mono = if nc > 1 {
                    data.chunks(nc as usize)
                        .map(|frame| frame.iter().sum::<f32>() / nc as f32)
                        .collect::<Vec<f32>>()
                } else {
                    data.to_vec()
                };

                // Downsample to 16kHz if needed.
                let samples = if nr != TARGET_RATE {
                    downsample_linear(&mono, nr, TARGET_RATE)
                } else {
                    mono
                };

                if let Ok(mut buf) = buf_clone.lock() {
                    buf.extend(samples);
                }
            },
            move |err| {
                eprintln!("  Audio error: {err}");
            },
            None,
        )
        .map_err(|e| format!("failed to build stream: {e}"))?;

    stream
        .play()
        .map_err(|e| format!("failed to start stream: {e}"))?;

    // Record for the specified duration.
    std::thread::sleep(std::time::Duration::from_secs_f32(RECORD_SECONDS));

    done.store(true, Ordering::Relaxed);
    drop(stream);

    let buf = buffer.lock().map_err(|e| format!("lock error: {e}"))?;
    let samples: Vec<f32> = buf.iter().copied().take(total_samples).collect();

    Ok(samples)
}

/// Simple linear downsampling (same algorithm as capture.rs).
fn downsample_linear(input: &[f32], from_rate: u32, to_rate: u32) -> Vec<f32> {
    if from_rate == to_rate || input.is_empty() {
        return input.to_vec();
    }
    let ratio = from_rate as f64 / to_rate as f64;
    let out_len = (input.len() as f64 / ratio).floor() as usize;
    let mut output = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src = i as f64 * ratio;
        let idx = src as usize;
        let frac = src - idx as f64;
        let sample = if idx + 1 < input.len() {
            input[idx] as f64 * (1.0 - frac) + input[idx + 1] as f64 * frac
        } else {
            input[idx] as f64
        };
        output.push(sample as f32);
    }
    output
}

/// Trim leading and trailing silence from audio.
fn trim_silence(samples: &[f32], threshold: f32) -> Vec<f32> {
    let window = 160; // 10ms at 16kHz
    if samples.len() < window {
        return samples.to_vec();
    }

    // Find first non-silent window.
    let mut start = 0;
    for i in (0..samples.len()).step_by(window) {
        let end = (i + window).min(samples.len());
        let rms = rms_energy(&samples[i..end]);
        if rms > threshold {
            start = i.saturating_sub(window); // Keep one window of padding.
            break;
        }
    }

    // Find last non-silent window.
    let mut end = samples.len();
    for i in (0..samples.len()).step_by(window).rev() {
        let chunk_end = (i + window).min(samples.len());
        let rms = rms_energy(&samples[i..chunk_end]);
        if rms > threshold {
            end = (chunk_end + window).min(samples.len()); // Keep one window of padding.
            break;
        }
    }

    if start >= end {
        return samples.to_vec();
    }

    samples[start..end].to_vec()
}

/// RMS energy of a sample slice.
fn rms_energy(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

/// Wait for the user to press Enter.
fn wait_for_enter() {
    let _ = std::io::stdout().flush();
    let mut buf = String::new();
    let _ = std::io::stdin().read_line(&mut buf);
}

/// Returns the default wakeword references directory.
fn wakeword_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".fae").join("wakeword")
    } else {
        PathBuf::from("/tmp/.fae/wakeword")
    }
}
