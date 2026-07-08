//! Parakeet ASR — NVIDIA `parakeet-tdt-0.6b-v2` (Int8 ONNX) via `sherpa-onnx`.
//!
//! A [`ProviderAdapter`] for dedicated audio transcription. It honours the same
//! contract as the Qwen3-ASR llama.cpp sidecar: [`ProviderAdapter::stream_chat`]
//! receives a [`ChatRequest`] carrying `audio_wav_base64`, decodes the WAV to
//! mono float samples, runs sherpa-onnx's offline transducer recognizer, and
//! emits the transcript as the completion text. Wired in by the daemon at
//! `build_asr_fallback_engine()` behind `asr.engine = "parakeet"`.
//!
//! The four model artifacts (encoder/decoder/joiner Int8 ONNX + `tokens.txt`)
//! are integrity-gated (size + SHA-256) by `models.lock` (loader
//! `"sherpa-onnx"`) *before* this adapter is constructed — the daemon refuses to
//! build it on a missing/mismatched artifact (fail-closed). This adapter is the
//! executor: a sherpa-onnx failure surfaces as [`EngineError::Inference`],
//! never a silent empty transcript.
//!
//! CPU-bound by design: on Apple Silicon, onnxruntime's CoreML execution
//! provider falls back to CPU for FastConformer-transducer ops
//! (k2-fsa/sherpa-onnx #152), so Parakeet runs on the M-series CPU. Linux can
//! use the CUDA EP via onnxruntime. The decode runs on a blocking task so the
//! CPU-bound transducer never stalls the async runtime.
//!
//! Upgrade path: English-only v2 is the chosen model. When multilingual ASR is
//! needed, `nvidia/parakeet-tdt-0.6b-v3` (25 European languages) is the drop-in
//! successor — same sherpa-onnx transducer config, different artifact set.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use futures_util::stream;
use sherpa_onnx::{OfflineRecognizer, OfflineRecognizerConfig, OfflineTransducerModelConfig};

use crate::provider::{
    AdapterInfo, ChatEvent, ChatRequest, ChatStream, EngineError, ProviderAdapter,
};

/// Default decode threads for the transducer — matches the sherpa-onnx canonical
/// Parakeet example and keeps CPU use modest for a background fallback lane.
const DEFAULT_NUM_THREADS: i32 = 2;

/// Identifier reported via [`AdapterInfo`] (status + audit).
const PARAKEET_MODEL_ID: &str = "nvidia/parakeet-tdt-0.6b-v2 (int8 onnx)";

/// A Parakeet-TDT offline recognizer behind the [`ProviderAdapter`] contract.
///
/// The recognizer is `Send + Sync` (sherpa-onnx declares both). The `Mutex`
/// serializes decode calls so the CPU-bound transducer is never raced on a
/// shared object, and lets a clone of the `Arc` handle be moved into a blocking
/// task without borrowing `self`.
pub struct ParakeetAsrAdapter {
    recognizer: Arc<Mutex<OfflineRecognizer>>,
    model_id: String,
}

impl ParakeetAsrAdapter {
    /// Build from already-verified on-disk artifact paths. Returns
    pub fn new(
        encoder: PathBuf,
        decoder: PathBuf,
        joiner: PathBuf,
        tokens: PathBuf,
    ) -> Result<ParakeetAsrAdapter, EngineError> {
        Self::with_model_id(
            encoder,
            decoder,
            joiner,
            tokens,
            PARAKEET_MODEL_ID.to_owned(),
        )
    }

    /// As [`ParakeetAsrAdapter::new`] with a caller-supplied model id (status).
    pub fn with_model_id(
        encoder: PathBuf,
        decoder: PathBuf,
        joiner: PathBuf,
        tokens: PathBuf,
        model_id: String,
    ) -> Result<ParakeetAsrAdapter, EngineError> {
        let mut config = OfflineRecognizerConfig::default();
        config.model_config.transducer = OfflineTransducerModelConfig {
            encoder: Some(encoder.to_string_lossy().into_owned()),
            decoder: Some(decoder.to_string_lossy().into_owned()),
            joiner: Some(joiner.to_string_lossy().into_owned()),
        };
        config.model_config.tokens = Some(tokens.to_string_lossy().into_owned());
        // The docs.rs canonical Parakeet example sets the model type explicitly
        // so sherpa-onnx picks the nemo-transducer graph path.
        config.model_config.model_type = Some("nemo_transducer".to_owned());
        config.model_config.num_threads = DEFAULT_NUM_THREADS;
        let recognizer = OfflineRecognizer::create(&config).ok_or_else(|| {
            EngineError::Load(format!(
                "sherpa-onnx failed to create the Parakeet recognizer (encoder: {})",
                encoder.display()
            ))
        })?;
        Ok(ParakeetAsrAdapter {
            recognizer: Arc::new(Mutex::new(recognizer)),
            model_id,
        })
    }
}

#[async_trait]
impl ProviderAdapter for ParakeetAsrAdapter {
    fn describe(&self) -> AdapterInfo {
        AdapterInfo {
            backend: "sherpa-onnx-parakeet".to_owned(),
            model_id: self.model_id.clone(),
            // An ASR transducer has no text context window.
            context_window: 0,
        }
    }

    async fn stream_chat(&self, request: ChatRequest) -> Result<ChatStream, EngineError> {
        // Pull the audio clip from the most recent message that carries one —
        // the ASR turn shape is a single user message with `audio_wav_base64`.
        let audio_message = request
            .messages
            .iter()
            .rev()
            .find(|message| message.audio_wav_base64.is_some())
            .ok_or_else(|| {
                EngineError::Inference(
                    "parakeet ASR requires a message with audio_wav_base64".to_owned(),
                )
            })?;
        let wav_bytes = match audio_message.decode_audio()? {
            Some(bytes) => bytes,
            None => {
                return Err(EngineError::Inference(
                    "parakeet ASR: selected audio message had no decodable clip".to_owned(),
                ));
            }
        };
        let (samples, sample_rate) = decode_wav_pcm(&wav_bytes)?;
        if samples.is_empty() {
            return Err(EngineError::Inference(
                "parakeet ASR: decoded WAV has zero samples".to_owned(),
            ));
        }

        // Run the CPU-bound transducer off the async runtime. The recognizer is
        // Send + Sync; cloning the Arc handle lets the blocking task lock +
        // decode without borrowing `self`. The OfflineStream lives entirely
        // inside the closure, so its Send-ness is irrelevant.
        let recognizer = self.recognizer.clone();
        let transcript = tokio::task::spawn_blocking(move || -> Result<String, EngineError> {
            let recognizer = recognizer.lock().map_err(|_| {
                EngineError::Inference("parakeet ASR recognizer lock poisoned".to_owned())
            })?;
            let offline_stream = recognizer.create_stream();
            let sample_rate_i32 = i32::try_from(sample_rate).map_err(|_| {
                EngineError::Inference(format!(
                    "parakeet ASR: sample rate {sample_rate} out of range"
                ))
            })?;
            offline_stream.accept_waveform(sample_rate_i32, &samples);
            recognizer.decode(&offline_stream);
            offline_stream
                .get_result()
                .map(|result| result.text)
                .ok_or_else(|| {
                    EngineError::Inference("sherpa-onnx returned no recognition result".to_owned())
                })
        })
        .await
        .map_err(|join_error| {
            EngineError::Inference(format!("parakeet ASR decode task failed: {join_error}"))
        })??;

        // Emit the full transcript as a single token, then a clean stop. The
        // daemon's `run_turn` aggregates tokens into the `text` field, matching
        // how the Qwen3-ASR sidecar surfaces its result.
        let events: Vec<Result<ChatEvent, EngineError>> = vec![
            Ok(ChatEvent::Token(transcript)),
            Ok(ChatEvent::Done {
                finish_reason: "stop".to_owned(),
            }),
        ];
        Ok(Box::pin(stream::iter(events)))
    }
}

/// Decode a RIFF/WAVE blob into mono `f32` samples in `[-1, 1]` and its sample
/// rate. Supports signed PCM (8/16/24/32-bit) and 32-bit IEEE-float PCM;
/// multi-channel input is downmixed to mono by per-frame channel averaging.
/// sherpa-onnx resamples the returned samples to Parakeet's 16 kHz expectation
/// internally, so the clip's native rate is passed through unchanged.
///
/// This is a focused, allocation-aware parser (no `hound` dependency) so the
/// security-gated audio path has no surprising behaviour. All reads are bounds-
/// checked via `slice::get` — it never panics on a truncated/malformed file.
fn decode_wav_pcm(wav: &[u8]) -> Result<(Vec<f32>, u32), EngineError> {
    if wav.len() < 12 || &wav[0..4] != b"RIFF" || &wav[8..12] != b"WAVE" {
        return Err(EngineError::Inference(
            "parakeet ASR: audio is not a RIFF/WAVE blob".to_owned(),
        ));
    }

    let mut offset = 12_usize;
    let mut format: Option<WavFormat> = None;
    let mut data: &[u8] = &[];
    while offset.saturating_add(8) <= wav.len() {
        let id = &wav[offset..offset + 4];
        let size = read_u32(&wav[offset + 4..offset + 8]) as usize;
        offset += 8;
        let body_end = offset.saturating_add(size).min(wav.len());
        let body = &wav[offset..body_end];
        if id == b"fmt " && body.len() >= 16 {
            format = Some(WavFormat {
                audio_format: read_u16(&body[0..2]),
                num_channels: read_u16(&body[2..4]),
                sample_rate: read_u32(&body[4..8]),
                bits_per_sample: read_u16(&body[14..16]),
            });
        } else if id == b"data" {
            data = body;
        }
        // Chunks are word-aligned: advance past the body + a padding byte when
        // the size is odd.
        offset = body_end.saturating_add(size % 2);
    }

    let format = format.ok_or_else(|| {
        EngineError::Inference("parakeet ASR: WAV missing a fmt chunk".to_owned())
    })?;
    if format.sample_rate == 0 {
        return Err(EngineError::Inference(
            "parakeet ASR: WAV sample rate is zero".to_owned(),
        ));
    }
    if format.num_channels == 0 {
        return Err(EngineError::Inference(
            "parakeet ASR: WAV has zero channels".to_owned(),
        ));
    }

    let samples = pcm_to_mono_f32(data, &format)?;
    Ok((samples, format.sample_rate))
}

struct WavFormat {
    audio_format: u16,
    num_channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
}

/// Convert a raw PCM data block to mono `f32` samples for the given format.
fn pcm_to_mono_f32(data: &[u8], format: &WavFormat) -> Result<Vec<f32>, EngineError> {
    let bytes_per_sample = usize::from(format.bits_per_sample / 8);
    let frame_size = bytes_per_sample
        .checked_mul(usize::from(format.num_channels))
        .ok_or_else(|| {
            EngineError::Inference("parakeet ASR: WAV frame size overflow".to_owned())
        })?;
    if frame_size == 0 {
        return Err(EngineError::Inference(
            "parakeet ASR: WAV frame size is zero".to_owned(),
        ));
    }
    let frame_count = data.len() / frame_size;
    let mut mono = Vec::with_capacity(frame_count);

    let decode_sample = |bytes: &[u8]| -> Result<f32, EngineError> {
        // `bytes` is exactly `bytes_per_sample` long (guaranteed by the slicing
        // below); bounds are checked defensively regardless.
        match (format.audio_format, format.bits_per_sample) {
            (1, 8) => Ok(i16::from(bytes[0]).saturating_sub(128) as f32 / 128.0),
            (1, 16) => Ok(read_i16(bytes) as f32 / 32_768.0),
            (1, 24) => Ok(read_i24(bytes) as f32 / 8_388_608.0),
            (1, 32) => Ok(read_i32(bytes) as f32 / 2_147_483_648.0),
            (3, 32) => Ok(read_f32(bytes)),
            _ => Err(EngineError::Inference(format!(
                "parakeet ASR: unsupported WAV format (audio_format={}, bits={})",
                format.audio_format, format.bits_per_sample
            ))),
        }
    };

    for frame in 0..frame_count {
        let base = frame * frame_size;
        let mut sum = 0.0_f32;
        for channel in 0..usize::from(format.num_channels) {
            let start = base + channel * bytes_per_sample;
            let sample_bytes = data.get(start..start + bytes_per_sample).ok_or_else(|| {
                EngineError::Inference("parakeet ASR: truncated PCM frame".to_owned())
            })?;
            sum += decode_sample(sample_bytes)?;
        }
        mono.push(sum / f32::from(format.num_channels));
    }
    Ok(mono)
}
fn read_u16(bytes: &[u8]) -> u16 {
    u16::from_le_bytes([*bytes.first().unwrap_or(&0), *bytes.get(1).unwrap_or(&0)])
}

fn read_i16(bytes: &[u8]) -> i16 {
    i16::from_le_bytes([*bytes.first().unwrap_or(&0), *bytes.get(1).unwrap_or(&0)])
}

fn read_u32(bytes: &[u8]) -> u32 {
    u32::from_le_bytes([
        *bytes.first().unwrap_or(&0),
        *bytes.get(1).unwrap_or(&0),
        *bytes.get(2).unwrap_or(&0),
        *bytes.get(3).unwrap_or(&0),
    ])
}

fn read_i32(bytes: &[u8]) -> i32 {
    i32::from_le_bytes([
        *bytes.first().unwrap_or(&0),
        *bytes.get(1).unwrap_or(&0),
        *bytes.get(2).unwrap_or(&0),
        *bytes.get(3).unwrap_or(&0),
    ])
}

fn read_f32(bytes: &[u8]) -> f32 {
    f32::from_le_bytes([
        *bytes.first().unwrap_or(&0),
        *bytes.get(1).unwrap_or(&0),
        *bytes.get(2).unwrap_or(&0),
        *bytes.get(3).unwrap_or(&0),
    ])
}

/// Read a little-endian 24-bit signed integer (3 bytes): bytes 0–1 are the low
/// 16 bits, byte 2 is the sign-extended high byte.
fn read_i24(bytes: &[u8]) -> i32 {
    let low = read_u16(bytes);
    let high = (*bytes.get(2).unwrap_or(&0)) as i8;
    (i32::from(high) << 16) | i32::from(low)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tts::encode_wav_pcm16;

    #[test]
    fn decodes_pcm16_mono_wav() {
        // A 1 kHz-ish waveform; values chosen to exercise clamping + scaling.
        let samples: Vec<f32> = (0..4800)
            .map(|i| ((i as f32) / 4800.0) * 2.0 - 1.0)
            .collect();
        let wav = encode_wav_pcm16(&samples, 16_000);
        let (decoded, rate) = decode_wav_pcm(&wav).expect("decode pcm16 mono");
        assert_eq!(rate, 16_000);
        assert_eq!(decoded.len(), samples.len());
        for (i, want) in samples.iter().enumerate() {
            let got = decoded[i];
            assert!(
                (got - want).abs() < 1.0 / 32_768.0 + 1e-6,
                "sample {i}: got {got}, want {want}"
            );
        }
    }

    #[test]
    fn downmixes_stereo_to_mono() {
        // Hand-build a 2-channel PCM16 WAV: left = +0.25, right = -0.25 each
        // frame → mono average must be ~0.0.
        let frame_count = 100usize;
        let mut data = Vec::with_capacity(44 + frame_count * 4);
        let body_len = (frame_count * 4) as u32;
        data.extend_from_slice(b"RIFF");
        data.extend_from_slice(&(36 + body_len).to_le_bytes());
        data.extend_from_slice(b"WAVE");
        data.extend_from_slice(b"fmt ");
        data.extend_from_slice(&16_u32.to_le_bytes());
        data.extend_from_slice(&1_u16.to_le_bytes()); // PCM
        data.extend_from_slice(&2_u16.to_le_bytes()); // stereo
        data.extend_from_slice(&16_000_u32.to_le_bytes());
        data.extend_from_slice(&(16_000_u32 * 4).to_le_bytes()); // byte rate
        data.extend_from_slice(&4_u16.to_le_bytes()); // block align
        data.extend_from_slice(&16_u16.to_le_bytes()); // bits
        data.extend_from_slice(b"data");
        data.extend_from_slice(&body_len.to_le_bytes());
        let left = (0.25_f32 * 32_768.0) as i16;
        let right = (-0.25_f32 * 32_768.0) as i16;
        for _ in 0..frame_count {
            data.extend_from_slice(&left.to_le_bytes());
            data.extend_from_slice(&right.to_le_bytes());
        }
        let (mono, rate) = decode_wav_pcm(&data).expect("decode stereo");
        assert_eq!(rate, 16_000);
        assert_eq!(mono.len(), frame_count);
        for value in mono {
            assert!(value.abs() < 1e-2, "expected ~0.0 mono, got {value}");
        }
    }

    #[test]
    fn rejects_non_wav() {
        assert!(decode_wav_pcm(b"not a wav file at all").is_err());
        assert!(decode_wav_pcm(b"RIFF\x00\x00\x00\x00XXXX").is_err());
    }

    #[test]
    fn rejects_missing_fmt_chunk() {
        // RIFF/WAVE with only a data chunk — no fmt.
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(4_u32 + 8 + 4).to_le_bytes());
        wav.extend_from_slice(b"WAVE");
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&4_u32.to_le_bytes());
        wav.extend_from_slice(&[0, 0, 0, 0]);
        assert!(decode_wav_pcm(&wav).is_err());
    }

    #[test]
    fn adapter_constants_and_identity_shape() {
        // Without real weights we cannot exercise stream_chat/describe live;
        // pin the constants describe() + new() use so a rename is caught.
        assert_eq!(PARAKEET_MODEL_ID, "nvidia/parakeet-tdt-0.6b-v2 (int8 onnx)");
        assert_eq!(DEFAULT_NUM_THREADS, 2);
    }

    #[test]
    fn new_fails_loud_on_missing_models() {
        // No real artifacts → sherpa-onnx must refuse (fail-closed), surfacing a
        // Load error rather than panicking. This is the executor-side mirror of
        // the daemon's models.lock gate.
        let result = ParakeetAsrAdapter::new(
            PathBuf::from("/nonexistent/encoder.int8.onnx"),
            PathBuf::from("/nonexistent/decoder.int8.onnx"),
            PathBuf::from("/nonexistent/joiner.int8.onnx"),
            PathBuf::from("/nonexistent/tokens.txt"),
        );
        let err = result.err();
        assert!(
            matches!(err, Some(EngineError::Load(_))),
            "expected EngineError::Load, got {err:?}"
        );
    }
    /// Live end-to-end transcription. Ignored by default (needs the ~661 MB
    /// model set). Run with the four artifacts + a WAV under a models dir:
    ///   cargo test -p fae-engine --features <none> parakeet_asr::tests::live_transcribes_real_clip -- --ignored --nocapture
    ///   FAE_PARAKEET_MODELS_DIR=/path/to/models FAE_PARAKEET_TEST_WAV=/path/to/0.wav
    #[tokio::test]
    #[ignore]
    async fn live_transcribes_real_clip() {
        use crate::provider::{ChatMessage, ChatRequest, Role};
        use base64::Engine as _;
        use futures_util::StreamExt;

        let dir = std::env::var_os("FAE_PARAKEET_MODELS_DIR")
            .expect("FAE_PARAKEET_MODELS_DIR must point at the four Parakeet artifacts");
        let wav_path = std::env::var_os("FAE_PARAKEET_TEST_WAV")
            .expect("FAE_PARAKEET_TEST_WAV must point at a 16 kHz mono WAV clip");
        let dir = PathBuf::from(dir);
        let adapter = ParakeetAsrAdapter::new(
            dir.join("encoder.int8.onnx"),
            dir.join("decoder.int8.onnx"),
            dir.join("joiner.int8.onnx"),
            dir.join("tokens.txt"),
        )
        .expect("construct recognizer");
        let wav = std::fs::read(&wav_path).expect("read test wav");
        let encoded = base64::engine::general_purpose::STANDARD.encode(&wav);
        let request = ChatRequest {
            system: None,
            messages: vec![ChatMessage {
                role: Role::User,
                content: String::new(),
                audio_wav_base64: Some(encoded),
            }],
            tools: Vec::new(),
            max_tokens: 128,
        };
        let mut stream = adapter.stream_chat(request).await.expect("stream_chat");
        let mut transcript = String::new();
        while let Some(event) = stream.next().await {
            if let Ok(ChatEvent::Token(text)) = event {
                transcript.push_str(&text);
            }
        }
        eprintln!("[parakeet-live] transcript = {transcript:?}");
        assert!(
            !transcript.trim().is_empty(),
            "transcript must be non-empty"
        );
    }
}
