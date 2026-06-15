//! Realistic-shape NaN sweep — replays a captured **real Fae turn** (system
//! prompt + 36 tool schemas + audio message) through the engine adapter and
//! sweeps the system-prompt length around the live ~13k-token window, reporting
//! PASS/FAIL per length. This is the acceptance test the synthetic `nan_repro`
//! (filler-only, no tools, no audio) is NOT: it matches the exact prompt SHAPE
//! Fae sends, so it catches the windows the daemon actually lands in.
//!
//! Measured at the engine layer (direct `send_chat_request`), so a NaN surfaces
//! immediately as FAIL — there is no daemon `NAN_RETRY_PADS` loop to silently
//! paper over it.
//!
//! Env:
//!   FAE_MODEL_ID  model id (default google/gemma-4-E4B-it)
//!   FAE_ISQ       Q4K (default) | Q8_0 | Q6K | Q5K
//!   FAE_MAX_SEQ_LEN  device-map seq budget (default 32768)
//! Flags:
//!   --payload <path>   captured inject JSON {system,messages,tools,max_tokens}
//!   --base <n>         starting extra system tokens to append (default 0)
//!   --step <n>         token step between samples (default 8)
//!   --count <n>        number of samples (default 48)
//!   --max-gen <n>      max generated tokens per probe (default 16)
//!
//! Each "padding" word the sweep appends is ~1 token, so --step N ≈ N tokens of
//! total-length shift. Each line: `pad=<n> total~<tok> -> PASS|FAIL[ (err)]`.

use std::time::Instant;

use base64::Engine as _;
use mistralrs::{
    AudioInput, AutoDeviceMapParams, DeviceMapSetting, IsqType, ModelBuilder, RequestBuilder,
    TextMessageRole, Tool, ToolChoice,
};
use serde_json::Value;

type BoxErr = Box<dyn std::error::Error + Send + Sync>;

fn args() -> Vec<String> {
    std::env::args().collect()
}
fn arg1(flag: &str, default: &str) -> String {
    let a = args();
    a.iter()
        .position(|x| x == flag)
        .and_then(|i| a.get(i + 1))
        .cloned()
        .unwrap_or_else(|| default.to_owned())
}
fn role_of(s: &str) -> TextMessageRole {
    match s {
        "system" => TextMessageRole::System,
        "assistant" => TextMessageRole::Assistant,
        "tool" => TextMessageRole::Tool,
        _ => TextMessageRole::User,
    }
}
fn configured_isq() -> IsqType {
    match std::env::var("FAE_ISQ").as_deref() {
        Ok("Q8_0") | Ok("q8_0") | Ok("Q8") | Ok("q8") => IsqType::Q8_0,
        Ok("Q6K") | Ok("q6k") => IsqType::Q6K,
        Ok("Q5K") | Ok("q5k") => IsqType::Q5K,
        _ => IsqType::Q4K,
    }
}

#[tokio::main]
async fn main() -> Result<(), BoxErr> {
    let model_id = std::env::var("FAE_MODEL_ID").unwrap_or_else(|_| "google/gemma-4-E4B-it".into());
    let isq = configured_isq();
    let max_seq_len: usize = std::env::var("FAE_MAX_SEQ_LEN")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(32768);
    let payload_path = arg1("--payload", "");
    if payload_path.is_empty() {
        return Err("--payload <path> required".into());
    }
    let base: usize = arg1("--base", "0").parse().unwrap_or(0);
    let step: usize = arg1("--step", "8").parse().unwrap_or(8);
    let count: usize = arg1("--count", "48").parse().unwrap_or(48);
    let max_gen: usize = arg1("--max-gen", "16").parse().unwrap_or(16);

    let payload: Value = serde_json::from_slice(&std::fs::read(&payload_path)?)?;
    let pl = payload.get("payload").unwrap_or(&payload);
    let system_base = pl.get("system").and_then(Value::as_str).unwrap_or("");
    let msgs = pl
        .get("messages")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let tools_json = pl
        .get("tools")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    eprintln!(
        "[realshape] model={model_id} isq={isq:?} system~{}tok {} msgs {} tools | sweep base={base} step={step} count={count}",
        system_base.len() / 4,
        msgs.len(),
        tools_json.len(),
    );

    let load_start = Instant::now();
    let model = ModelBuilder::new(&model_id)
        .with_isq(isq)
        .with_device_mapping(DeviceMapSetting::Auto(AutoDeviceMapParams::Multimodal {
            max_seq_len,
            max_batch_size: 1,
            max_image_shape: (1024, 1024),
            max_num_images: 1,
        }))
        .with_logging()
        .build()
        .await?;
    eprintln!(
        "[realshape] loaded in {:.1}s",
        load_start.elapsed().as_secs_f32()
    );

    let mut fail_pads: Vec<usize> = Vec::new();

    for i in 0..count {
        let pad = base + i * step;
        let system_owned = if pad > 0 {
            format!("{system_base}\n{}", " padding".repeat(pad))
        } else {
            system_base.to_owned()
        };
        let approx_tok = system_owned.len() / 4;

        // Build the real-shape request: system + history + audio + 36 tools.
        let mut builder = RequestBuilder::new()
            .set_sampler_max_len(max_gen)
            // Mirror production: topk=160 forces CPU sampling (where the
            // "Invalid sampling probability ... NaN" surfaces).
            .set_sampler_topk(160);
        if !system_owned.is_empty() {
            builder = builder.add_message(TextMessageRole::System, &system_owned);
        }
        let last = msgs.len().saturating_sub(1);
        for (mi, m) in msgs.iter().enumerate() {
            let role = role_of(m.get("role").and_then(Value::as_str).unwrap_or("user"));
            let content = m.get("content").and_then(Value::as_str).unwrap_or("");
            let audio_b64 = m.get("audio_wav_base64").and_then(Value::as_str);
            builder = match audio_b64 {
                Some(b64) if !b64.is_empty() && mi == last => {
                    let bytes = base64::engine::general_purpose::STANDARD.decode(b64)?;
                    let clip = AudioInput::from_bytes(&bytes)?;
                    builder.add_audio_message(role, content, vec![clip])
                }
                _ => builder.add_message(role, content),
            };
        }
        if !tools_json.is_empty() {
            let mut tools = Vec::new();
            for t in &tools_json {
                let v = serde_json::json!({
                    "type":"function",
                    "function":{
                        "name": t.get("name"),
                        "description": t.get("description"),
                        "parameters": t.get("parameters"),
                    }
                });
                tools.push(serde_json::from_value::<Tool>(v)?);
            }
            builder = builder.set_tools(tools).set_tool_choice(ToolChoice::Auto);
        }

        match model.send_chat_request(builder).await {
            Ok(resp) => {
                let toks = resp.usage.completion_tokens;
                println!("pad={pad} total~{approx_tok}tok -> PASS ({toks} tok)");
            }
            Err(e) => {
                let short = e.to_string().replace('\n', " ");
                println!("pad={pad} total~{approx_tok}tok -> FAIL ({short})");
                fail_pads.push(pad);
            }
        }
    }

    println!("---");
    println!("FAIL pads: {fail_pads:?}");
    println!(
        "summary: {}/{count} FAIL, {} PASS",
        fail_pads.len(),
        count - fail_pads.len()
    );
    Ok(())
}
