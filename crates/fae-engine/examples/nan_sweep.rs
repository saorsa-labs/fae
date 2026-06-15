//! Periodicity mapper for the Gemma-4 Metal NaN-logits bug (mistral.rs #2214).
//!
//! Loads the model ONCE, then drives a sweep of system-prompt char lengths and
//! records PASS/FAIL per length. The goal is to expose the *period* of the
//! failing windows in total prompt length — the fingerprint that tells us
//! whether the NaN tracks a kernel tile boundary (fixed token stride) or an
//! upstream sliding-window/KV boundary.
//!
//! Env knobs (all optional):
//!   FAE_MODEL_ID   model id (default google/gemma-4-E4B-it)
//!   FAE_ISQ        ISQ label, honoured by the adapter (Q4K / Q8_0)
//!   SWEEP_BASE     base system-prompt char length (default 36000)
//!   SWEEP_STEP     char step between samples (default 64)
//!   SWEEP_COUNT    number of samples (default 64)
//!   SWEEP_USER     user message char length (default 633)
//!
//! Each line: `len=<chars> -> PASS|FAIL[ (err)]`. A trailing summary lists the
//! FAIL lengths and the gaps between consecutive FAIL runs.

use std::time::Instant;

use fae_engine::{
    ChatEvent, ChatMessage, ChatRequest, LocalMistralrsAdapter, ProviderAdapter, Role,
};
use futures_util::StreamExt;

type BoxErr = Box<dyn std::error::Error + Send + Sync>;

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

fn env_usize(key: &str, default: usize) -> usize {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

#[tokio::main]
async fn main() -> Result<(), BoxErr> {
    let model_id = std::env::var("FAE_MODEL_ID").unwrap_or_else(|_| "google/gemma-4-E4B-it".into());
    let base = env_usize("SWEEP_BASE", 36_000);
    let step = env_usize("SWEEP_STEP", 64);
    let count = env_usize("SWEEP_COUNT", 64);
    let user_len = env_usize("SWEEP_USER", 633);

    eprintln!("[nan_sweep] model={model_id} base={base} step={step} count={count} user={user_len}");

    let load_start = Instant::now();
    let adapter = LocalMistralrsAdapter::load(&model_id).await?;
    eprintln!(
        "[nan_sweep] loaded {} in {:.1}s",
        adapter.describe().model_id,
        load_start.elapsed().as_secs_f32()
    );

    let user = filler(user_len);
    let mut fail_lengths: Vec<usize> = Vec::new();

    for i in 0..count {
        let sys_len = base + i * step;
        let system = filler(sys_len);
        let request = ChatRequest {
            system: Some(system),
            messages: vec![ChatMessage {
                role: Role::User,
                content: user.clone(),
                audio_wav_base64: None,
            }],
            tools: Vec::new(),
            max_tokens: 8,
        };

        let outcome: Result<usize, String> = async {
            let mut stream = adapter
                .stream_chat(request)
                .await
                .map_err(|e| e.to_string())?;
            let mut tokens = 0usize;
            while let Some(event) = stream.next().await {
                match event.map_err(|e| e.to_string())? {
                    ChatEvent::Token(_) => tokens += 1,
                    ChatEvent::ToolCall { .. } => {}
                    ChatEvent::Done { .. } => {}
                }
            }
            Ok(tokens)
        }
        .await;

        match outcome {
            Ok(tokens) => println!("len={sys_len} -> PASS ({tokens} tok)"),
            Err(error) => {
                let short = error.replace('\n', " ");
                println!("len={sys_len} -> FAIL ({short})");
                fail_lengths.push(sys_len);
            }
        }
    }

    println!("---");
    println!("FAIL lengths: {fail_lengths:?}");
    if fail_lengths.len() >= 2 {
        let gaps: Vec<usize> = fail_lengths.windows(2).map(|w| w[1] - w[0]).collect();
        println!("FAIL gaps (chars): {gaps:?}");
    }
    let total = count;
    let fails = fail_lengths.len();
    println!("summary: {fails}/{total} FAIL, {} PASS", total - fails);
    Ok(())
}
