//! Audio playback to system speakers via cpal.

use crate::config::AudioConfig;
use crate::error::{Result, SpeechError};
use cpal::StreamConfig;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::{Arc, Mutex};
use tracing::{error, info};

/// Audio playback to system speakers via cpal.
pub struct CpalPlayback {
    device: cpal::Device,
    stream_config: StreamConfig,
}

impl CpalPlayback {
    /// Create a new playback instance.
    ///
    /// # Errors
    ///
    /// Returns an error if no output device is available.
    pub fn new(config: &AudioConfig) -> Result<Self> {
        let host = cpal::default_host();

        let device = if let Some(ref name) = config.output_device {
            host.output_devices()
                .map_err(|e| SpeechError::Audio(format!("cannot enumerate devices: {e}")))?
                .find(|d| {
                    d.description()
                        .ok()
                        .map(|desc| desc.name() == name)
                        .unwrap_or(false)
                })
                .ok_or_else(|| SpeechError::Audio(format!("output device '{name}' not found")))?
        } else {
            host.default_output_device()
                .ok_or_else(|| SpeechError::Audio("no default output device".into()))?
        };

        let device_name = device
            .description()
            .map(|d| d.name().to_owned())
            .unwrap_or_else(|_| "<unknown>".into());
        info!("using output device: {device_name}");

        let stream_config = StreamConfig {
            channels: 1,
            sample_rate: config.output_sample_rate,
            buffer_size: cpal::BufferSize::Default,
        };

        Ok(Self {
            device,
            stream_config,
        })
    }

    /// Play audio samples through the output device.
    ///
    /// This method blocks until all samples have been played.
    ///
    /// # Errors
    ///
    /// Returns an error if the audio stream cannot be created or played.
    pub fn play(&mut self, samples: &[f32], _sample_rate: u32) -> Result<()> {
        let buffer = Arc::new(Mutex::new(PlaybackBuffer {
            samples: samples.to_vec(),
            position: 0,
            finished: false,
        }));

        let buffer_clone = Arc::clone(&buffer);

        let stream = self
            .device
            .build_output_stream(
                &self.stream_config,
                move |data: &mut [f32], _info: &cpal::OutputCallbackInfo| {
                    let mut buf = match buffer_clone.lock() {
                        Ok(b) => b,
                        Err(_) => return,
                    };

                    for sample in data.iter_mut() {
                        if buf.position < buf.samples.len() {
                            *sample = buf.samples[buf.position];
                            buf.position += 1;
                        } else {
                            *sample = 0.0;
                            buf.finished = true;
                        }
                    }
                },
                move |err| {
                    error!("audio output stream error: {err}");
                },
                None,
            )
            .map_err(|e| SpeechError::Audio(format!("failed to build output stream: {e}")))?;

        stream
            .play()
            .map_err(|e| SpeechError::Audio(format!("failed to start output stream: {e}")))?;

        // Wait for playback to finish
        loop {
            std::thread::sleep(std::time::Duration::from_millis(10));
            let buf = buffer
                .lock()
                .map_err(|e| SpeechError::Audio(format!("playback buffer lock poisoned: {e}")))?;
            if buf.finished {
                break;
            }
        }

        drop(stream);
        Ok(())
    }

    /// List available output devices.
    ///
    /// # Errors
    ///
    /// Returns an error if devices cannot be enumerated.
    pub fn list_output_devices() -> Result<Vec<String>> {
        let host = cpal::default_host();
        let devices = host
            .output_devices()
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

/// Internal buffer for tracking playback progress.
struct PlaybackBuffer {
    samples: Vec<f32>,
    position: usize,
    finished: bool,
}
