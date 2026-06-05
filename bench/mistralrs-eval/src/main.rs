//! S13 spike — focused mistral.rs 0.8 eval harness for Fae's engine decision.
//!
//! Measures load time, time-to-first-token, and decode tok/s, and prints the
//! raw output so we can eyeball the Gemma-4 NaN/hang bug (#2051) and candle's
//! Qwen GGUF RoPE defect (#3410). Throwaway — delete after S13.
//!
//! Usage:
//!   mistralrs-eval text  <hf_model_id>                 [--prompt P] [--max N]
//!   mistralrs-eval gguf  <hf_model_id> <gguf_file>     [--prompt P] [--max N] [--tok ID]
//!
//! Examples (run smallest first):
//!   mistralrs-eval gguf Qwen/Qwen3-1.7B-GGUF Qwen3-1.7B-Q4_K_M.gguf
//!   mistralrs-eval text google/gemma-4-E4B-it
//!   mistralrs-eval text google/gemma-4-26b-a4b-it     # the NaN-bug suspect (#2051)

use std::time::Instant;

use anyhow::{bail, Context, Result};
use mistralrs::{
    AudioInput, GgufModelBuilder, IsqType, ModelBuilder, RequestBuilder, Response, TextMessageRole,
    TextModelBuilder, Tool, ToolChoice,
};

const WEATHER_TOOL: &str = r#"{
  "type": "function",
  "function": {
    "name": "get_weather",
    "description": "Get the current weather for a city",
    "parameters": {
      "type": "object",
      "properties": { "city": { "type": "string", "description": "City name" } },
      "required": ["city"]
    }
  }
}"#;

struct Args {
    mode: String,
    model_id: String,
    gguf_file: Option<String>,
    tok_id: Option<String>,
    prompt: String,
    max: usize,
    audio: Option<String>,
    tools: bool,
}

fn parse_args() -> Result<Args> {
    let mut a: Vec<String> = std::env::args().skip(1).collect();
    if a.len() < 2 {
        bail!("usage: mistralrs-eval <text|gguf> <model_id> [gguf_file] [--prompt P] [--max N] [--tok ID]");
    }
    let mode = a.remove(0);
    let model_id = a.remove(0);
    let mut gguf_file = None;
    if mode == "gguf" {
        if a.is_empty() || a[0].starts_with("--") {
            bail!("gguf mode needs a <gguf_file> argument");
        }
        gguf_file = Some(a.remove(0));
    }
    let mut prompt =
        "In one short paragraph, explain what a tide is and why it happens.".to_string();
    let mut max = 128usize;
    let mut tok_id = None;
    let mut audio = None;
    let mut tools = false;
    let mut i = 0;
    while i < a.len() {
        match a[i].as_str() {
            "--prompt" => {
                prompt = a.get(i + 1).context("--prompt needs a value")?.clone();
                i += 2;
            }
            "--max" => {
                max = a.get(i + 1).context("--max needs a value")?.parse()?;
                i += 2;
            }
            "--tok" => {
                tok_id = Some(a.get(i + 1).context("--tok needs a value")?.clone());
                i += 2;
            }
            "--audio" => {
                audio = Some(a.get(i + 1).context("--audio needs a WAV path")?.clone());
                i += 2;
            }
            "--tools" => {
                tools = true;
                i += 1;
            }
            other => bail!("unknown arg: {other}"),
        }
    }
    Ok(Args { mode, model_id, gguf_file, tok_id, prompt, max, audio, tools })
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = parse_args()?;
    println!("== mistralrs-eval ==");
    println!("mode={} model={} gguf={:?}", args.mode, args.model_id, args.gguf_file);

    // ---- load ----
    let load_start = Instant::now();
    let model = match args.mode.as_str() {
        "auto" => {
            // auto-detect loader — needed for multimodal models like Gemma-4
            ModelBuilder::new(&args.model_id)
                .with_isq(IsqType::Q4K)
                .with_logging()
                .build()
                .await
                .context("ModelBuilder(auto).build failed")?
        }
        "text" => {
            TextModelBuilder::new(&args.model_id)
                .with_isq(IsqType::Q4K)
                .with_logging()
                .build()
                .await
                .context("TextModelBuilder.build failed")?
        }
        "gguf" => {
            let gguf = args.gguf_file.clone().context("gguf mode requires a <gguf_file> argument")?;
            let mut b = GgufModelBuilder::new(&args.model_id, vec![gguf]).with_logging();
            if let Some(t) = &args.tok_id {
                b = b.with_tok_model_id(t);
            }
            b.build().await.context("GgufModelBuilder.build failed")?
        }
        m => bail!("unknown mode: {m} (want text|gguf)"),
    };
    let load_s = load_start.elapsed().as_secs_f64();
    println!("LOAD: {load_s:.1}s");

    // ---- build request (text, or +audio, or +tools) ----
    let mut req = RequestBuilder::new().add_message(TextMessageRole::System, "You are a helpful assistant.");
    if let Some(wav) = &args.audio {
        let clip = AudioInput::read_wav(wav).with_context(|| format!("read_wav {wav}"))?;
        println!("(audio: loaded WAV {wav})");
        req = req.add_audio_message(TextMessageRole::User, &args.prompt, vec![clip]);
    } else {
        req = req.add_message(TextMessageRole::User, &args.prompt);
    }
    if args.tools {
        let tool: Tool = serde_json::from_str(WEATHER_TOOL).context("parse tool spec")?;
        req = req.set_tools(vec![tool]).set_tool_choice(ToolChoice::Auto);
        println!("(tools: get_weather registered, ToolChoice::Auto)");
    }

    // ---- generate (streamed, to capture TTFT + decode rate) ----
    let gen_start = Instant::now();
    let mut ttft: Option<f64> = None;
    let mut chunks = 0usize;
    let mut out = String::new();
    let mut reasoning = String::new();
    let mut tool_calls = String::new();
    let mut stream = model.stream_chat_request(req).await.context("stream_chat_request failed")?;
    while let Some(resp) = stream.next().await {
        match resp {
            Response::Chunk(c) => {
                if ttft.is_none() {
                    ttft = Some(gen_start.elapsed().as_secs_f64());
                }
                if let Some(choice) = c.choices.first() {
                    if let Some(text) = &choice.delta.content {
                        out.push_str(text);
                    }
                    if let Some(rc) = &choice.delta.reasoning_content {
                        reasoning.push_str(rc);
                    }
                    if let Some(tcs) = &choice.delta.tool_calls {
                        for tc in tcs {
                            tool_calls
                                .push_str(&format!("{}({}) ", tc.function.name, tc.function.arguments));
                        }
                    }
                }
                chunks += 1;
                if chunks >= args.max {
                    break;
                }
            }
            Response::Done(_) => break,
            Response::InternalError(e) | Response::ValidationError(e) => {
                bail!("generation error: {e}");
            }
            Response::ModelError(e, _) => {
                bail!("model error: {e}");
            }
            _ => {}
        }
    }
    let gen_s = gen_start.elapsed().as_secs_f64();
    let ttft = ttft.unwrap_or(gen_s);
    let decode_s = (gen_s - ttft).max(1e-6);
    println!(
        "TTFT: {ttft:.2}s | chunks: {chunks} | decode: {:.1} chunk/s | total gen: {gen_s:.1}s",
        chunks as f64 / decode_s
    );
    if !reasoning.trim().is_empty() {
        println!("--- REASONING ({} chars) ---\n{reasoning}\n--- /REASONING ---", reasoning.len());
    }
    if !tool_calls.trim().is_empty() {
        println!("--- TOOL CALLS ---\n{tool_calls}\n--- /TOOL CALLS ---");
    }
    println!("--- OUTPUT ({} chars) ---\n{out}\n--- END ---", out.len());

    if args.tools {
        if tool_calls.trim().is_empty() {
            println!("⚠️  tools registered but model emitted NO tool call");
        } else {
            println!("✅ TOOL CALLING works — model emitted a structured tool call");
        }
    }
    if args.audio.is_some() {
        println!("ℹ️  AUDIO transcription test — eyeball the OUTPUT/REASONING above against the spoken clip");
    }

    // sniff test (distinguish thinking-only from real NaN/garbage)
    let any = format!("{reasoning}{out}");
    let trimmed = any.trim();
    if trimmed.is_empty() {
        println!("⚠️  TRULY EMPTY (no content AND no reasoning) — possible #2051 hang/NaN");
    } else if out.trim().is_empty() {
        println!("ℹ️  thinking-only: model generated reasoning but hit --max before final answer (raise --max). Engine is generating fine.");
    } else if out.trim().chars().filter(|c| !c.is_ascii()).count() > out.trim().len() / 2 {
        println!("⚠️  MOSTLY NON-ASCII output — possible garbled/RoPE defect (#3410)");
    } else {
        println!("✅ produced coherent final answer (eyeball it above for sense)");
    }
    Ok(())
}
