//! Voice cloning helpers for the GUI.
//!
//! Supports importing an audio file (mp3/mp4/wav) and saving a reference WAV
//! that can be used by Chatterbox TTS for voice cloning.

use crate::error::{Result, SpeechError};
use std::fs;
use std::path::{Path, PathBuf};

const TARGET_SR: u32 = 24_000;

#[derive(Debug, Clone)]
pub struct ImportedVoice {
    pub wav_path: PathBuf,
    pub sample_rate: u32,
    pub seconds: f32,
}

#[derive(Debug, Clone)]
pub struct ImportOptions {
    /// Maximum duration to keep from the audio (seconds).
    pub max_seconds: f32,
}

impl Default for ImportOptions {
    fn default() -> Self {
        Self { max_seconds: 30.0 }
    }
}

/// Import an audio file and write a mono WAV into `<cache_dir>/voices/`.
pub fn import_audio_to_voice_wav(
    cache_dir: &Path,
    input_path: &Path,
    voice_name: &str,
    opts: ImportOptions,
) -> Result<ImportedVoice> {
    let voice_name = sanitize_name(voice_name);
    if voice_name.is_empty() {
        return Err(SpeechError::Tts("voice name is empty".into()));
    }

    let (mut samples, sr) = decode_audio_to_mono_f32(input_path)?;
    if samples.is_empty() {
        return Err(SpeechError::Tts("decoded audio is empty".into()));
    }

    let max_samples = (opts.max_seconds.max(1.0) * sr as f32) as usize;
    if samples.len() > max_samples {
        samples.truncate(max_samples);
    }

    let seconds = samples.len() as f32 / sr as f32;
    let samples_24k = if sr == TARGET_SR {
        samples
    } else {
        resample_linear_mono(&samples, sr, TARGET_SR)
    };

    let out_dir = cache_dir.join("voices");
    fs::create_dir_all(&out_dir)?;
    let out_path = out_dir.join(format!("{voice_name}.wav"));
    write_wav_f32_mono(&out_path, &samples_24k, TARGET_SR)?;

    Ok(ImportedVoice {
        wav_path: out_path,
        sample_rate: TARGET_SR,
        seconds,
    })
}

/// Record from the default microphone for `seconds` and write a mono WAV into `<cache_dir>/voices/`.
///
/// This is best-effort and currently assumes the default input stream supports f32 samples.
pub fn record_voice_wav(cache_dir: &Path, voice_name: &str, seconds: f32) -> Result<ImportedVoice> {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

    let voice_name = sanitize_name(voice_name);
    if voice_name.is_empty() {
        return Err(SpeechError::Tts("voice name is empty".into()));
    }
    if !(seconds.is_finite() && seconds > 0.5) {
        return Err(SpeechError::Tts("record duration must be > 0.5s".into()));
    }

    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| SpeechError::Audio("no default input device".into()))?;

    let supported = device
        .default_input_config()
        .map_err(|e| SpeechError::Audio(format!("no default input config: {e}")))?;

    let native_rate = supported.sample_rate();
    let channels = supported.channels();

    // Note: We only handle f32 here (matches current pipeline capture).
    if supported.sample_format() != cpal::SampleFormat::F32 {
        return Err(SpeechError::Audio(format!(
            "voice recording requires f32 input (got {:?})",
            supported.sample_format()
        )));
    }

    let cfg: cpal::StreamConfig = supported.into();

    let buf: std::sync::Arc<std::sync::Mutex<Vec<f32>>> =
        std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let buf_cb = std::sync::Arc::clone(&buf);

    let stream = device
        .build_input_stream(
            &cfg,
            move |data: &[f32], _| {
                // Downmix to mono by averaging channels.
                let mut out = Vec::with_capacity(data.len() / channels as usize + 1);
                if channels > 1 {
                    let ch = channels as usize;
                    for frame in data.chunks_exact(ch) {
                        let mut sum = 0.0f32;
                        for s in frame {
                            sum += *s;
                        }
                        out.push(sum / ch as f32);
                    }
                } else {
                    out.extend_from_slice(data);
                }

                if let Ok(mut guard) = buf_cb.lock() {
                    guard.extend(out);
                }
            },
            move |err| {
                tracing::error!("voice record stream error: {err}");
            },
            None,
        )
        .map_err(|e| SpeechError::Audio(format!("failed to build record stream: {e}")))?;

    stream
        .play()
        .map_err(|e| SpeechError::Audio(format!("failed to start record stream: {e}")))?;

    std::thread::sleep(std::time::Duration::from_secs_f32(seconds));
    drop(stream);

    let mono_native = buf
        .lock()
        .map_err(|_| SpeechError::Audio("record buffer poisoned".into()))?
        .clone();

    if mono_native.is_empty() {
        return Err(SpeechError::Audio("recorded no audio".into()));
    }

    let seconds = mono_native.len() as f32 / native_rate as f32;
    let samples_24k = if native_rate == TARGET_SR {
        mono_native
    } else {
        resample_linear_mono(&mono_native, native_rate, TARGET_SR)
    };

    let out_dir = cache_dir.join("voices");
    fs::create_dir_all(&out_dir)?;
    let out_path = out_dir.join(format!("{voice_name}.wav"));
    write_wav_f32_mono(&out_path, &samples_24k, TARGET_SR)?;

    Ok(ImportedVoice {
        wav_path: out_path,
        sample_rate: TARGET_SR,
        seconds,
    })
}

fn decode_audio_to_mono_f32(path: &Path) -> Result<(Vec<f32>, u32)> {
    use symphonia::core::audio::SampleBuffer;
    use symphonia::core::codecs::DecoderOptions;
    use symphonia::core::errors::Error as SymphError;
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    let file = std::fs::File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| SpeechError::Tts(format!("failed to probe audio: {e}")))?;

    let mut format = probed.format;
    let track = format
        .default_track()
        .ok_or_else(|| SpeechError::Tts("no default audio track".into()))?;
    let track_id = track.id;
    let codec_params = track.codec_params.clone();

    let sr = codec_params
        .sample_rate
        .ok_or_else(|| SpeechError::Tts("unknown sample rate".into()))?;

    let mut decoder = symphonia::default::get_codecs()
        .make(&codec_params, &DecoderOptions::default())
        .map_err(|e| SpeechError::Tts(format!("failed to create decoder: {e}")))?;

    let mut out: Vec<f32> = Vec::new();
    let mut sample_buf: Option<SampleBuffer<f32>> = None;

    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(SymphError::IoError(e)) => {
                if e.kind() == std::io::ErrorKind::UnexpectedEof {
                    break;
                }
                return Err(SpeechError::Tts(format!("audio read error: {e}")));
            }
            Err(e) => return Err(SpeechError::Tts(format!("audio read error: {e}"))),
        };

        if packet.track_id() != track_id {
            continue;
        }

        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(SymphError::DecodeError(_)) => continue,
            Err(e) => return Err(SpeechError::Tts(format!("audio decode error: {e}"))),
        };

        let spec = *decoded.spec();
        let channels = spec.channels.count();
        let frames = decoded.frames() as u64;

        let frames_usize = match usize::try_from(frames) {
            Ok(v) => v,
            Err(_) => usize::MAX,
        };
        let required = frames_usize.saturating_mul(channels);
        let needs_new = match sample_buf.as_ref() {
            Some(b) => b.capacity() < required,
            None => true,
        };

        if needs_new {
            sample_buf = Some(SampleBuffer::<f32>::new(frames, spec));
        } else if let Some(b) = sample_buf.as_mut() {
            b.clear();
        }

        if let Some(b) = sample_buf.as_mut() {
            b.copy_interleaved_ref(decoded);
        }

        let data = match sample_buf.as_ref() {
            Some(b) => b.samples(),
            None => &[],
        };
        if channels <= 1 {
            out.extend_from_slice(data);
        } else {
            for frame in data.chunks_exact(channels) {
                let mut sum = 0.0f32;
                for s in frame {
                    sum += *s;
                }
                out.push(sum / channels as f32);
            }
        }
    }

    Ok((out, sr))
}

fn write_wav_f32_mono(path: &Path, samples: &[f32], sample_rate: u32) -> Result<()> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec)
        .map_err(|e| SpeechError::Tts(format!("failed to create wav writer: {e}")))?;

    for &s in samples {
        let clamped = s.clamp(-1.0, 1.0);
        let v = (clamped * i16::MAX as f32).round() as i16;
        writer
            .write_sample(v)
            .map_err(|e| SpeechError::Tts(format!("failed to write wav sample: {e}")))?;
    }
    writer
        .finalize()
        .map_err(|e| SpeechError::Tts(format!("failed to finalize wav: {e}")))?;
    Ok(())
}

fn resample_linear_mono(input: &[f32], from_sr: u32, to_sr: u32) -> Vec<f32> {
    if input.is_empty() || from_sr == to_sr {
        return input.to_vec();
    }

    let ratio = to_sr as f64 / from_sr as f64;
    let out_len = ((input.len() as f64) * ratio).round() as usize;
    let mut out = Vec::with_capacity(out_len);

    for i in 0..out_len {
        let src_pos = (i as f64) / ratio;
        let src_i0 = src_pos.floor() as isize;
        let src_i1 = src_i0 + 1;
        let t = (src_pos - src_i0 as f64) as f32;

        let s0 = sample_clamped(input, src_i0);
        let s1 = sample_clamped(input, src_i1);
        out.push(s0 * (1.0 - t) + s1 * t);
    }

    out
}

fn sample_clamped(input: &[f32], idx: isize) -> f32 {
    if idx <= 0 {
        return input[0];
    }
    let idx = idx as usize;
    if idx >= input.len() {
        return input[input.len() - 1];
    }
    input[idx]
}

fn sanitize_name(name: &str) -> String {
    let mut out = String::new();
    for c in name.trim().chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if matches!(c, ' ' | '-' | '_') && !out.ends_with('_') {
            out.push('_');
        }
    }
    out.trim_matches('_').to_owned()
}
