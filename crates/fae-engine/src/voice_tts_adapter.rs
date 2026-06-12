//! `VoiceTtsAdapter` — Kokoro TTS via the pure-Rust `voice-tts` crate (S19).
//!
//! `voice-tts` runs Kokoro-82M on mlx-rs (Apple Silicon); `voice-g2p` (pure
//! Rust, portable) handles text → phonemes. MLX values are not `Send`, so the
//! model lives on a dedicated worker thread that owns it for the process
//! lifetime; requests arrive over a channel and answers return via oneshot.
//! The model loads lazily on the first request — daemon startup stays fast.
//!
//! Cross-platform note: this adapter is compiled on macOS only (mlx-rs).
//! Other targets get [`crate::MockTtsAdapter`] until the candle port lands —
//! the protocol surface is identical.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc;

use async_trait::async_trait;
use tokio::sync::oneshot;

use crate::provider::{AdapterInfo, EngineError};
use crate::tts::{encode_wav_pcm16, TtsAdapter, TtsAudio};

/// Kokoro generates 24 kHz audio.
const KOKORO_SAMPLE_RATE: u32 = 24_000;

/// Voice used when the requested voice cannot be loaded from the local voices
/// directory or the HuggingFace repo. Synthesis must degrade to a different
/// voice, never to silence.
const FALLBACK_VOICE: &str = "af_heart";

enum Job {
    Synthesize {
        text: String,
        voice: String,
        speed: f32,
        reply: oneshot::Sender<Result<TtsAudio, EngineError>>,
    },
}

/// A Kokoro model behind the [`TtsAdapter`] contract.
pub struct VoiceTtsAdapter {
    jobs: mpsc::Sender<Job>,
    info: AdapterInfo,
}

impl VoiceTtsAdapter {
    /// Spawn the worker thread. `model_repo` is a HuggingFace id (the same
    /// `prince-canuma/Kokoro-82M` the Swift lane uses, so the cache is warm).
    /// `local_voices_dir`, when set, is checked for `{voice}.safetensors`
    /// before the HF repo — custom voices (Fae's own) live there. Weights load
    /// on the first synthesize call, not here.
    pub fn spawn(
        model_repo: impl Into<String>,
        local_voices_dir: Option<PathBuf>,
    ) -> Result<VoiceTtsAdapter, EngineError> {
        let model_repo = model_repo.into();
        let info = AdapterInfo {
            backend: "voice-tts".to_owned(),
            model_id: model_repo.clone(),
        };
        let (jobs, receiver) = mpsc::channel::<Job>();
        std::thread::Builder::new()
            .name("fae-tts-worker".to_owned())
            .spawn(move || worker(&receiver, &model_repo, local_voices_dir.as_deref()))
            .map_err(|error| EngineError::Load(format!("tts worker spawn failed: {error}")))?;
        Ok(VoiceTtsAdapter { jobs, info })
    }
}

#[async_trait]
impl TtsAdapter for VoiceTtsAdapter {
    fn describe(&self) -> AdapterInfo {
        self.info.clone()
    }

    async fn synthesize(
        &self,
        text: &str,
        voice: &str,
        speed: f32,
    ) -> Result<TtsAudio, EngineError> {
        let (reply, response) = oneshot::channel();
        self.jobs
            .send(Job::Synthesize {
                text: text.to_owned(),
                voice: voice.to_owned(),
                speed,
                reply,
            })
            .map_err(|_| EngineError::Inference("tts worker is gone".to_owned()))?;
        response
            .await
            .map_err(|_| EngineError::Inference("tts worker dropped the request".to_owned()))?
    }
}

/// Worker loop: owns the (non-`Send`) model and voice cache for the process
/// lifetime, loading both lazily on first use.
fn worker(
    receiver: &mpsc::Receiver<Job>,
    model_repo: &str,
    local_voices_dir: Option<&std::path::Path>,
) {
    let mut model: Option<voice_tts::KokoroModel> = None;
    let mut voices: HashMap<String, voice_tts::Array> = HashMap::new();

    while let Ok(job) = receiver.recv() {
        let Job::Synthesize {
            text,
            voice,
            speed,
            reply,
        } = job;
        let result = run_synthesis(
            &mut model,
            &mut voices,
            model_repo,
            local_voices_dir,
            &text,
            &voice,
            speed,
        );
        // A dropped receiver just means the caller went away mid-request.
        let _ = reply.send(result);
    }
}

/// Load a voice embedding: local `{dir}/{voice}.safetensors` first (custom
/// voices like Fae's own), then the HF model repo's `voices/` directory.
fn load_voice_embedding(
    local_voices_dir: Option<&std::path::Path>,
    voice: &str,
) -> Result<voice_tts::Array, voice_tts::VoicersError> {
    if let Some(dir) = local_voices_dir {
        let candidate = dir.join(format!("{voice}.safetensors"));
        if candidate.is_file() {
            return voice_tts::voice::load_voice_from_file(&candidate);
        }
    }
    voice_tts::load_voice(voice, None)
}

#[allow(clippy::too_many_arguments)]
fn run_synthesis(
    model: &mut Option<voice_tts::KokoroModel>,
    voices: &mut HashMap<String, voice_tts::Array>,
    model_repo: &str,
    local_voices_dir: Option<&std::path::Path>,
    text: &str,
    voice: &str,
    speed: f32,
) -> Result<TtsAudio, EngineError> {
    if text.trim().is_empty() {
        return Err(EngineError::Inference("empty text".to_owned()));
    }

    if model.is_none() {
        let loaded = voice_tts::load_model(model_repo)
            .map_err(|error| EngineError::Load(format!("kokoro load failed: {error}")))?;
        *model = Some(loaded);
    }
    let Some(loaded_model) = model.as_mut() else {
        return Err(EngineError::NotLoaded);
    };

    if !voices.contains_key(voice) {
        let embedding = match load_voice_embedding(local_voices_dir, voice) {
            Ok(embedding) => embedding,
            Err(error) if voice != FALLBACK_VOICE => {
                // An unknown voice must degrade to a different voice, never
                // to an error (speech would silently stop downstream).
                eprintln!(
                    "fae-daemon: voice '{voice}' load failed ({error}); using {FALLBACK_VOICE}"
                );
                load_voice_embedding(local_voices_dir, FALLBACK_VOICE).map_err(|error| {
                    EngineError::Load(format!("fallback voice load failed: {error}"))
                })?
            }
            Err(error) => {
                return Err(EngineError::Load(format!(
                    "voice '{voice}' load failed: {error}"
                )));
            }
        };
        voices.insert(voice.to_owned(), embedding);
    }
    let Some(embedding) = voices.get(voice) else {
        return Err(EngineError::NotLoaded);
    };

    let chunks = voice_g2p::text_to_phoneme_chunks(text)
        .map_err(|error| EngineError::Inference(format!("g2p failed: {error}")))?;
    let mut samples: Vec<f32> = Vec::new();
    for chunk in chunks {
        if chunk.trim().is_empty() {
            continue;
        }
        let audio = voice_tts::generate(loaded_model, &chunk, embedding, speed)
            .map_err(|error| EngineError::Inference(format!("kokoro generate failed: {error}")))?;
        audio
            .eval()
            .map_err(|error| EngineError::Inference(format!("mlx eval failed: {error}")))?;
        let chunk_samples: &[f32] = audio.as_slice();
        samples.extend_from_slice(chunk_samples);
    }
    if samples.is_empty() {
        return Err(EngineError::Inference("no audio generated".to_owned()));
    }

    Ok(TtsAudio {
        wav: encode_wav_pcm16(&samples, KOKORO_SAMPLE_RATE),
        sample_rate: KOKORO_SAMPLE_RATE,
    })
}
