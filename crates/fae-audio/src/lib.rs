//! Portable cpal-backed audio capture/playback for the Fae daemon.
#![forbid(unsafe_code)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig};
use serde::Serialize;

/// Daemon capture target: S18 push-to-talk WAV payloads are 16 kHz mono f32
/// internally and 16-bit PCM WAV on the wire.
pub const TARGET_SAMPLE_RATE: u32 = 16_000;
const CAPTURE_CAP: Duration = Duration::from_secs(30);
const REAP_AFTER: Duration = Duration::from_secs(35);
const WORKER_TICK: Duration = Duration::from_millis(100);

#[derive(Debug, thiserror::Error)]
pub enum AudioError {
    #[error("no input device available")]
    NoInputDevice,
    #[error("no output device available")]
    NoOutputDevice,
    #[error("device configuration failed: {0}")]
    DeviceConfig(String),
    #[error("stream failed: {0}")]
    Stream(String),
    #[error("capture not found")]
    CaptureNotFound,
    #[error("capture state unavailable")]
    CaptureStateUnavailable,
    #[error("bad wav: {0}")]
    BadWav(&'static str),
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct AudioDeviceInfo {
    pub inputs: Vec<String>,
    pub outputs: Vec<String>,
    pub default_input: Option<String>,
    pub default_output: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CapturedAudio {
    pub wav: Vec<u8>,
    pub duration_ms: u64,
    pub sample_rate: u32,
}

type AudioResult<T> = Result<T, AudioError>;

enum AudioRequest {
    Devices(mpsc::Sender<AudioDeviceInfo>),
    CaptureStart(mpsc::Sender<AudioResult<String>>),
    CaptureStop {
        capture_id: String,
        reply: mpsc::Sender<AudioResult<CapturedAudio>>,
    },
    Play {
        wav: Vec<u8>,
        reply: mpsc::Sender<AudioResult<u64>>,
    },
}

struct CaptureSession {
    samples: Arc<Mutex<Vec<f32>>>,
    stream: Option<cpal::Stream>,
    input_rate: u32,
    started: Instant,
    finished_at: Option<Instant>,
}

/// Shared daemon audio manager. Public methods are thread-safe; all cpal
/// streams live on a dedicated worker thread because CoreAudio streams are not
/// `Send` on macOS.
pub struct AudioManager {
    tx: mpsc::Sender<AudioRequest>,
}

impl Default for AudioManager {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioManager {
    #[must_use]
    pub fn new() -> AudioManager {
        Self::new_with_cap(CAPTURE_CAP)
    }

    fn new_with_cap(capture_cap: Duration) -> AudioManager {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let worker = AudioWorker {
                captures: HashMap::new(),
                next_id: AtomicU64::new(1),
                capture_cap,
            };
            worker.run(rx);
        });
        AudioManager { tx }
    }

    pub fn devices(&self) -> AudioDeviceInfo {
        let (reply, rx) = mpsc::channel();
        if self.tx.send(AudioRequest::Devices(reply)).is_err() {
            return AudioDeviceInfo {
                inputs: Vec::new(),
                outputs: Vec::new(),
                default_input: None,
                default_output: None,
            };
        }
        rx.recv().unwrap_or_else(|_| AudioDeviceInfo {
            inputs: Vec::new(),
            outputs: Vec::new(),
            default_input: None,
            default_output: None,
        })
    }

    pub fn capture_start(&self) -> AudioResult<String> {
        let (reply, rx) = mpsc::channel();
        self.tx
            .send(AudioRequest::CaptureStart(reply))
            .map_err(|_| AudioError::CaptureStateUnavailable)?;
        rx.recv().map_err(|_| AudioError::CaptureStateUnavailable)?
    }

    pub fn capture_stop(&self, capture_id: &str) -> AudioResult<CapturedAudio> {
        let (reply, rx) = mpsc::channel();
        self.tx
            .send(AudioRequest::CaptureStop {
                capture_id: capture_id.to_owned(),
                reply,
            })
            .map_err(|_| AudioError::CaptureStateUnavailable)?;
        rx.recv().map_err(|_| AudioError::CaptureStateUnavailable)?
    }

    pub fn play_wav(&self, wav: &[u8]) -> AudioResult<u64> {
        let (reply, rx) = mpsc::channel();
        self.tx
            .send(AudioRequest::Play {
                wav: wav.to_vec(),
                reply,
            })
            .map_err(|_| AudioError::CaptureStateUnavailable)?;
        rx.recv().map_err(|_| AudioError::CaptureStateUnavailable)?
    }
}

struct AudioWorker {
    captures: HashMap<String, CaptureSession>,
    next_id: AtomicU64,
    capture_cap: Duration,
}

impl AudioWorker {
    fn run(mut self, rx: mpsc::Receiver<AudioRequest>) {
        loop {
            self.reap_captures();
            match rx.recv_timeout(WORKER_TICK) {
                Ok(request) => self.handle(request),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
    }

    fn handle(&mut self, request: AudioRequest) {
        match request {
            AudioRequest::Devices(reply) => {
                let _ = reply.send(devices_impl());
            }
            AudioRequest::CaptureStart(reply) => {
                let _ = reply.send(self.capture_start_impl());
            }
            AudioRequest::CaptureStop { capture_id, reply } => {
                let _ = reply.send(self.capture_stop_impl(&capture_id));
            }
            AudioRequest::Play { wav, reply } => {
                let _ = reply.send(play_wav_impl(&wav));
            }
        }
    }

    fn capture_start_impl(&mut self) -> AudioResult<String> {
        let host = cpal::default_host();
        let device = select_input_device(&host)?;
        let supported = device
            .default_input_config()
            .map_err(|error| AudioError::DeviceConfig(error.to_string()))?;
        let input_rate = supported.sample_rate().0;
        let config: StreamConfig = supported.clone().into();
        let channels = usize::from(config.channels);
        let samples = Arc::new(Mutex::new(Vec::<f32>::new()));
        let err_fn = |error| eprintln!("fae-audio: input stream error: {error}");
        let stream = match supported.sample_format() {
            SampleFormat::F32 => {
                let target = Arc::clone(&samples);
                device.build_input_stream(
                    &config,
                    move |data: &[f32], _| append_interleaved_f32(&target, data, channels),
                    err_fn,
                    None,
                )
            }
            SampleFormat::I16 => {
                let target = Arc::clone(&samples);
                device.build_input_stream(
                    &config,
                    move |data: &[i16], _| append_interleaved_i16(&target, data, channels),
                    err_fn,
                    None,
                )
            }
            SampleFormat::U16 => {
                let target = Arc::clone(&samples);
                device.build_input_stream(
                    &config,
                    move |data: &[u16], _| append_interleaved_u16(&target, data, channels),
                    err_fn,
                    None,
                )
            }
            other => {
                return Err(AudioError::DeviceConfig(format!(
                    "unsupported input format {other:?}"
                )))
            }
        }
        .map_err(|error| AudioError::Stream(error.to_string()))?;
        stream
            .play()
            .map_err(|error| AudioError::Stream(error.to_string()))?;
        let id = format!("cap-{}", self.next_id.fetch_add(1, Ordering::Relaxed));
        self.captures.insert(
            id.clone(),
            CaptureSession {
                samples,
                stream: Some(stream),
                input_rate,
                started: Instant::now(),
                finished_at: None,
            },
        );
        Ok(id)
    }

    fn capture_stop_impl(&mut self, capture_id: &str) -> AudioResult<CapturedAudio> {
        let session = self
            .captures
            .remove(capture_id)
            .ok_or(AudioError::CaptureNotFound)?;
        drop(session.stream);
        let raw = session
            .samples
            .lock()
            .map_err(|_| AudioError::CaptureStateUnavailable)?
            .clone();
        let mono = resample_linear(&raw, session.input_rate, TARGET_SAMPLE_RATE);
        let normalized = normalize_capture_gain(&mono);
        let duration_ms = duration_ms(normalized.len(), TARGET_SAMPLE_RATE);
        Ok(CapturedAudio {
            wav: encode_wav_pcm16(&normalized, TARGET_SAMPLE_RATE),
            duration_ms,
            sample_rate: TARGET_SAMPLE_RATE,
        })
    }

    fn reap_captures(&mut self) {
        let now = Instant::now();
        for session in self.captures.values_mut() {
            if session.finished_at.is_none()
                && now.duration_since(session.started) >= self.capture_cap
            {
                session.stream = None;
                session.finished_at = Some(now);
            }
        }
        self.captures.retain(|_, session| {
            session
                .finished_at
                .is_none_or(|finished| now.duration_since(finished) <= REAP_AFTER)
        });
    }
}

fn devices_impl() -> AudioDeviceInfo {
    let host = cpal::default_host();
    let default_input = host
        .default_input_device()
        .and_then(|device| device.name().ok());
    let default_output = host
        .default_output_device()
        .and_then(|device| device.name().ok());
    let inputs = host
        .input_devices()
        .map(|devices| devices.filter_map(|device| device.name().ok()).collect())
        .unwrap_or_default();
    let outputs = host
        .output_devices()
        .map(|devices| devices.filter_map(|device| device.name().ok()).collect())
        .unwrap_or_default();
    AudioDeviceInfo {
        inputs,
        outputs,
        default_input,
        default_output,
    }
}

fn select_input_device(host: &cpal::Host) -> AudioResult<cpal::Device> {
    select_named_device(
        host.input_devices(),
        std::env::var("FAE_AUDIO_INPUT_DEVICE").ok(),
        AudioError::NoInputDevice,
    )?
    .or_else(|| host.default_input_device())
    .ok_or(AudioError::NoInputDevice)
}

fn select_output_device(host: &cpal::Host) -> AudioResult<cpal::Device> {
    select_named_device(
        host.output_devices(),
        std::env::var("FAE_AUDIO_OUTPUT_DEVICE").ok(),
        AudioError::NoOutputDevice,
    )?
    .or_else(|| host.default_output_device())
    .ok_or(AudioError::NoOutputDevice)
}

fn select_named_device<I>(
    devices: Result<I, cpal::DevicesError>,
    requested: Option<String>,
    missing: AudioError,
) -> AudioResult<Option<cpal::Device>>
where
    I: IntoIterator<Item = cpal::Device>,
{
    let Some(requested) = requested.filter(|name| !name.trim().is_empty()) else {
        return Ok(None);
    };
    let requested_lower = requested.to_ascii_lowercase();
    let devices = devices.map_err(|error| AudioError::DeviceConfig(error.to_string()))?;
    for device in devices {
        let name = match device.name() {
            Ok(name) => name,
            Err(_) => continue,
        };
        if name.to_ascii_lowercase().contains(&requested_lower) {
            return Ok(Some(device));
        }
    }
    Err(match missing {
        AudioError::NoInputDevice => {
            AudioError::DeviceConfig(format!("input device matching '{requested}' not found"))
        }
        AudioError::NoOutputDevice => {
            AudioError::DeviceConfig(format!("output device matching '{requested}' not found"))
        }
        other => other,
    })
}

fn play_wav_impl(wav: &[u8]) -> AudioResult<u64> {
    let decoded = decode_wav_mono(wav)?;
    let host = cpal::default_host();
    let device = select_output_device(&host)?;
    let supported = device
        .default_output_config()
        .map_err(|error| AudioError::DeviceConfig(error.to_string()))?;
    let output_rate = supported.sample_rate().0;
    let samples = if decoded.sample_rate == output_rate {
        decoded.samples
    } else {
        resample_linear(&decoded.samples, decoded.sample_rate, output_rate)
    };
    let played_ms = duration_ms(samples.len(), output_rate);
    let config: StreamConfig = supported.clone().into();
    let channels = usize::from(config.channels);
    let index = Arc::new(AtomicU64::new(0));
    let done = Arc::new(std::sync::atomic::AtomicBool::new(samples.is_empty()));
    let samples = Arc::new(samples);
    let err_fn = |error| eprintln!("fae-audio: output stream error: {error}");
    let stream = match supported.sample_format() {
        SampleFormat::F32 => {
            build_output_stream::<f32>(&device, &config, channels, &samples, &index, &done, err_fn)
        }
        SampleFormat::I16 => {
            build_output_stream::<i16>(&device, &config, channels, &samples, &index, &done, err_fn)
        }
        SampleFormat::U16 => {
            build_output_stream::<u16>(&device, &config, channels, &samples, &index, &done, err_fn)
        }
        other => {
            return Err(AudioError::DeviceConfig(format!(
                "unsupported output format {other:?}"
            )))
        }
    }
    .map_err(|error| AudioError::Stream(error.to_string()))?;
    stream
        .play()
        .map_err(|error| AudioError::Stream(error.to_string()))?;
    while !done.load(Ordering::Relaxed) {
        std::thread::sleep(Duration::from_millis(10));
    }
    std::thread::sleep(Duration::from_millis(25));
    drop(stream);
    Ok(played_ms)
}

fn append_interleaved_f32(target: &Arc<Mutex<Vec<f32>>>, data: &[f32], channels: usize) {
    append_interleaved(
        target,
        data.chunks(channels)
            .map(|frame| average_f32(frame.iter().copied())),
    );
}

fn append_interleaved_i16(target: &Arc<Mutex<Vec<f32>>>, data: &[i16], channels: usize) {
    append_interleaved(
        target,
        data.chunks(channels)
            .map(|frame| average_f32(frame.iter().map(|sample| f32::from(*sample) / 32768.0))),
    );
}

fn append_interleaved_u16(target: &Arc<Mutex<Vec<f32>>>, data: &[u16], channels: usize) {
    append_interleaved(
        target,
        data.chunks(channels).map(|frame| {
            average_f32(
                frame
                    .iter()
                    .map(|sample| (f32::from(*sample) - 32768.0) / 32768.0),
            )
        }),
    );
}

fn append_interleaved<I>(target: &Arc<Mutex<Vec<f32>>>, frames: I)
where
    I: Iterator<Item = f32>,
{
    if let Ok(mut samples) = target.lock() {
        samples.extend(frames.map(|sample| sample.clamp(-1.0, 1.0)));
    }
}

fn average_f32<I>(values: I) -> f32
where
    I: IntoIterator<Item = f32>,
{
    let mut sum = 0.0_f32;
    let mut count = 0_u32;
    for value in values {
        sum += value;
        count = count.saturating_add(1);
    }
    if count == 0 {
        0.0
    } else {
        sum / count as f32
    }
}

fn build_output_stream<T>(
    device: &cpal::Device,
    config: &StreamConfig,
    channels: usize,
    samples: &Arc<Vec<f32>>,
    index: &Arc<AtomicU64>,
    done: &Arc<std::sync::atomic::AtomicBool>,
    err_fn: impl FnMut(cpal::StreamError) + Send + 'static,
) -> Result<cpal::Stream, cpal::BuildStreamError>
where
    T: cpal::Sample + cpal::SizedSample + FromF32Sample,
{
    let samples = Arc::clone(samples);
    let index = Arc::clone(index);
    let done = Arc::clone(done);
    device.build_output_stream(
        config,
        move |output: &mut [T], _| {
            for frame in output.chunks_mut(channels) {
                let sample_index = index.fetch_add(1, Ordering::Relaxed) as usize;
                let value = samples.get(sample_index).copied().unwrap_or(0.0);
                if sample_index >= samples.len() {
                    done.store(true, Ordering::Relaxed);
                }
                for out in frame {
                    *out = T::from_f32_sample(value);
                }
            }
        },
        err_fn,
        None,
    )
}

trait FromF32Sample {
    fn from_f32_sample(value: f32) -> Self;
}

impl FromF32Sample for f32 {
    fn from_f32_sample(value: f32) -> Self {
        value.clamp(-1.0, 1.0)
    }
}

impl FromF32Sample for i16 {
    fn from_f32_sample(value: f32) -> Self {
        #[allow(clippy::cast_possible_truncation)]
        let scaled = (value.clamp(-1.0, 1.0) * 32767.0).round() as i16;
        scaled
    }
}

impl FromF32Sample for u16 {
    fn from_f32_sample(value: f32) -> Self {
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let scaled = ((value.clamp(-1.0, 1.0) * 32767.0) + 32768.0).round() as u16;
        scaled
    }
}

#[must_use]
pub fn resample_linear(input: &[f32], from_rate: u32, to_rate: u32) -> Vec<f32> {
    if input.is_empty() || from_rate == 0 || to_rate == 0 {
        return Vec::new();
    }
    if from_rate == to_rate {
        return input.to_vec();
    }
    let out_len_u64 = (input.len() as u64)
        .saturating_mul(u64::from(to_rate))
        .div_ceil(u64::from(from_rate));
    let out_len = usize::try_from(out_len_u64)
        .unwrap_or(usize::MAX)
        .min(usize::MAX / 2);
    let ratio = from_rate as f64 / to_rate as f64;
    let mut output = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src = i as f64 * ratio;
        let left = src.floor() as usize;
        let frac = (src - left as f64) as f32;
        let a = input.get(left).copied().unwrap_or(0.0);
        let b = input.get(left.saturating_add(1)).copied().unwrap_or(a);
        output.push(a.mul_add(1.0 - frac, b * frac));
    }
    output
}

#[must_use]
pub fn encode_wav_pcm16(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let data_len = (samples.len() * 2) as u32;
    let mut wav = Vec::with_capacity(44 + samples.len() * 2);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    for &sample in samples {
        let clamped = sample.clamp(-1.0, 1.0);
        #[allow(clippy::cast_possible_truncation)]
        let value = (clamped * 32768.0).round().clamp(-32768.0, 32767.0) as i16;
        wav.extend_from_slice(&value.to_le_bytes());
    }
    wav
}

struct DecodedWav {
    samples: Vec<f32>,
    sample_rate: u32,
}

fn decode_wav_mono(wav: &[u8]) -> AudioResult<DecodedWav> {
    if wav.len() < 44 || &wav[0..4] != b"RIFF" || &wav[8..12] != b"WAVE" {
        return Err(AudioError::BadWav("missing RIFF/WAVE header"));
    }
    let mut offset = 12_usize;
    let mut fmt: Option<(u16, u16, u32, u16)> = None;
    let mut data: Option<&[u8]> = None;
    while offset.saturating_add(8) <= wav.len() {
        let id = &wav[offset..offset + 4];
        let size = u32::from_le_bytes([
            wav[offset + 4],
            wav[offset + 5],
            wav[offset + 6],
            wav[offset + 7],
        ]) as usize;
        offset = offset.saturating_add(8);
        if offset.saturating_add(size) > wav.len() {
            return Err(AudioError::BadWav("chunk exceeds file length"));
        }
        let chunk = &wav[offset..offset + size];
        if id == b"fmt " {
            if chunk.len() < 16 {
                return Err(AudioError::BadWav("short fmt chunk"));
            }
            let format = u16::from_le_bytes([chunk[0], chunk[1]]);
            let channels = u16::from_le_bytes([chunk[2], chunk[3]]);
            let sample_rate = u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);
            let bits = u16::from_le_bytes([chunk[14], chunk[15]]);
            fmt = Some((format, channels, sample_rate, bits));
        } else if id == b"data" {
            data = Some(chunk);
        }
        offset = offset.saturating_add(size + (size % 2));
    }
    let (format, channels, sample_rate, bits) =
        fmt.ok_or(AudioError::BadWav("missing fmt chunk"))?;
    let data = data.ok_or(AudioError::BadWav("missing data chunk"))?;
    if channels == 0 {
        return Err(AudioError::BadWav("zero channels"));
    }
    match (format, bits) {
        (1, 16) => decode_pcm16(data, usize::from(channels), sample_rate),
        (3, 32) => decode_float32(data, usize::from(channels), sample_rate),
        _ => Err(AudioError::BadWav("unsupported wav format")),
    }
}

fn decode_pcm16(data: &[u8], channels: usize, sample_rate: u32) -> AudioResult<DecodedWav> {
    let frame_bytes = channels.saturating_mul(2);
    if frame_bytes == 0 || data.len() % frame_bytes != 0 {
        return Err(AudioError::BadWav("misaligned pcm data"));
    }
    let mut samples = Vec::with_capacity(data.len() / frame_bytes);
    for frame in data.chunks(frame_bytes) {
        let mut sum = 0.0_f32;
        for chunk in frame.chunks_exact(2) {
            let value = i16::from_le_bytes([chunk[0], chunk[1]]);
            sum += f32::from(value) / 32768.0;
        }
        samples.push(sum / channels as f32);
    }
    Ok(DecodedWav {
        samples,
        sample_rate,
    })
}

fn decode_float32(data: &[u8], channels: usize, sample_rate: u32) -> AudioResult<DecodedWav> {
    let frame_bytes = channels.saturating_mul(4);
    if frame_bytes == 0 || data.len() % frame_bytes != 0 {
        return Err(AudioError::BadWav("misaligned float data"));
    }
    let mut samples = Vec::with_capacity(data.len() / frame_bytes);
    for frame in data.chunks(frame_bytes) {
        let mut sum = 0.0_f32;
        for chunk in frame.chunks_exact(4) {
            sum += f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        }
        samples.push((sum / channels as f32).clamp(-1.0, 1.0));
    }
    Ok(DecodedWav {
        samples,
        sample_rate,
    })
}

fn normalize_capture_gain(input: &[f32]) -> Vec<f32> {
    if input.is_empty() {
        return Vec::new();
    }
    let rms = (input
        .iter()
        .map(|sample| f64::from(*sample) * f64::from(*sample))
        .sum::<f64>()
        / input.len() as f64)
        .sqrt() as f32;
    if rms < 0.001 {
        return input.to_vec();
    }
    let peak = input
        .iter()
        .map(|sample| sample.abs())
        .fold(0.0_f32, f32::max);
    let target_rms = 0.10_f32;
    let rms_gain = (target_rms / rms).clamp(1.0, 12.0);
    let peak_gain = if peak > 0.0 { 0.98 / peak } else { rms_gain };
    let gain = rms_gain.min(peak_gain.max(1.0));
    input
        .iter()
        .map(|sample| (sample * gain).clamp(-1.0, 1.0))
        .collect()
}

fn duration_ms(samples: usize, sample_rate: u32) -> u64 {
    if sample_rate == 0 {
        return 0;
    }
    (samples as u64).saturating_mul(1_000) / u64::from(sample_rate)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wav_encode_round_trip() -> Result<(), AudioError> {
        let samples = [-1.0, -0.25, 0.0, 0.25, 1.0];
        let wav = encode_wav_pcm16(&samples, TARGET_SAMPLE_RATE);
        let decoded = decode_wav_mono(&wav)?;
        assert_eq!(decoded.sample_rate, TARGET_SAMPLE_RATE);
        assert_eq!(decoded.samples.len(), samples.len());
        for (actual, expected) in decoded.samples.iter().zip(samples) {
            assert!((actual - expected).abs() < 0.0001);
        }
        Ok(())
    }

    #[test]
    fn resample_48k_to_16k_preserves_sine_frequency() {
        let input_rate = 48_000_u32;
        let target_rate = 16_000_u32;
        let freq = 440.0_f32;
        let input: Vec<f32> = (0..input_rate)
            .map(|i| ((i as f32 * freq * std::f32::consts::TAU) / input_rate as f32).sin())
            .collect();
        let output = resample_linear(&input, input_rate, target_rate);
        let crossings = output
            .windows(2)
            .filter(|pair| pair[0] <= 0.0 && pair[1] > 0.0)
            .count();
        assert!((i64::try_from(crossings).unwrap_or(0) - 440).abs() <= 1);
    }

    #[test]
    fn capture_cap_reaping_marks_then_removes_finished_sessions() {
        let mut worker = AudioWorker {
            captures: HashMap::new(),
            next_id: AtomicU64::new(1),
            capture_cap: Duration::from_millis(1),
        };
        worker.captures.insert(
            "old".to_owned(),
            CaptureSession {
                samples: Arc::new(Mutex::new(Vec::new())),
                stream: None,
                input_rate: TARGET_SAMPLE_RATE,
                started: Instant::now() - Duration::from_secs(60),
                finished_at: None,
            },
        );
        worker.reap_captures();
        assert!(worker
            .captures
            .get("old")
            .and_then(|session| session.finished_at)
            .is_some());
        if let Some(session) = worker.captures.get_mut("old") {
            session.finished_at = Some(Instant::now() - REAP_AFTER - Duration::from_secs(1));
        }
        worker.reap_captures();
        assert!(worker.captures.is_empty());
    }

    #[test]
    fn capture_gain_lifts_quiet_speech_without_clipping() {
        let quiet: Vec<f32> = (0..16_000)
            .map(|i| ((i as f32 * 440.0 * std::f32::consts::TAU) / 16_000.0).sin() * 0.01)
            .collect();
        let normalized = normalize_capture_gain(&quiet);
        let rms = (normalized
            .iter()
            .map(|sample| f64::from(*sample) * f64::from(*sample))
            .sum::<f64>()
            / normalized.len() as f64)
            .sqrt();
        let peak = normalized
            .iter()
            .map(|sample| sample.abs())
            .fold(0.0_f32, f32::max);
        assert!(rms > 0.07, "rms after gain: {rms}");
        assert!(peak <= 0.98, "peak after gain: {peak}");
    }

    #[test]
    fn capture_gain_leaves_near_silence_alone() {
        let silence = vec![0.0001_f32; 128];
        assert_eq!(normalize_capture_gain(&silence), silence);
    }

    #[test]
    fn bad_wav_is_rejected() {
        assert!(decode_wav_mono(b"not a wav").is_err());
    }
}
