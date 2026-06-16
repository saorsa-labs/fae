//! Live de-risk for `engine.reload` (gap B3b): spawn a managed `llama-server`
//! sidecar, serve a turn, then `reload_adapter` with a personal LoRA (kills the
//! old child, rebinds the same port, respawns with `--lora`) and serve again.
//!
//! ```sh
//! cargo run -p fae-engine --example llama_reload   # needs ~/llama-spike bench
//! ```

use fae_engine::{
    ChatEvent, ChatMessage, ChatRequest, LlamaServerAdapter, LlamaServerConfig, ProviderAdapter,
    Role,
};
use futures_util::StreamExt;

#[tokio::main]
async fn main() {
    let home = std::env::var("HOME").expect("HOME");
    let config = LlamaServerConfig {
        binary: format!("{home}/llama-spike/llama.cpp/build/bin/llama-server"),
        model_gguf: format!("{home}/llama-spike/gguf/gemma-4-E4B-it-Q4_K_M.gguf"),
        lora_gguf: None,
        mmproj: None,
        port: 18100,
        ctx_size: 4096,
        ngl: 99,
    };
    eprintln!("[reload] spawning managed sidecar (no LoRA)…");
    let adapter = LlamaServerAdapter::spawn(config, "gemma-4-e4b")
        .await
        .expect("spawn");
    ask(&adapter, "before reload").await;

    let lora = format!("{home}/llama-spike/personal-e4b-f16.gguf");
    eprintln!("[reload] reload_adapter(Some({lora}))…");
    adapter
        .reload_adapter(Some(lora))
        .await
        .expect("reload should restart the sidecar");
    eprintln!("[reload] reloaded — server rebound on the same port");
    ask(&adapter, "after reload").await;
    eprintln!("[reload] SUCCESS: sidecar restarted + served before and after");
}

async fn ask(adapter: &LlamaServerAdapter, label: &str) {
    let request = ChatRequest {
        system: None,
        messages: vec![ChatMessage::text(
            Role::User,
            "Reply with the single word OK.",
        )],
        tools: Vec::new(),
        max_tokens: 8,
    };
    let mut stream = adapter.stream_chat(request).await.expect("stream");
    let mut out = String::new();
    while let Some(event) = stream.next().await {
        match event {
            Ok(ChatEvent::Token(text)) => out.push_str(&text),
            Ok(ChatEvent::Done { .. }) => break,
            Ok(ChatEvent::ToolCall { .. }) => {}
            Err(error) => {
                eprintln!("[reload] {label}: STREAM ERROR {error}");
                std::process::exit(1);
            }
        }
    }
    eprintln!("[reload] {label}: responded {:?}", out.trim());
}
