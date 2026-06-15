//! Multi-turn / prefix-cache NaN repro for the real Fae prompt shape (system +
//! 36 tool schemas), driven directly through the engine adapter. Loads the model
//! ONCE with prefix caching ON (mirroring the live daemon) and sends several
//! turns whose final message grows a little each pass, so the shared prefix is a
//! cache hit while total length sweeps across the live ~13k-token window. This
//! reproduces the daemon's real conversational shape that the single-turn
//! `nan_repro`/`realshape_sweep` do not.
//!
//! Empirically (Apple M5 Max): `google/gemma-4-12B-it` at prompt_tok≈12,813 NaNs
//! with the candle steel-SDPA fix DISABLED (`FAE_DISABLE_SDPA_FIX=1`) and is
//! clean with it ENABLED — i.e. the SAME `do_causal && !has_mask` fix that cures
//! E4B also covers 12B (the attention mask is present on every prefill call, so
//! the fix forces `do_causal=false` and avoids the degenerate path). Reports
//! PASS/FAIL per pass.
//!
//! Run:
//!   FAE_ISQ=Q4K FAE_MODEL_ID=google/gemma-4-12B-it \
//!     cargo run --release -p fae-engine --example prefix_repro -- \
//!     --payload /tmp/fae-dumps/inject-1781284731871-r3.json --passes 6

use std::time::Instant;

use mistralrs::{
    AutoDeviceMapParams, DeviceMapSetting, IsqType, ModelBuilder, RequestBuilder, TextMessageRole,
    Tool, ToolChoice,
};
use serde_json::Value;

type BoxErr = Box<dyn std::error::Error + Send + Sync>;

fn arg1(flag: &str, default: &str) -> String {
    let a: Vec<String> = std::env::args().collect();
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
        Ok("Q8_0") | Ok("q8_0") => IsqType::Q8_0,
        Ok("Q6K") | Ok("q6k") => IsqType::Q6K,
        Ok("Q5K") | Ok("q5k") => IsqType::Q5K,
        _ => IsqType::Q4K,
    }
}

#[tokio::main]
async fn main() -> Result<(), BoxErr> {
    let model_id = std::env::var("FAE_MODEL_ID").unwrap_or_else(|_| "google/gemma-4-12B-it".into());
    let isq = configured_isq();
    let payload_path = arg1("--payload", "");
    if payload_path.is_empty() {
        return Err("--payload <path> required".into());
    }
    let passes: usize = arg1("--passes", "6").parse().unwrap_or(6);
    let max_seq_len: usize = arg1("--max-seq-len", "32768").parse().unwrap_or(32768);

    let payload: Value = serde_json::from_slice(&std::fs::read(&payload_path)?)?;
    let pl = payload.get("payload").unwrap_or(&payload);
    let system = pl
        .get("system")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
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
        "[prefix_repro] model={model_id} isq={isq:?} system~{}tok {} msgs {} tools passes={passes} (prefix cache ON)",
        system.len() / 4,
        msgs.len(),
        tools_json.len(),
    );

    let load_start = Instant::now();
    let model = ModelBuilder::new(&model_id)
        .with_isq(isq)
        // Prefix caching ON — mirror the live daemon's multi-turn flow so the
        // shared prefix is a cache hit while the tail length sweeps.
        .with_prefix_cache_n(Some(16))
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
        "[prefix_repro] loaded in {:.1}s",
        load_start.elapsed().as_secs_f32()
    );

    let mut any_fail = false;
    for pass in 0..passes {
        // Grow the final user turn a little each pass so the shared prefix
        // (system + tools + earlier turns) is a cache hit while the tail shifts —
        // exactly the live follow-up shape.
        let grow = " more".repeat(pass * 3);
        let mut builder = RequestBuilder::new()
            .set_sampler_max_len(8)
            .set_sampler_topk(160);
        if !system.is_empty() {
            builder = builder.add_message(TextMessageRole::System, &system);
        }
        let last = msgs.len().saturating_sub(1);
        for (mi, m) in msgs.iter().enumerate() {
            let role = role_of(m.get("role").and_then(Value::as_str).unwrap_or("user"));
            let mut content = m
                .get("content")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
            if mi == last {
                content.push_str(&grow);
            }
            builder = builder.add_message(role, &content);
        }
        if !tools_json.is_empty() {
            let mut tools = Vec::new();
            for t in &tools_json {
                let v = serde_json::json!({"type":"function","function":{
                    "name": t.get("name"),"description": t.get("description"),
                    "parameters": t.get("parameters")}});
                tools.push(serde_json::from_value::<Tool>(v)?);
            }
            builder = builder.set_tools(tools).set_tool_choice(ToolChoice::Auto);
        }

        match model.send_chat_request(builder).await {
            Ok(resp) => {
                let cached = resp.usage.prompt_tokens;
                println!(
                    "pass={pass} -> PASS ({} gen tok, prompt_tok={cached})",
                    resp.usage.completion_tokens
                );
            }
            Err(e) => {
                println!("pass={pass} -> FAIL ({})", e.to_string().replace('\n', " "));
                any_fail = true;
            }
        }
    }

    println!("---");
    println!(
        "RESULT: {}",
        if any_fail {
            "FAIL (NaN on a prefix-cache pass)"
        } else {
            "PASS (no NaN across passes)"
        }
    );
    if any_fail {
        std::process::exit(1);
    }
    Ok(())
}
