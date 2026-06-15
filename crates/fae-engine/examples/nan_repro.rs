//! Deterministic Gemma-4 Metal NaN-logits repro (mistral.rs issue #2214).
//!
//! Drives the exact synthetic payload from the upstream issue: a 38,000-char
//! filler **system** prompt + a 633-char filler **user** message, no tools, no
//! audio. On the pinned `c22c2e2b` this deterministically NaNs: the device
//! sampler path surfaces "invalid Metal top-k softmax normalizer" and the CPU
//! sampler (topk=160) surfaces "Invalid sampling probability ... NaN/Inf logits".
//! Both prove the model forward pass emits NaN logits at this total length.
//!
//! Prints `RESULT: PASS` (got real tokens, no NaN) or `RESULT: FAIL (<error>)`.
//! Uses the real adapter load path so ISQ honours `FAE_ISQ` (Q4K / Q8_0).
//!
//! Run:
//!   FAE_ISQ=Q4K  FAE_MODEL_ID=google/gemma-4-E4B-it \
//!     cargo run --release -p fae-engine --example nan_repro
//!   FAE_ISQ=Q8_0 FAE_MODEL_ID=google/gemma-4-E4B-it \
//!     cargo run --release -p fae-engine --example nan_repro

use std::time::Instant;

use fae_engine::{
    ChatEvent, ChatMessage, ChatRequest, LocalMistralrsAdapter, ProviderAdapter, Role,
};
use futures_util::StreamExt;

type BoxErr = Box<dyn std::error::Error + Send + Sync>;

/// Neutral Greek-letter filler — exactly the generator from issue #2214 — so the
/// payload depends only on total length, not on any special content.
fn filler(n_chars: usize) -> String {
    const WORDS: &[&str] = &[
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
        "lambda", "mu", "nu", "xi", "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi",
        "chi", "psi", "omega",
    ];
    let mut parts: Vec<&str> = Vec::new();
    let mut total = 0usize;
    let mut i = 0usize;
    while total < n_chars {
        let w = WORDS[i % WORDS.len()];
        parts.push(w);
        total += w.len() + 1;
        i += 1;
    }
    let joined = parts.join(" ");
    joined.chars().take(n_chars).collect()
}

#[tokio::main]
async fn main() -> Result<(), BoxErr> {
    let model_id = std::env::var("FAE_MODEL_ID").unwrap_or_else(|_| "google/gemma-4-E4B-it".into());
    let isq = std::env::var("FAE_ISQ").unwrap_or_else(|_| "Q4K(default)".into());

    let system = filler(38_000);
    let user = filler(633);
    eprintln!(
        "[nan_repro] model={model_id} isq={isq} system={} chars user={} chars (no tools, no audio)",
        system.len(),
        user.len()
    );

    let load_start = Instant::now();
    let adapter = LocalMistralrsAdapter::load(&model_id).await?;
    eprintln!(
        "[nan_repro] loaded {} in {:.1}s",
        adapter.describe().model_id,
        load_start.elapsed().as_secs_f32()
    );

    let request = ChatRequest {
        system: Some(system),
        messages: vec![ChatMessage {
            role: Role::User,
            content: user,
            audio_wav_base64: None,
        }],
        tools: Vec::new(),
        max_tokens: 32,
    };

    // Drain the stream; capture the first error (the NaN surfaces mid-stream).
    let gen_start = Instant::now();
    let mut tokens = 0usize;
    let outcome: Result<(), String> = async {
        let mut stream = adapter
            .stream_chat(request)
            .await
            .map_err(|e| e.to_string())?;
        while let Some(event) = stream.next().await {
            match event.map_err(|e| e.to_string())? {
                ChatEvent::Token(_) => tokens += 1,
                ChatEvent::ToolCall { .. } => {}
                ChatEvent::Done { .. } => {}
            }
        }
        Ok(())
    }
    .await;

    let secs = gen_start.elapsed().as_secs_f32();
    match outcome {
        Ok(()) => {
            println!("RESULT: PASS (got {tokens} tokens in {secs:.1}s, no NaN)");
            Ok(())
        }
        Err(error) => {
            println!("RESULT: FAIL ({error})");
            // Non-zero exit so scripted before/after runs can branch on it.
            std::process::exit(1);
        }
    }
}
