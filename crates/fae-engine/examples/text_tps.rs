//! Minimal text-only decode throughput probe (2026-06-15).
//!
//! No audio, no tools — a plain text prompt that forces a long, sustained
//! generation so we can measure steady-state Metal decode tokens/sec on this
//! hardware. Used to refute the "candle runs on CPU" hypothesis: if a clean
//! text turn decodes at tens of tok/s on Metal, the device is correct and the
//! daemon's glacial latency comes from the Gemma-4 Metal NaN-logits retry loop,
//! not CPU execution.
//!
//! Run:
//!   FAE_MODEL_ID=google/gemma-4-E4B-it \
//!     cargo run --release -p fae-engine --example text_tps -- --max 300

use std::time::Instant;

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
    let max_tokens: usize = arg("--max", "300").parse().unwrap_or(300);
    let prompt = arg(
        "--prompt",
        "Write a detailed, multi-paragraph explanation of how a transformer \
         neural network works, covering attention, feed-forward layers, and \
         positional encoding. Be thorough.",
    );

    let load_start = Instant::now();
    let adapter = LocalMistralrsAdapter::load(&model_id).await?;
    eprintln!(
        "[text_tps] loaded {} in {:.1}s",
        adapter.describe().model_id,
        load_start.elapsed().as_secs_f32()
    );

    let request = ChatRequest {
        system: None,
        messages: vec![ChatMessage {
            role: Role::User,
            content: prompt,
            audio_wav_base64: None,
        }],
        tools: Vec::new(),
        max_tokens,
    };

    let gen_start = Instant::now();
    let mut stream = adapter.stream_chat(request).await?;
    let mut tokens = 0usize;
    let mut first_token_s = 0.0f32;
    while let Some(event) = stream.next().await {
        match event? {
            ChatEvent::Token(_) => {
                if tokens == 0 {
                    first_token_s = gen_start.elapsed().as_secs_f32();
                }
                tokens += 1;
            }
            ChatEvent::ToolCall { .. } => {}
            ChatEvent::Done { finish_reason } => {
                eprintln!("[text_tps] done: {finish_reason}");
            }
        }
    }
    let secs = gen_start.elapsed().as_secs_f32();
    let decode_secs = (secs - first_token_s).max(0.001);
    eprintln!(
        "[text_tps] ttfa={first_token_s:.2}s total={secs:.1}s tokens={tokens} \
         decode_tps={:.2} (steady-state, excludes prefill)",
        (tokens.saturating_sub(1)) as f32 / decode_secs
    );
    Ok(())
}
