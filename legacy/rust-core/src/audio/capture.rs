//! Microphone audio capture using cpal.
//!
//! Captures audio at the device's native sample rate and downsamples
//! to 16kHz mono for the speech processing pipeline.

use crate::config::AudioConfig;
use crate::error::{Result, SpeechError};
use crate::pipeline::messages::AudioChunk;
use cpal::StreamConfig;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Instant;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};

/// Audio capture from system microphone via cpal.
///
/// Captures at the device's native sample rate and downsamples to the
/// configured input rate (default 16kHz) for downstream processing.
pub struct CpalCapture {
    device: cpal::Device,
    stream_config: StreamConfig,
    /// The target sample rate for the pipeline (e.g., 16kHz).
    target_sample_rate: u32,
    /// Target chunk size at the pipeline sample rate (in frames/samples).
    target_chunk_frames: usize,
}

impl CpalCapture {
    /// Create a new capture instance.
    ///
    /// Uses the device's default configuration for maximum compatibility,
    /// then downsamples to the target rate in software.
    ///
    /// # Errors
    ///
    /// Returns an error if no input device is available.
    pub fn new(config: &AudioConfig) -> Result<Self> {
        let host = cpal::default_host();

        let device = if let Some(ref name) = config.input_device {
            let requested = host
                .input_devices()
                .map_err(|e| SpeechError::Audio(format!("cannot enumerate devices: {e}")))?
                .find(|d| match d.description() {
                    Ok(desc) => desc.name() == name,
                    Err(_) => false,
                });

            match requested {
                Some(device) => device,
                None => {
                    warn!(
                        "configured input device '{}' not found, falling back to default input device",
                        name
                    );
                    host.default_input_device()
                        .ok_or_else(|| SpeechError::Audio("no default input device".into()))?
                }
            }
        } else {
            host.default_input_device()
                .ok_or_else(|| SpeechError::Audio("no default input device".into()))?
        };

        let device_name = match device.description() {
            Ok(d) => d.name().to_owned(),
            Err(_) => "<unknown>".into(),
        };
        info!("using input device: {device_name}");

        // Use the device's default config for best compatibility
        let default_config = device
            .default_input_config()
            .map_err(|e| SpeechError::Audio(format!("no default input config: {e}")))?;

        let native_rate = default_config.sample_rate();
        let native_channels = default_config.channels();

        let stream_config = StreamConfig {
            channels: native_channels,
            sample_rate: native_rate,
            buffer_size: cpal::BufferSize::Default,
        };

        info!(
            "native input config: {}Hz, {} channels",
            native_rate, native_channels
        );

        if native_rate != config.input_sample_rate {
            info!(
                "will downsample from {}Hz to {}Hz",
                native_rate, config.input_sample_rate
            );
        }

        Ok(Self {
            device,
            stream_config,
            target_sample_rate: config.input_sample_rate,
            target_chunk_frames: config.buffer_size as usize,
        })
    }

    /// Run the capture loop, sending audio chunks to the provided channel.
    ///
    /// Blocks until the cancellation token is triggered.
    ///
    /// # Errors
    ///
    /// Returns an error if the audio stream cannot be created.
    pub async fn run(&self, tx: mpsc::Sender<AudioChunk>, cancel: CancellationToken) -> Result<()> {
        let native_rate = self.stream_config.sample_rate;
        let native_channels = self.stream_config.channels;
        let target_rate = self.target_sample_rate;
        let chunk_len = self.target_chunk_frames.max(1);
        let tx_clone = tx.clone();
        let mut pending: VecDeque<f32> = VecDeque::with_capacity(chunk_len.saturating_mul(4));

        // Rate-limited reporting from the audio callback thread.
        let dropped_full = AtomicU64::new(0);
        let last_report_ms = AtomicU64::new(0);
        let tx_closed = AtomicBool::new(false);

        let stream = self
            .device
            .build_input_stream(
                &self.stream_config,
                move |data: &[f32], _info: &cpal::InputCallbackInfo| {
                    // Convert to mono if needed
                    let mono = if native_channels > 1 {
                        to_mono(data, native_channels)
                    } else {
                        data.to_vec()
                    };

                    // Downsample if native rate differs from target
                    let samples = if native_rate != target_rate {
                        downsample(&mono, native_rate, target_rate)
                    } else {
                        mono
                    };

                    pending.extend(samples.into_iter());

                    // Emit fixed-size chunks to make downstream timing consistent.
                    while pending.len() >= chunk_len {
                        if tx_closed.load(Ordering::Relaxed) {
                            // Downstream pipeline has stopped; discard buffered samples.
                            pending.clear();
                            break;
                        }

                        let mut out = Vec::with_capacity(chunk_len);
                        for _ in 0..chunk_len {
                            if let Some(s) = pending.pop_front() {
                                out.push(s);
                            }
                        }

                        let chunk = AudioChunk {
                            samples: out,
                            sample_rate: target_rate,
                            captured_at: Instant::now(),
                        };
                        // Use try_send to avoid blocking the audio thread
                        match tx_clone.try_send(chunk) {
                            Ok(()) => {}
                            Err(mpsc::error::TrySendError::Full(_chunk)) => {
                                dropped_full.fetch_add(1, Ordering::Relaxed);
                            }
                            Err(mpsc::error::TrySendError::Closed(_chunk)) => {
                                tx_closed.store(true, Ordering::Relaxed);
                            }
                        }

                        // Rate-limit logs to avoid spamming.
                        let now_ms = SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .map(|d| d.as_millis() as u64)
                            .unwrap_or(0);
                        let last = last_report_ms.load(Ordering::Relaxed);
                        if now_ms.saturating_sub(last) >= 2_000
                            && last_report_ms
                                .compare_exchange(
                                    last,
                                    now_ms,
                                    Ordering::Relaxed,
                                    Ordering::Relaxed,
                                )
                                .is_ok()
                        {
                            let n = dropped_full.swap(0, Ordering::Relaxed);
                            if tx_closed.load(Ordering::Relaxed) {
                                debug!("audio channel closed (pipeline stopped)");
                            } else if n > 0 {
                                debug!("audio channel full, dropped {n} chunks (last 2s)");
                            }
                        }
                    }
                },
                move |err| {
                    error!("audio input stream error: {err}");
                },
                None,
            )
            .map_err(|e| SpeechError::Audio(format!("failed to build input stream: {e}")))?;

        stream
            .play()
            .map_err(|e| SpeechError::Audio(format!("failed to start input stream: {e}")))?;

        info!(
            "audio capture started: native {}Hz -> target {}Hz",
            native_rate, target_rate
        );

        // Hold the stream alive until cancelled
        cancel.cancelled().await;

        drop(stream);
        info!("audio capture stopped");
        Ok(())
    }

    /// List available input devices.
    ///
    /// # Errors
    ///
    /// Returns an error if devices cannot be enumerated.
    pub fn list_input_devices() -> Result<Vec<String>> {
        let host = cpal::default_host();
        let devices = host
            .input_devices()
            .map_err(|e| SpeechError::Audio(format!("cannot enumerate devices: {e}")))?;

        let mut names = Vec::new();
        for device in devices {
            if let Ok(desc) = device.description() {
                names.push(desc.name().to_owned());
            }
        }
        Ok(names)
    }
}

/// Convert interleaved multi-channel audio to mono by averaging channels.
fn to_mono(data: &[f32], channels: u16) -> Vec<f32> {
    let ch = channels as usize;
    data.chunks_exact(ch)
        .map(|frame| frame.iter().sum::<f32>() / ch as f32)
        .collect()
}

/// Simple linear-interpolation downsampler.
///
/// Converts audio from `src_rate` to `dst_rate`. For speech processing
/// (48kHz → 16kHz) this is sufficient quality — no anti-alias filter needed
/// since human speech energy is below 8kHz.
fn downsample(samples: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
    if src_rate == dst_rate || samples.is_empty() {
        return samples.to_vec();
    }

    let ratio = src_rate as f64 / dst_rate as f64;
    let out_len = (samples.len() as f64 / ratio) as usize;
    let mut output = Vec::with_capacity(out_len);

    for i in 0..out_len {
        let src_pos = i as f64 * ratio;
        let idx = src_pos as usize;
        let frac = src_pos - idx as f64;

        let sample = if idx + 1 < samples.len() {
            samples[idx] as f64 * (1.0 - frac) + samples[idx + 1] as f64 * frac
        } else {
            samples[idx.min(samples.len() - 1)] as f64
        };

        output.push(sample as f32);
    }

    output
}
