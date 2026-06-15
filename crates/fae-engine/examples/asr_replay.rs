//! Deterministic replay of a captured daemon audio payload (`FAE_DUMP_REQUESTS`
//! JSON) straight through mistral.rs, mirroring the daemon's load + request
//! construction (ISQ Q4K, 32K auto device-map, audio via `add_audio_message`,
//! tools). Loads the model ONCE and replays a matrix of content overrides so we
//! can compare "empty user text" (the live failure) against a fix candidate
//! without sampling noise reloading the model each time.
//!
//! Run:
//!   FAE_MODEL_ID=google/gemma-4-E4B-it \
//!     cargo run --release -p fae-engine --example asr_replay -- \
//!     --payload /tmp/fae-dumps/inject-….json
//!
//! Flags:
//!   --payload <path>   captured inject_text JSON {system,messages,tools,max_tokens}
//!   --greedy           deterministic (argmax) sampling — reproducible
//!   --content <text>   override the empty audio-message content (the fix);
//!                      repeatable to try several wordings in one load
//!   --repeat <n>       run each condition n times (variance under prod sampling)

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
fn arg_many(flag: &str) -> Vec<String> {
    let a = args();
    a.iter()
        .enumerate()
        .filter(|(_, x)| x.as_str() == flag)
        .filter_map(|(i, _)| a.get(i + 1).cloned())
        .collect()
}
fn has_flag(flag: &str) -> bool {
    args().iter().any(|x| x == flag)
}

fn role_of(s: &str) -> TextMessageRole {
    match s {
        "system" => TextMessageRole::System,
        "assistant" => TextMessageRole::Assistant,
        "tool" => TextMessageRole::Tool,
        _ => TextMessageRole::User,
    }
}

#[tokio::main]
async fn main() -> Result<(), BoxErr> {
    let model_id = std::env::var("FAE_MODEL_ID").unwrap_or_else(|_| "google/gemma-4-E4B-it".into());
    let payload_path = arg1("--payload", "");
    if payload_path.is_empty() {
        return Err("--payload <path> required".into());
    }
    let greedy = has_flag("--greedy");
    let repeat: usize = arg1("--repeat", "1").parse().unwrap_or(1);
    let max_seq_len: usize = arg1("--max-seq-len", "32768").parse().unwrap_or(32768);
    // Swap the dumped audio clip for a fresh known WAV (avoids the exact
    // NaN-triggering total length of a captured payload while keeping the real
    // system prompt + tools). `--only-last` drops the failure-history messages.
    let wav_override = arg1("--wav", "");
    let only_last = has_flag("--only-last");
    // Append N filler tokens to the system prompt to shift total length out of
    // the NaN window (replicates the daemon's padded-retry cure for offline
    // observation of the real generation).
    let padsys: usize = arg1("--padsys", "0").parse().unwrap_or(0);

    let payload: Value = serde_json::from_slice(&std::fs::read(&payload_path)?)?;
    let pl = payload.get("payload").unwrap_or(&payload);
    let system_base = pl.get("system").and_then(Value::as_str).unwrap_or("");
    let system_owned;
    let system: &str = if padsys > 0 {
        system_owned = format!("{system_base}\n{}", " padding".repeat(padsys));
        &system_owned
    } else {
        system_base
    };
    let max_tokens = pl.get("max_tokens").and_then(Value::as_u64).unwrap_or(4096) as usize;
    let mut msgs = pl
        .get("messages")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if only_last {
        // Keep only the final (audio) user message.
        if let Some(last) = msgs.pop() {
            msgs = vec![last];
        }
    }
    // Optionally replace the final message's audio clip with a fresh WAV.
    let fresh_wav_b64: Option<String> = if wav_override.is_empty() {
        None
    } else {
        Some(base64::engine::general_purpose::STANDARD.encode(std::fs::read(&wav_override)?))
    };
    let tools_json = pl
        .get("tools")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    eprintln!(
        "[replay] system ~{} tok, {} msgs, {} tools, max_tokens={}",
        system.len() / 4,
        msgs.len(),
        tools_json.len(),
        max_tokens
    );

    // Build the conditions: the original empty content, plus each --content override.
    let mut conditions: Vec<Option<String>> = vec![None]; // None = leave content as-is
    for c in arg_many("--content") {
        conditions.push(Some(c));
    }

    let load_start = Instant::now();
    let model = ModelBuilder::new(&model_id)
        .with_isq(IsqType::Q4K)
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
        "[replay] loaded in {:.1}s",
        load_start.elapsed().as_secs_f32()
    );

    // --twostep: mirror the Swift DaemonLLMEngine two-pass audio flow on the
    // real payload. Pass 1 = transcription only (no tools); pass 2 = reason on
    // the transcript text (no audio, tools enabled, [heard] contract stripped).
    if has_flag("--twostep") {
        let audio_b64 = fresh_wav_b64.clone().unwrap_or_else(|| {
            msgs.last()
                .and_then(|m| m.get("audio_wav_base64"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned()
        });
        let audio = base64::engine::general_purpose::STANDARD.decode(&audio_b64)?;

        // Pass 1 — transcribe.
        let mut b1 = RequestBuilder::new()
            .set_sampler_max_len(256)
            .set_deterministic_sampler()
            .add_message(
                TextMessageRole::System,
                "Transcribe the user's audio. Output only the exact words spoken — \
                 no labels, quotation marks, preamble, or commentary. If nothing is \
                 said, output nothing.",
            );
        b1 = b1.add_audio_message(
            TextMessageRole::User,
            "",
            vec![AudioInput::from_bytes(&audio)?],
        );
        let r1 = model.send_chat_request(b1).await?;
        let transcript = r1.choices[0]
            .message
            .content
            .clone()
            .unwrap_or_default()
            .replace('\n', " ")
            .trim()
            .to_owned();
        println!("\n##### PASS 1 (transcribe) #####");
        println!("transcript: {transcript:?}");

        // Pass 2 — reason on the transcript as text. Strip the [heard] contract.
        let mut reason_system = match system.find("The user's message arrives as audio") {
            Some(i) => system[..i].trim_end().to_owned(),
            None => system.to_owned(),
        };
        // Pad pass-2 directly to dodge the NaN window for offline observation
        // (production: the daemon's padded-retry covers this).
        if padsys > 0 {
            reason_system.push('\n');
            reason_system.push_str(&" padding".repeat(padsys));
        }
        let mut b2 = RequestBuilder::new()
            .set_sampler_max_len(max_tokens)
            .set_deterministic_sampler()
            .add_message(TextMessageRole::System, &reason_system)
            .add_message(TextMessageRole::User, &transcript);
        if !tools_json.is_empty() {
            let mut tools = Vec::new();
            for t in &tools_json {
                let v = serde_json::json!({"type":"function","function":{
                    "name": t.get("name"),"description": t.get("description"),
                    "parameters": t.get("parameters")}});
                tools.push(serde_json::from_value::<Tool>(v)?);
            }
            b2 = b2.set_tools(tools).set_tool_choice(ToolChoice::Auto);
        }
        let r2 = model.send_chat_request(b2).await?;
        let ans = r2.choices[0].message.content.clone().unwrap_or_default();
        let calls = r2.choices[0]
            .message
            .tool_calls
            .as_ref()
            .map(|c| {
                c.iter()
                    .map(|x| format!("{}({})", x.function.name, x.function.arguments))
                    .collect::<Vec<_>>()
                    .join(",")
            })
            .unwrap_or_default();
        println!("\n##### PASS 2 (reason on text) #####");
        println!("answer: {ans:?}");
        println!("tool_calls: [{calls}]");
        println!("\n##### COMBINED (what the pipeline receives) #####");
        let body = ans.trim();
        if body.is_empty() {
            println!("[heard]: {transcript}");
        } else {
            println!("[heard]: {transcript}\n{body}");
        }
        return Ok(());
    }

    for cond in &conditions {
        let label = match cond {
            None => "<as-is empty content>".to_owned(),
            Some(c) => format!("content={c:?}"),
        };
        for r in 0..repeat {
            let mut builder = RequestBuilder::new().set_sampler_max_len(max_tokens);
            builder = if greedy {
                builder.set_deterministic_sampler()
            } else {
                // Mirror the production build_request: topk=160 forces CPU sampling.
                builder.set_sampler_topk(160)
            };
            if has_flag("--no-think") {
                builder = builder.enable_thinking(false);
            } else if has_flag("--think") {
                builder = builder.enable_thinking(true);
            }
            if !system.is_empty() {
                builder = builder.add_message(TextMessageRole::System, system);
            }
            let last = msgs.len().saturating_sub(1);
            for (i, m) in msgs.iter().enumerate() {
                let role = role_of(m.get("role").and_then(Value::as_str).unwrap_or("user"));
                let mut content = m
                    .get("content")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                let mut audio_b64 = m
                    .get("audio_wav_base64")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                if i == last {
                    if let Some(fresh) = &fresh_wav_b64 {
                        audio_b64 = Some(fresh.clone());
                    }
                }
                let audio_b64 = audio_b64.as_deref();
                // Apply the content override to the final audio-bearing message.
                if i == last {
                    if let (Some(c), Some(_)) = (cond, audio_b64) {
                        content = c.clone();
                    }
                }
                builder = match audio_b64 {
                    Some(b64) if !b64.is_empty() => {
                        let bytes = base64::engine::general_purpose::STANDARD.decode(b64)?;
                        let clip = AudioInput::from_bytes(&bytes)?;
                        builder.add_audio_message(role, &content, vec![clip])
                    }
                    _ => builder.add_message(role, &content),
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

            let t0 = Instant::now();
            let resp = model.send_chat_request(builder).await?;
            let secs = t0.elapsed().as_secs_f32();
            let choice = &resp.choices[0];
            let text = choice.message.content.clone().unwrap_or_default();
            let calls = choice
                .message
                .tool_calls
                .as_ref()
                .map(|c| {
                    c.iter()
                        .map(|x| format!("{}({})", x.function.name, x.function.arguments))
                        .collect::<Vec<_>>()
                        .join(",")
                })
                .unwrap_or_default();
            println!(
                "\n##### {label} [run {}/{repeat}] sampler={} #####",
                r + 1,
                if greedy { "greedy" } else { "topk160" }
            );
            println!(
                "tokens={} tps={:.2} secs={:.1} tool_calls=[{}]",
                resp.usage.completion_tokens, resp.usage.avg_compl_tok_per_sec, secs, calls
            );
            println!("REPLY: {text:?}");
            if let Some(rc) = &choice.message.reasoning_content {
                println!("REASONING: {rc:?}");
            }
            println!("finish_reason: {:?}", choice.finish_reason);
        }
    }
    Ok(())
}
