//! Audio playback to system speakers via cpal.
//!
//! This implementation keeps a persistent output stream alive and plays audio
//! from an internal queue so playback can be interrupted (barge-in).

use crate::config::AudioConfig;
use crate::error::{Result, SpeechError};
use cpal::StreamConfig;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::sync::mpsc::UnboundedSender;
use tracing::{error, info};

/// Playback lifecycle events emitted from the audio callback thread.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PlaybackEvent {
    /// The last chunk of the current response finished playing.
    Finished,
    /// Playback was stopped/cleared (interrupted).
    Stopped,
    /// Playback audio level for UI animation.
    Level { rms: f32 },
}

struct SharedState {
    queue: VecDeque<f32>,
    /// When true, the callback will emit `Finished` the first time the queue drains.
    final_pending: bool,
    last_level_emit: Option<Instant>,
}

/// Audio playback to system speakers via cpal.
pub struct CpalPlayback {
    stream_config: StreamConfig,
    shared: Arc<Mutex<SharedState>>,
    // Keep the stream alive for the life of this struct.
    _stream: cpal::Stream,
    event_tx: UnboundedSender<PlaybackEvent>,
}

impl CpalPlayback {
    /// Create a new playback instance.
    ///
    /// # Errors
    ///
    /// Returns an error if no output device is available or the stream cannot be created.
    pub fn new(config: &AudioConfig, event_tx: UnboundedSender<PlaybackEvent>) -> Result<Self> {
        let host = cpal::default_host();

        let device = if let Some(ref name) = config.output_device {
            host.output_devices()
                .map_err(|e| SpeechError::Audio(format!("cannot enumerate devices: {e}")))?
                .find(|d| match d.description() {
                    Ok(desc) => desc.name() == name,
                    Err(_) => false,
                })
                .ok_or_else(|| SpeechError::Audio(format!("output device '{name}' not found")))?
        } else {
            host.default_output_device()
                .ok_or_else(|| SpeechError::Audio("no default output device".into()))?
        };

        let device_name = match device.description() {
            Ok(d) => d.name().to_owned(),
            Err(_) => "<unknown>".into(),
        };
        info!("using output device: {device_name}");

        let stream_config = StreamConfig {
            channels: 1,
            sample_rate: config.output_sample_rate,
            buffer_size: cpal::BufferSize::Default,
        };

        let shared = Arc::new(Mutex::new(SharedState {
            queue: VecDeque::new(),
            final_pending: false,
            last_level_emit: None,
        }));

        let shared_cb = Arc::clone(&shared);
        let event_tx_cb = event_tx.clone();

        let stream = device
            .build_output_stream(
                &stream_config,
                move |data: &mut [f32], _info: &cpal::OutputCallbackInfo| {
                    let mut drained = false;
                    let mut should_finish = false;
                    let mut level: Option<f32> = None;

                    {
                        let Ok(mut st) = shared_cb.lock() else {
                            // If the mutex is poisoned, output silence.
                            for s in data.iter_mut() {
                                *s = 0.0;
                            }
                            return;
                        };

                        for out in data.iter_mut() {
                            match st.queue.pop_front() {
                                Some(v) => *out = v,
                                None => {
                                    *out = 0.0;
                                    drained = true;
                                }
                            }
                        }

                        if drained && st.queue.is_empty() && st.final_pending {
                            st.final_pending = false;
                            should_finish = true;
                        }

                        // Rate limit level updates to avoid spamming the UI.
                        // 50ms is responsive enough for mouth animation.
                        let now = Instant::now();
                        let can_emit = match st.last_level_emit {
                            Some(t0) => {
                                now.duration_since(t0) >= std::time::Duration::from_millis(50)
                            }
                            None => true,
                        };
                        if can_emit && !data.is_empty() {
                            let mut sum = 0.0f32;
                            for s in data.iter() {
                                sum += *s * *s;
                            }
                            let rms = (sum / data.len() as f32).sqrt();
                            st.last_level_emit = Some(now);
                            level = Some(rms);
                        }
                    }

                    if should_finish {
                        let _ = event_tx_cb.send(PlaybackEvent::Finished);
                    }
                    if let Some(rms) = level {
                        let _ = event_tx_cb.send(PlaybackEvent::Level { rms });
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

        Ok(Self {
            stream_config,
            shared,
            _stream: stream,
            event_tx,
        })
    }

    /// Enqueue audio samples for playback.
    ///
    /// If `is_final` is true, `PlaybackEvent::Finished` will be emitted when the queue drains.
    ///
    /// # Errors
    ///
    /// Returns an error if the sample rate doesn't match the configured output rate.
    pub fn enqueue(&mut self, samples: &[f32], sample_rate: u32, is_final: bool) -> Result<()> {
        if sample_rate != self.stream_config.sample_rate {
            return Err(SpeechError::Audio(format!(
                "playback sample rate mismatch: got {sample_rate}Hz, expected {}Hz",
                self.stream_config.sample_rate
            )));
        }

        if samples.is_empty() {
            // End-of-response marker: emit finished immediately so callers can clear state.
            if is_final {
                let _ = self.event_tx.send(PlaybackEvent::Finished);
            }
            return Ok(());
        }

        let Ok(mut st) = self.shared.lock() else {
            return Err(SpeechError::Audio("playback queue lock poisoned".into()));
        };

        st.queue.extend(samples.iter().copied());
        if is_final {
            st.final_pending = true;
        }
        Ok(())
    }

    /// Mark the end of a response.
    ///
    /// If the queue still has audio, sets `final_pending` so `PlaybackEvent::Finished`
    /// fires once the remaining audio actually finishes playing.  If the queue is
    /// already empty, fires `Finished` immediately.
    pub fn mark_end(&mut self) {
        let Ok(mut st) = self.shared.lock() else {
            return;
        };
        if st.queue.is_empty() {
            drop(st);
            let _ = self.event_tx.send(PlaybackEvent::Finished);
        } else {
            st.final_pending = true;
        }
    }

    /// Stop playback and clear any queued audio.
    pub fn stop(&mut self) {
        if let Ok(mut st) = self.shared.lock() {
            st.queue.clear();
            st.final_pending = false;
        }
        let _ = self.event_tx.send(PlaybackEvent::Stopped);
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
