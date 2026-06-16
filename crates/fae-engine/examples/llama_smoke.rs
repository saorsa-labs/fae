//! Live smoke for `LlamaServerAdapter` (gap B1). Streams one turn through the
//! real adapter against a running `llama-server`, proving the HTTP/SSE →
//! `ChatEvent` path end-to-end (not just the pure unit tests).
//!
//! ```sh
//! # start a server first, then:
//! FAE_LLAMA_SERVER_URL=http://127.0.0.1:18095 \
//!   cargo run -p fae-engine --example llama_smoke -- "Name the capital of Scotland."
//! ```

use fae_engine::{ChatEvent, ChatMessage, ChatRequest, LlamaServerAdapter, ProviderAdapter, Role};
use futures_util::StreamExt;

#[tokio::main]
async fn main() {
    let url = std::env::var("FAE_LLAMA_SERVER_URL")
        .unwrap_or_else(|_| "http://127.0.0.1:18095".to_owned());
    let prompt = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "Name the capital of Scotland in one word.".to_owned());

    let adapter = LlamaServerAdapter::connect(&url, "gemma-4-e4b");
    let request = ChatRequest {
        system: Some("You are a concise assistant.".to_owned()),
        messages: vec![ChatMessage::text(Role::User, prompt.clone())],
        tools: Vec::new(),
        max_tokens: 64,
    };

    eprintln!("[smoke] {url} <- {prompt:?}");
    let mut stream = match adapter.stream_chat(request).await {
        Ok(stream) => stream,
        Err(error) => {
            eprintln!("[smoke] FAILED before first token: {error}");
            std::process::exit(1);
        }
    };

    let mut answer = String::new();
    let mut tokens = 0usize;
    while let Some(event) = stream.next().await {
        match event {
            Ok(ChatEvent::Token(text)) => {
                print!("{text}");
                let _ = std::io::Write::flush(&mut std::io::stdout());
                answer.push_str(&text);
                tokens += 1;
            }
            Ok(ChatEvent::ToolCall { name, arguments }) => {
                eprintln!("\n[smoke] tool_call: {name}({arguments})");
            }
            Ok(ChatEvent::Done { finish_reason }) => {
                eprintln!(
                    "\n[smoke] DONE ({finish_reason}) — {tokens} token events, {} chars",
                    answer.len()
                );
                break;
            }
            Err(error) => {
                eprintln!("\n[smoke] stream error: {error}");
                std::process::exit(1);
            }
        }
    }
    if answer.trim().is_empty() {
        eprintln!("[smoke] FAILED: empty answer");
        std::process::exit(2);
    }
}
