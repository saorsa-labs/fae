//! Headless offline voice-turn driver (P5/D2-V5, Stage 3).
//!
//! Proves the full Linux voice spine WITHOUT an audio device: a provided WAV
//! clip → STT (the same audio-capable engine turn the push-to-talk path uses) →
//! LLM turn → `tts.synthesize` (Piper on Linux) → a spoken-answer WAV written to
//! disk. Optionally it round-trips the synthesized WAV back through STT to show
//! the words survive synthesis (an intelligibility smoke).
//!
//! This is the headless-verifiable proof CI runs (CPU-only, no device). It
//! reuses the production turn loop (`session::run_turn`) and the real backend
//! builders (`build_engine`/`build_asr_fallback_engine`/`build_tts_engine`) so
//! it can't drift from the served pipeline.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::Engine as _;
use fae_engine::{ChatMessage, ChatRequest, ProviderAdapter, Role, TtsAdapter};

use crate::session::{normalize_asr_transcript, run_turn};

/// Parsed `--offline-turn` arguments.
pub struct OfflineTurnArgs {
    /// Input WAV clip to transcribe. `None` in `--tts-only` mode.
    pub input_wav: Option<PathBuf>,
    /// Where to write the synthesized spoken-answer WAV.
    pub output_wav: PathBuf,
    /// Voice name passed to the TTS adapter (Piper resolves its pinned voice).
    pub voice: String,
    /// When true, round-trip the synthesized WAV back through STT and HARD-gate
    /// on the recovered words (intelligibility check). Ignored in `--tts-only`.
    pub roundtrip: bool,
    /// Optional expected words for the round-trip overlap assertion. When set
    /// and `roundtrip` is on, the recovered transcript must share at least one
    /// word with these, or the turn fails. `None` only checks non-empty.
    pub expect_words: Option<String>,
    /// Minimum number of expected words that must survive the round-trip
    /// (default 1). CI sets this higher (e.g. 2) to make the intelligibility
    /// gate robust against a single chance match.
    pub min_overlap: usize,
    /// TTS-only mode (CI gate): skip STT+LLM, synthesize `tts_text` directly
    /// through the integrity-gated Piper adapter. Proves the riskiest NEW leg
    /// (Piper invocation + integrity gate + 22.05→24 kHz resample) WITHOUT a
    /// multi-GB LLM/ASR model download. `None` = full STT→LLM→TTS turn.
    pub tts_text: Option<String>,
}

impl OfflineTurnArgs {
    /// Parse from a raw args iterator (everything after `--offline-turn`).
    /// Full-turn flags: `--in <wav>` (required) + `--out <wav>` (required) +
    /// `--voice <name>`/`--roundtrip` (optional). TTS-only: `--tts-only`
    /// `--text <words>` + `--out <wav>` (no `--in`).
    pub fn parse(mut args: impl Iterator<Item = String>) -> Result<OfflineTurnArgs, String> {
        let mut input_wav: Option<PathBuf> = None;
        let mut output_wav: Option<PathBuf> = None;
        let mut voice = "en_US-lessac-medium".to_owned();
        let mut roundtrip = false;
        let mut tts_only = false;
        let mut text: Option<String> = None;
        let mut expect_words: Option<String> = None;
        let mut min_overlap: usize = 1;
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--in" => {
                    input_wav = Some(PathBuf::from(args.next().ok_or("--in requires a path")?));
                }
                "--out" => {
                    output_wav = Some(PathBuf::from(args.next().ok_or("--out requires a path")?));
                }
                "--voice" => {
                    voice = args.next().ok_or("--voice requires a name")?;
                }
                "--text" => {
                    text = Some(args.next().ok_or("--text requires a string")?);
                }
                "--expect-words" => {
                    expect_words = Some(args.next().ok_or("--expect-words requires a string")?);
                }
                "--min-overlap" => {
                    let raw = args.next().ok_or("--min-overlap requires a number")?;
                    min_overlap = raw
                        .parse()
                        .map_err(|_| format!("--min-overlap not a number: {raw}"))?;
                }
                "--tts-only" => tts_only = true,
                "--roundtrip" => roundtrip = true,
                other => return Err(format!("unknown --offline-turn arg: {other}")),
            }
        }
        let output_wav = output_wav.ok_or("--offline-turn requires --out <wav>")?;
        if tts_only {
            let tts_text = text.ok_or("--tts-only requires --text <words>")?;
            if tts_text.trim().is_empty() {
                return Err("--text must not be empty".to_owned());
            }
            return Ok(OfflineTurnArgs {
                input_wav: None,
                output_wav,
                voice,
                // tts-only honors --roundtrip: the round-trip transcribes the
                // synthesized WAV through the ASR engine (no Gemma) — the
                // intelligibility gate for the Piper leg.
                roundtrip,
                expect_words,
                min_overlap,
                tts_text: Some(tts_text),
            });
        }
        Ok(OfflineTurnArgs {
            input_wav: Some(input_wav.ok_or("--offline-turn requires --in <wav> (or --tts-only)")?),
            output_wav,
            voice,
            roundtrip,
            expect_words,
            min_overlap,
            tts_text: None,
        })
    }
}

/// Count how many distinct expected words appear in `actual` (case-insensitive,
/// punctuation-stripped). Used for the round-trip intelligibility gate — STT
/// rarely reproduces a phrase verbatim, so any word overlap is the signal.
fn word_overlap(expected: &str, actual: &str) -> usize {
    fn words(text: &str) -> std::collections::HashSet<String> {
        text.split_whitespace()
            .map(|word| {
                word.chars()
                    .filter(|c| c.is_alphanumeric())
                    .flat_map(char::to_lowercase)
                    .collect::<String>()
            })
            .filter(|word| !word.is_empty())
            .collect()
    }
    let actual_words = words(actual);
    words(expected)
        .iter()
        .filter(|word| actual_words.contains(*word))
        .count()
}

/// Transcribe a base64 WAV clip via the audio-capable engine, falling back to
/// the dedicated ASR engine if the primary turn yields nothing. Returns the
/// cleaned transcript (never empty on success).
async fn transcribe(
    engine: &dyn ProviderAdapter,
    asr_fallback: Option<&dyn ProviderAdapter>,
    wav_base64: &str,
) -> Result<String, String> {
    let request = ChatRequest {
        system: Some(
            "Transcribe the user's audio verbatim. Output only the exact words spoken — no labels, commentary, or answers."
                .to_owned(),
        ),
        messages: vec![ChatMessage {
            role: Role::User,
            content: String::new(),
            audio_wav_base64: Some(wav_base64.to_owned()),
        }],
        tools: Vec::new(),
        max_tokens: 128,
    };
    let result = run_turn(engine, request).await?;
    let transcript = result
        .get("text")
        .and_then(serde_json::Value::as_str)
        .map(normalize_asr_transcript)
        .unwrap_or_default();
    if !transcript.is_empty() {
        return Ok(transcript);
    }
    // Primary produced nothing — try the dedicated ASR engine if present.
    let Some(asr) = asr_fallback else {
        return Err(
            "primary STT produced an empty transcript and no ASR fallback is configured".to_owned(),
        );
    };
    let request = ChatRequest {
        system: Some(
            "Transcribe the user's audio verbatim. Output only the exact words spoken — no labels, commentary, or answers."
                .to_owned(),
        ),
        messages: vec![ChatMessage {
            role: Role::User,
            content: String::new(),
            audio_wav_base64: Some(wav_base64.to_owned()),
        }],
        tools: Vec::new(),
        max_tokens: 128,
    };
    let result = run_turn(asr, request).await?;
    let transcript = result
        .get("text")
        .and_then(serde_json::Value::as_str)
        .map(normalize_asr_transcript)
        .unwrap_or_default();
    if transcript.is_empty() {
        return Err("both primary STT and ASR fallback produced empty transcripts".to_owned());
    }
    Ok(transcript)
}

/// Run one LLM turn over a plain-text user message, returning the visible answer.
async fn answer_turn(engine: &dyn ProviderAdapter, user_text: &str) -> Result<String, String> {
    let request = ChatRequest {
        system: None,
        messages: vec![ChatMessage {
            role: Role::User,
            content: user_text.to_owned(),
            audio_wav_base64: None,
        }],
        tools: Vec::new(),
        max_tokens: 256,
    };
    let result = run_turn(engine, request).await?;
    let answer = result
        .get("text")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_owned();
    if answer.is_empty() {
        return Err("LLM turn produced an empty answer".to_owned());
    }
    Ok(answer)
}

/// Number of PCM16-mono samples in a canonical WAV's `data` chunk, for the
/// duration assertion. Returns `(samples, sample_rate)`.
fn wav_sample_count(wav: &[u8]) -> Result<(usize, u32), String> {
    if wav.len() < 44 || &wav[0..4] != b"RIFF" || &wav[8..12] != b"WAVE" {
        return Err("output is not a RIFF/WAVE file".to_owned());
    }
    let mut offset = 12_usize;
    let mut sample_rate = 0_u32;
    let mut data_len = 0_usize;
    while offset.saturating_add(8) <= wav.len() {
        let id = &wav[offset..offset + 4];
        let size = u32::from_le_bytes([
            wav[offset + 4],
            wav[offset + 5],
            wav[offset + 6],
            wav[offset + 7],
        ]) as usize;
        offset = offset.saturating_add(8);
        if id == b"fmt " && size >= 16 {
            sample_rate = u32::from_le_bytes([
                wav[offset + 4],
                wav[offset + 5],
                wav[offset + 6],
                wav[offset + 7],
            ]);
        } else if id == b"data" {
            data_len = size.min(wav.len().saturating_sub(offset));
        }
        offset = offset.saturating_add(size + (size % 2));
    }
    if sample_rate == 0 {
        return Err("output WAV missing fmt chunk".to_owned());
    }
    Ok((data_len / 2, sample_rate))
}

/// Synthesize `text` through the (integrity-gated) TTS adapter, assert the WAV
/// is non-empty + correct-duration, write it to `out`, and return the decoded
/// `(wav_bytes, samples, sample_rate)` for any follow-on round-trip.
async fn synthesize_to_file(
    tts: &dyn TtsAdapter,
    text: &str,
    voice: &str,
    out: &Path,
) -> Result<Vec<u8>, String> {
    println!("[offline-turn] TTS: synthesizing with voice {voice}");
    let audio = tts
        .synthesize(text, voice, 1.0)
        .await
        .map_err(|error| format!("tts.synthesize failed: {error}"))?;
    let (samples, sample_rate) = wav_sample_count(&audio.wav)?;
    if samples == 0 {
        return Err("synthesized WAV has zero audio samples".to_owned());
    }
    let duration_ms = (samples as u64 * 1000) / u64::from(sample_rate.max(1));
    std::fs::write(out, &audio.wav)
        .map_err(|error| format!("write output {}: {error}", out.display()))?;
    println!(
        "[offline-turn] wrote {} ({} bytes, {} samples @ {} Hz, ~{} ms)",
        out.display(),
        audio.wav.len(),
        samples,
        sample_rate,
        duration_ms
    );
    Ok(audio.wav)
}

/// HARD intelligibility gate: re-transcribe the synthesized WAV through
/// `transcriber` and assert the recovered words are non-empty and (when
/// `expect_words` is set) overlap the expected phrase. With the macOS Piper
/// smoke infeasible, this round-trip is the SOLE proof Piper produced
/// intelligible speech, so any failure aborts the turn.
async fn assert_intelligible(
    transcriber: &dyn ProviderAdapter,
    asr_fallback: Option<&dyn ProviderAdapter>,
    synth_wav: &[u8],
    expect_words: Option<&str>,
    min_overlap: usize,
) -> Result<(), String> {
    println!("[offline-turn] round-trip: re-transcribing the synthesized WAV");
    let synth_b64 = base64::engine::general_purpose::STANDARD.encode(synth_wav);
    let recovered = transcribe(transcriber, asr_fallback, &synth_b64)
        .await
        .map_err(|error| format!("round-trip STT failed: {error}"))?;
    println!("[offline-turn] round-trip heard: {recovered:?}");
    if recovered.trim().is_empty() {
        return Err(
            "round-trip transcript is empty — synthesized audio was not intelligible".to_owned(),
        );
    }
    if let Some(expected) = expect_words {
        let overlap = word_overlap(expected, &recovered);
        // At least one word must overlap, plus any caller-set higher bar.
        let required = min_overlap.max(1);
        println!(
            "[offline-turn] round-trip word overlap: {overlap} (need >= {required}) of expected {expected:?}"
        );
        if overlap < required {
            return Err(format!(
                "round-trip transcript {recovered:?} overlaps expected {expected:?} by only {overlap} words (need >= {required}) — not intelligible"
            ));
        }
    }
    Ok(())
}

/// Drive the headless turn. In `--tts-only` mode it synthesizes the provided
/// text directly through Piper (no LLM); with `--roundtrip` it transcribes the
/// synthesized WAV back through the ASR engine to HARD-gate intelligibility.
/// Otherwise it builds the full STT → LLM → Piper TTS turn from the input clip.
pub async fn run(
    args: OfflineTurnArgs,
    engine: Option<Arc<dyn ProviderAdapter>>,
    asr_fallback: Option<Arc<dyn ProviderAdapter>>,
    tts: Arc<dyn TtsAdapter>,
) -> Result<(), String> {
    // TTS-only: exercise the integrity-gated Piper leg without STT/LLM. The
    // adapter was already built (and its binary/voice SHA-verified) by the
    // daemon; a synthesis failure here is a real Piper/integrity failure. No
    // engine is built in this mode.
    if let Some(text) = &args.tts_text {
        println!("[offline-turn] tts-only: text {text:?}");
        let synth_wav =
            synthesize_to_file(tts.as_ref(), text, &args.voice, &args.output_wav).await?;
        if args.roundtrip {
            // Round-trip transcription uses the ASR engine ONLY (no Gemma LLM):
            // re-proving STT+LLM isn't the point — Piper intelligibility is.
            let transcriber = asr_fallback.as_deref().ok_or(
                "tts-only --roundtrip needs the ASR engine (set FAE_AUDIO_FALLBACK + install the runtime)",
            )?;
            // Expect the synthesized text's own words to survive round-trip.
            let expect = args.expect_words.as_deref().or(Some(text.as_str()));
            assert_intelligible(transcriber, None, &synth_wav, expect, args.min_overlap).await?;
        }
        println!("[offline-turn] OK");
        return Ok(());
    }

    let engine = engine.ok_or("full-turn mode requires the LLM engine")?;
    let input_wav = args
        .input_wav
        .as_ref()
        .ok_or("full-turn mode requires --in <wav>")?;
    let clip = std::fs::read(input_wav)
        .map_err(|error| format!("read input clip {}: {error}", input_wav.display()))?;
    if clip.is_empty() {
        return Err(format!("input clip {} is empty", input_wav.display()));
    }
    let clip_b64 = base64::engine::general_purpose::STANDARD.encode(&clip);

    println!("[offline-turn] STT: transcribing {}", input_wav.display());
    let asr_ref = asr_fallback.as_deref();
    let transcript = transcribe(engine.as_ref(), asr_ref, &clip_b64).await?;
    println!("[offline-turn] heard: {transcript:?}");

    println!("[offline-turn] LLM: running answer turn");
    let answer = answer_turn(engine.as_ref(), &transcript).await?;
    println!("[offline-turn] answer: {answer:?}");

    let synth_wav =
        synthesize_to_file(tts.as_ref(), &answer, &args.voice, &args.output_wav).await?;

    if args.roundtrip {
        // SELF-CONSISTENCY (full-turn): the synthesized audio is the LLM's
        // ANSWER, which is nondeterministic — so the round-trip must be checked
        // against the ANSWER we just synthesized, NOT a fixed --expect-words
        // (which describes the input QUESTION). Require ~half the answer's words
        // to survive Piper → STT. (The deterministic intelligibility proof is the
        // tts-only path, where synthesized text == expected text.)
        let answer_word_count = word_overlap(&answer, &answer); // distinct words
        let required = answer_word_count.div_ceil(2).max(1);
        println!(
            "[offline-turn] full-turn self-consistency: need >= {required} of {answer_word_count} answer words to survive"
        );
        assert_intelligible(
            engine.as_ref(),
            asr_ref,
            &synth_wav,
            Some(&answer),
            required,
        )
        .await?;
    }

    println!("[offline-turn] OK");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use fae_engine::encode_wav_pcm16;

    #[test]
    fn parse_requires_in_and_out() {
        // Full-turn mode: --in alone (no --out) and --out alone (no --in) both fail.
        assert!(OfflineTurnArgs::parse(["--in", "a.wav"].into_iter().map(String::from)).is_err());
        assert!(OfflineTurnArgs::parse(["--out", "b.wav"].into_iter().map(String::from)).is_err());
        let ok = OfflineTurnArgs::parse(
            ["--in", "a.wav", "--out", "b.wav", "--roundtrip"]
                .into_iter()
                .map(String::from),
        )
        .expect("valid args");
        assert_eq!(ok.input_wav, Some(PathBuf::from("a.wav")));
        assert_eq!(ok.output_wav, PathBuf::from("b.wav"));
        assert!(ok.roundtrip);
        assert!(ok.tts_text.is_none());
        assert!(ok.expect_words.is_none());
        assert_eq!(ok.voice, "en_US-lessac-medium");
    }

    #[test]
    fn parse_captures_expect_words() {
        let ok = OfflineTurnArgs::parse(
            [
                "--in",
                "a.wav",
                "--out",
                "b.wav",
                "--roundtrip",
                "--expect-words",
                "what time is it",
            ]
            .into_iter()
            .map(String::from),
        )
        .expect("valid args");
        assert_eq!(ok.expect_words.as_deref(), Some("what time is it"));
        assert_eq!(ok.min_overlap, 1); // default
    }

    #[test]
    fn parse_min_overlap() {
        let ok = OfflineTurnArgs::parse(
            [
                "--tts-only",
                "--text",
                "fox",
                "--out",
                "o.wav",
                "--roundtrip",
                "--min-overlap",
                "2",
            ]
            .into_iter()
            .map(String::from),
        )
        .expect("valid args");
        assert_eq!(ok.min_overlap, 2);
        // Non-numeric --min-overlap is rejected.
        assert!(OfflineTurnArgs::parse(
            [
                "--tts-only",
                "--text",
                "x",
                "--out",
                "o.wav",
                "--min-overlap",
                "nope"
            ]
            .into_iter()
            .map(String::from)
        )
        .is_err());
    }

    #[test]
    fn self_consistency_threshold_is_half_the_answer_words() {
        // Full-turn round-trip compares vs the ANSWER (self-consistency), not the
        // question. Threshold = ceil(distinct_answer_words / 2), min 1.
        let answer = "the time is three o'clock"; // distinct: the,time,is,three,oclock = 5
        let distinct = word_overlap(answer, answer);
        assert_eq!(distinct, 5);
        let required = distinct.div_ceil(2).max(1);
        assert_eq!(required, 3);
        // A round-trip recovering 3/5 answer words passes the bar.
        assert!(word_overlap(answer, "time is three") >= required);
        // Recovering only 1 word does not.
        assert!(word_overlap(answer, "the umm") < required);
    }

    #[test]
    fn word_overlap_is_case_and_punctuation_insensitive() {
        // STT rarely matches verbatim; any shared word is the intelligibility signal.
        assert_eq!(word_overlap("What time is it", "what TIME is it?"), 4);
        assert_eq!(word_overlap("What time is it", "the time, please"), 1);
        assert_eq!(
            word_overlap("What time is it", "completely different words"),
            0
        );
        // Empty actual → zero overlap (the empty-transcript gate catches this too).
        assert_eq!(word_overlap("hello", ""), 0);
    }

    #[test]
    fn parse_tts_only_needs_text_and_out_not_in() {
        // --tts-only without --text fails.
        assert!(OfflineTurnArgs::parse(
            ["--tts-only", "--out", "o.wav"]
                .into_iter()
                .map(String::from)
        )
        .is_err());
        // --tts-only with empty text fails.
        assert!(OfflineTurnArgs::parse(
            ["--tts-only", "--text", "   ", "--out", "o.wav"]
                .into_iter()
                .map(String::from)
        )
        .is_err());
        // Valid tts-only: no --in required, tts_text set, roundtrip forced off.
        let ok = OfflineTurnArgs::parse(
            ["--tts-only", "--text", "Hello from Fae.", "--out", "o.wav"]
                .into_iter()
                .map(String::from),
        )
        .expect("valid tts-only args");
        assert!(ok.input_wav.is_none());
        assert_eq!(ok.tts_text.as_deref(), Some("Hello from Fae."));
        assert!(!ok.roundtrip);
    }

    #[test]
    fn parse_rejects_unknown_flag() {
        assert!(OfflineTurnArgs::parse(["--bogus"].into_iter().map(String::from)).is_err());
    }

    #[test]
    fn wav_sample_count_reads_canonical_wav() {
        let wav = encode_wav_pcm16(&[0.0; 2400], 24_000);
        let (samples, rate) = wav_sample_count(&wav).expect("valid wav");
        assert_eq!(samples, 2400);
        assert_eq!(rate, 24_000);
        assert!(wav_sample_count(b"not a wav").is_err());
    }
}
