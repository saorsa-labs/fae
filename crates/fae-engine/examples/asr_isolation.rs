//! Isolation harness for the daemon audio-ASR bug (2026-06-15).
//!
//! Runs mistral.rs audio through Fae's *real* load path
//! ([`LocalMistralrsAdapter::load`]) but with a controllable prompt, so we can
//! separate three hypotheses with one binary:
//!   1. WAV format / sample-rate mismatch  → vary the `--wav` file.
//!   2. Prompt format (empty user text vs. an explicit ASR instruction)
//!      → vary `--mode`.
//!   3. mistral.rs Gemma-4 audio simply broken on Metal in our pin
//!      → if EVERY mode fails to transcribe, it's the pin.
//!
//! Run:
//!   FAE_MODEL_ID=google/gemma-4-E4B-it \
//!     cargo run --release -p fae-engine --example asr_isolation -- \
//!     --wav /tmp/asr_q_16k.wav --mode transcribe
//!
//! Modes:
//!   transcribe — explicit "Transcribe this audio." instruction (matches the
//!                upstream mistral.rs ASR example; tests raw capability).
//!   empty      — empty user text + audio (reproduces Fae's daemon turn).
//!   question   — "Answer the spoken question." (tests comprehension, not just
//!                transcription).
//!   fae        — empty user text + a Fae-style system prompt asking for the
//!                `[heard]:` contract (closest to the live failure).

use std::time::Instant;

use base64::Engine as _;
use fae_engine::{
    ChatEvent, ChatMessage, ChatRequest, LocalMistralrsAdapter, ProviderAdapter, Role,
};
use futures_util::StreamExt;

type BoxErr = Box<dyn std::error::Error + Send + Sync>;

fn arg(flag: &str, default: &str) -> String {
    let args: Vec<String> = std::env::args().collect();
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1))
        .cloned()
        .unwrap_or_else(|| default.to_owned())
}

#[tokio::main]
async fn main() -> Result<(), BoxErr> {
    let model_id = std::env::var("FAE_MODEL_ID").unwrap_or_else(|_| "google/gemma-4-E4B-it".into());
    let wav_path = arg("--wav", "/tmp/asr_q_16k.wav");
    let mode = arg("--mode", "transcribe");

    let wav_bytes = std::fs::read(&wav_path)?;
    let encoded = base64::engine::general_purpose::STANDARD.encode(&wav_bytes);
    eprintln!(
        "[harness] model={model_id} wav={wav_path} ({} bytes) mode={mode}",
        wav_bytes.len()
    );

    let (system, content): (Option<String>, &str) = match mode.as_str() {
        "transcribe" => (
            Some("You are a helpful assistant.".to_owned()),
            "Transcribe this audio.",
        ),
        "empty" => (Some("You are a helpful assistant.".to_owned()), ""),
        "question" => (
            Some("You are a helpful assistant.".to_owned()),
            "Answer the spoken question.",
        ),
        "fae" => (
            Some(
                "You are Fae, a warm voice assistant. Begin every reply with a \
                 line `[heard]: <verbatim transcript of the user's speech>`, then \
                 answer."
                    .to_owned(),
            ),
            "",
        ),
        other => return Err(format!("unknown --mode {other}").into()),
    };

    // Override the user-message content (the instruction sent alongside the
    // audio). `--content ""` keeps it empty.
    let content_override = arg("--content", "\u{0}");
    let content: &str = if content_override == "\u{0}" {
        content
    } else {
        &content_override
    };

    // Optionally pad the system prompt toward a target token count to reproduce
    // the live daemon's ~7300-token personality prompt (`--syspad 7300`). Filler
    // is Fae-flavoured prose so the priming is realistic, not random noise.
    let syspad: usize = arg("--syspad", "0").parse().unwrap_or(0);
    let mut system = system;
    if syspad > 0 {
        let base = system.unwrap_or_default();
        let filler_unit = "You are Fae, a warm and proactive voice companion who \
            remembers what matters to the user, watches for presence, and helps \
            with calendars, mail, notes, and reminders throughout the day. You \
            are gentle, concise, and never interrupt. ";
        // ~0.75 tokens/word → estimate ~1.3 tokens per 6 chars; pad by chars.
        let target_chars = syspad * 4;
        let mut s = String::with_capacity(target_chars + base.len());
        s.push_str(&base);
        s.push('\n');
        while s.len() < target_chars {
            s.push_str(filler_unit);
        }
        eprintln!("[harness] syspad: system prompt ~{} chars", s.len());
        system = Some(s);
    }

    // Optionally attach N dummy tool specs (the live daemon sends 6-15).
    let n_tools: usize = arg("--tools", "0").parse().unwrap_or(0);
    let tools: Vec<fae_engine::ToolSpec> = (0..n_tools)
        .map(|i| fae_engine::ToolSpec {
            name: format!("tool_{i}"),
            description: format!("Performs operation number {i} on the user's data."),
            parameters: serde_json::json!({
                "type": "object",
                "properties": { "arg": { "type": "string", "description": "the argument" } },
                "required": ["arg"]
            }),
        })
        .collect();
    if n_tools > 0 {
        eprintln!("[harness] attached {n_tools} dummy tools");
    }

    let load_start = Instant::now();
    let adapter = LocalMistralrsAdapter::load(&model_id).await?;
    eprintln!(
        "[harness] loaded {} in {:.1}s",
        adapter.describe().model_id,
        load_start.elapsed().as_secs_f32()
    );

    let request = ChatRequest {
        system,
        messages: vec![ChatMessage {
            role: Role::User,
            content: content.to_owned(),
            audio_wav_base64: Some(encoded),
        }],
        tools,
        max_tokens: 256,
    };

    let gen_start = Instant::now();
    let mut stream = adapter.stream_chat(request).await?;
    let mut out = String::new();
    let mut tokens = 0usize;
    while let Some(event) = stream.next().await {
        match event? {
            ChatEvent::Token(text) => {
                out.push_str(&text);
                tokens += 1;
            }
            ChatEvent::ToolCall { name, arguments } => {
                eprintln!("[harness] tool_call {name}({arguments})");
            }
            ChatEvent::Done { finish_reason } => {
                eprintln!("[harness] done: {finish_reason}");
            }
        }
    }
    let secs = gen_start.elapsed().as_secs_f32();
    eprintln!(
        "[harness] {tokens} tokens in {secs:.1}s ({:.2} tps)",
        tokens as f32 / secs.max(0.001)
    );
    println!("\n===== REPLY ({mode}) =====\n{out}\n==========================");
    Ok(())
}
