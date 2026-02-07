//! Microphone audio capture using cpal.
//!
//! Captures audio at the device's native sample rate and downsamples
//! to 16kHz mono for the speech processing pipeline.

use crate::config::AudioConfig;
use crate::error::{Result, SpeechError};
use crate::pipeline::messages::AudioChunk;
use cpal::StreamConfig;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::time::Instant;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info};

/// Audio capture from system microphone via cpal.
///
/// Captures at the device's native sample rate and downsamples to the
/// configured input rate (default 16kHz) for downstream processing.
pub struct CpalCapture {
    device: cpal::Device,
    stream_config: StreamConfig,
    /// The target sample rate for the pipeline (e.g., 16kHz).
    target_sample_rate: u32,
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
            host.input_devices()
                .map_err(|e| SpeechError::Audio(format!("cannot enumerate devices: {e}")))?
                .find(|d| {
                    d.description()
                        .ok()
                        .map(|desc| desc.name() == name)
                        .unwrap_or(false)
                })
                .ok_or_else(|| SpeechError::Audio(format!("input device '{name}' not found")))?
        } else {
            host.default_input_device()
                .ok_or_else(|| SpeechError::Audio("no default input device".into()))?
        };

        let device_name = device
            .description()
            .map(|d| d.name().to_owned())
            .unwrap_or_else(|_| "<unknown>".into());
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
        let tx_clone = tx.clone();

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

                    let chunk = AudioChunk {
                        samples,
                        sample_rate: target_rate,
                        captured_at: Instant::now(),
                    };
                    // Use try_send to avoid blocking the audio thread
                    if tx_clone.try_send(chunk).is_err() {
                        debug!("audio channel full, dropping chunk");
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
