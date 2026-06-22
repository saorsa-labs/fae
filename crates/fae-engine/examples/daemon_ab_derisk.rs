//! P9/C4 HEADLESS LIVE DE-RISK (manual only — NOT a test, never runs in CI).
//!
//! Proves the two things only real hardware can show about the gguf-lane A/B
//! eval gate (`DaemonABEvaluator`):
//!   1. the real llama.cpp scale-0/1 + reload mechanism A/Bs a real GGUF LoRA
//!      end-to-end and yields a MEASURED per-dimension delta (not "blocked"),
//!   2. the bundled held-out eval set `daemon-ab-eval-v1.json` actually
//!      DISCRIMINATES — a different adapter scores measurably differently, not
//!      identically.
//!
//! Mirrors `examples/llama_reload.rs`. Needs the `~/llama-spike` bench
//! artifacts. Run manually:
//! ```sh
//! env -u RUSTFLAGS cargo run -p fae-engine --example daemon_ab_derisk
//! ```
//! Scoring rules are a faithful port of `DaemonEvalScorer.isCorrect` in
//! `native/macos/Fae/Sources/Fae/Scheduler/DaemonABEvaluator.swift`.

use std::collections::{BTreeMap, BTreeSet};

use fae_engine::{
    ChatEvent, ChatMessage, ChatRequest, LlamaModelSource, LlamaServerAdapter, LlamaServerConfig,
    ProviderAdapter, Role, ToolSpec,
};
use futures_util::StreamExt;
use serde_json::Value;

const EVAL_JSON: &str =
    include_str!("../../../native/macos/Fae/Sources/Fae/Resources/Models/daemon-ab-eval-v1.json");

/// One scored inference: the model's text + any tool calls it emitted.
struct Inference {
    text: String,
    tool_calls: Vec<(String, BTreeSet<String>)>, // (name, arg keys)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let home = std::env::var("HOME")?;

    // Let `reload_adapter`'s confinement accept the bench adapters (they live in
    // ~/llama-spike, not the app's personal-adapters dir). This is the documented
    // FAE_PERSONAL_ADAPTERS_DIR override the daemon honours.
    std::env::set_var("FAE_PERSONAL_ADAPTERS_DIR", format!("{home}/llama-spike"));

    let base = format!("{home}/llama-spike/gguf/gemma-4-E4B-it-Q4_K_M.gguf");
    let metric = format!("{home}/llama-spike/personal-metric.gguf");
    let c2 = format!("{home}/llama-spike/personal-c2.gguf");
    let server = format!("{home}/llama-spike/llama.cpp/build/bin/llama-server");

    let examples = parse_examples(EVAL_JSON)?;
    eprintln!("[derisk] loaded {} eval examples", examples.len());

    // Spawn ONE sidecar: base model + personal-metric loaded but inactive
    // (--lora-init-without-apply). scale 0 = base, scale 1 = personalized — the
    // exact production "portable gate" the design names.
    let config = LlamaServerConfig {
        binary: server,
        model: LlamaModelSource::Local {
            model_gguf: base,
            mmproj: None,
            mtp_draft: None,
        },
        lora_gguf: Some(metric.clone()),
        alias: "gemma-4-e4b".to_owned(),
        enable_thinking: false, // deterministic, fast — no thinking span
        mtp_draft_tokens: None,
        port: 18133,
        ctx_size: 4096,
        ngl: 99,
    };
    eprintln!("[derisk] spawning sidecar (base + personal-metric loaded inactive)…");
    let adapter = LlamaServerAdapter::spawn(config, "gemma-4-e4b").await?;

    // --- Good-candidate A/B via the scale-0/1 portable gate -----------------
    eprintln!("\n[derisk] === PHASE 1: scale-0 BASELINE (base model) ===");
    adapter.set_adapter_scale(0.0)?;
    let baseline = run_suite(&adapter, &examples).await?;
    let base_acc = accuracy_by_dim(&baseline);

    eprintln!("\n[derisk] === PHASE 2: scale-1 CANDIDATE (personal-metric) ===");
    adapter.set_adapter_scale(1.0)?;
    let candidate = run_suite(&adapter, &examples).await?;
    let cand_acc = accuracy_by_dim(&candidate);

    eprintln!("\n[derisk] === GOOD-CANDIDATE A/B (personal-metric scale1 − base scale0) ===");
    print_delta_table(&base_acc, &cand_acc);

    // --- Restore + confirm safety property ----------------------------------
    eprintln!("\n[derisk] === RESTORE: scale back to 0 (base) ===");
    adapter.set_adapter_scale(0.0)?;
    match adapter.loaded_adapter() {
        Some(la) => eprintln!(
            "[derisk] loaded_adapter after restore: path={} scale={} sha={}…",
            la.path,
            la.scale,
            &la.sha256.chars().take(12).collect::<String>()
        ),
        None => eprintln!("[derisk] loaded_adapter after restore: None (base only)"),
    }

    // --- Discrimination: a DIFFERENT adapter via the real reload primitive ---
    // reload_adapter confines + SHA-hashes the path (the untrusted NDJSON path),
    // then restarts the sidecar with --lora personal-c2.gguf.
    eprintln!("\n[derisk] === PHASE 3: reload → personal-c2 (different adapter) ===");
    adapter.reload_adapter(Some(c2.clone())).await?;
    match adapter.loaded_adapter() {
        Some(la) => eprintln!(
            "[derisk] reloaded adapter: path={} sha={}… scale={}",
            la.path,
            &la.sha256.chars().take(12).collect::<String>(),
            la.scale
        ),
        None => eprintln!("[derisk] WARNING: reload reported no loaded adapter"),
    }
    adapter.set_adapter_scale(1.0)?;
    let c2_results = run_suite(&adapter, &examples).await?;
    let c2_acc = accuracy_by_dim(&c2_results);
    eprintln!("\n[derisk] === DISCRIMINATION A/B (personal-c2 scale1 − base scale0) ===");
    print_delta_table(&base_acc, &c2_acc);

    eprintln!("\n[derisk] === SUMMARY (per-dimension accuracy %) ===");
    let mut dims: Vec<&String> = base_acc.keys().collect();
    dims.sort();
    eprintln!(
        "{:<16} {:>10} {:>14} {:>12}",
        "dimension", "base(s0)", "metric(s1)", "c2(s1)"
    );
    for d in &dims {
        eprintln!(
            "{:<16} {:>9.0}% {:>13.0}% {:>11.0}%",
            d,
            base_acc.get(*d).copied().unwrap_or(0.0) * 100.0,
            cand_acc.get(*d).copied().unwrap_or(0.0) * 100.0,
            c2_acc.get(*d).copied().unwrap_or(0.0) * 100.0,
        );
    }

    // Restore to base for a clean exit.
    adapter.reload_adapter(None).await?;
    eprintln!("\n[derisk] restored to base; exit");
    Ok(())
}

// ---------------------------------------------------------------------------
// Eval harness
// ---------------------------------------------------------------------------

struct Example {
    dimension: String,
    system: String,
    prompt: String,
    tools: Vec<ToolSpec>,
    scoring: Value,
}

fn parse_examples(json: &str) -> Result<Vec<Example>, Box<dyn std::error::Error>> {
    let root: Value = serde_json::from_str(json)?;
    let arr = root["examples"]
        .as_array()
        .ok_or("daemon-ab-eval-v1.json missing examples[]")?;
    let mut out = Vec::new();
    for e in arr {
        let tools = e["tools"]
            .as_array()
            .map(|ts| {
                ts.iter()
                    .map(|t| ToolSpec {
                        name: t["name"].as_str().unwrap_or_default().to_owned(),
                        description: t["description"].as_str().unwrap_or_default().to_owned(),
                        parameters: t["parameters"].clone(),
                    })
                    .collect()
            })
            .unwrap_or_default();
        out.push(Example {
            dimension: e["dimension"].as_str().unwrap_or_default().to_owned(),
            system: e["system"].as_str().unwrap_or_default().to_owned(),
            prompt: e["prompt"].as_str().unwrap_or_default().to_owned(),
            tools,
            scoring: e["scoring"].clone(),
        });
    }
    Ok(out)
}

async fn run_suite(
    adapter: &LlamaServerAdapter,
    examples: &[Example],
) -> Result<Vec<(String, bool)>, Box<dyn std::error::Error>> {
    let mut results = Vec::new();
    for (i, ex) in examples.iter().enumerate() {
        let inf = run_one(adapter, ex).await?;
        let correct = is_correct(&inf, &ex.scoring);
        if i == 0 {
            // Show one concrete prompt→output so the run is verifiable.
            eprintln!(
                "  [sample] prompt={:?}\n           text={:?} toolCalls={:?} correct={}",
                ex.prompt,
                inf.text.chars().take(160).collect::<String>(),
                inf.tool_calls.iter().map(|(n, _)| n).collect::<Vec<_>>(),
                correct
            );
        }
        results.push((ex.dimension.clone(), correct));
    }
    Ok(results)
}

async fn run_one(
    adapter: &LlamaServerAdapter,
    ex: &Example,
) -> Result<Inference, Box<dyn std::error::Error>> {
    let request = ChatRequest {
        system: Some(ex.system.clone()),
        messages: vec![ChatMessage::text(Role::User, ex.prompt.clone())],
        tools: ex.tools.clone(),
        max_tokens: 256,
    };
    let mut stream = adapter.stream_chat(request).await?;
    let mut text = String::new();
    let mut tool_calls = Vec::new();
    while let Some(event) = stream.next().await {
        match event? {
            ChatEvent::Token(t) => text.push_str(&t),
            ChatEvent::ToolCall { name, arguments } => {
                let keys: BTreeSet<String> = serde_json::from_str::<Value>(&arguments)
                    .ok()
                    .and_then(|v| v.as_object().map(|o| o.keys().cloned().collect()))
                    .unwrap_or_default();
                tool_calls.push((name, keys));
            }
            ChatEvent::Done { .. } => break,
        }
    }
    Ok(Inference { text, tool_calls })
}

// ---------------------------------------------------------------------------
// Scorer — faithful port of DaemonEvalScorer.isCorrect (Swift)
// ---------------------------------------------------------------------------

fn is_correct(inf: &Inference, scoring: &Value) -> bool {
    let text = inf.text.trim();
    let lower = text.to_lowercase();
    match scoring["type"].as_str().unwrap_or_default() {
        "expectToolCall" => {
            let name = scoring["name"].as_str().unwrap_or_default();
            let Some((_, keys)) = inf.tool_calls.iter().find(|(n, _)| n == name) else {
                return false;
            };
            let required: BTreeSet<String> = scoring["requiredArgs"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default();
            required.is_subset(keys)
        }
        "expectNoToolCall" => inf.tool_calls.is_empty() && !text.is_empty(),
        "expectLinesPrefixed" => {
            let prefix = scoring["prefix"].as_str().unwrap_or_default();
            let min = scoring["minLines"].as_u64().unwrap_or(1) as usize;
            let matching = text
                .lines()
                .map(str::trim)
                .filter(|l| l.starts_with(prefix))
                .count();
            matching >= min
        }
        "expectJSONKeys" => {
            let Some(keys) = scoring["keys"].as_array() else {
                return false;
            };
            let Some(obj) = first_json_object(text) else {
                return false;
            };
            keys.iter()
                .filter_map(|v| v.as_str())
                .all(|k| obj.contains_key(k))
        }
        "expectJSONArray" => {
            let min = scoring["minCount"].as_u64().unwrap_or(1) as usize;
            first_json_array(text).is_some_and(|a| a.len() >= min)
        }
        "expectKeywords" => {
            if contains_forbidden(&lower, scoring) {
                return false;
            }
            let any_of: Vec<String> = scoring["anyOf"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(|s| s.to_lowercase()))
                        .collect()
                })
                .unwrap_or_default();
            if any_of.is_empty() {
                return !text.is_empty();
            }
            any_of.iter().any(|k| lower.contains(k))
        }
        "expectNonEmpty" => !contains_forbidden(&lower, scoring) && !text.is_empty(),
        _ => false,
    }
}

fn contains_forbidden(lower: &str, scoring: &Value) -> bool {
    scoring["forbidden"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str())
                .any(|f| lower.contains(&f.to_lowercase()))
        })
        .unwrap_or(false)
}

fn first_json_object(text: &str) -> Option<serde_json::Map<String, Value>> {
    first_json(text, '{', '}').and_then(|v| v.as_object().cloned())
}

fn first_json_array(text: &str) -> Option<Vec<Value>> {
    first_json(text, '[', ']').and_then(|v| v.as_array().cloned())
}

fn first_json(text: &str, open: char, close: char) -> Option<Value> {
    let start = text.find(open)?;
    let mut depth = 0i32;
    for (offset, ch) in text[start..].char_indices() {
        if ch == open {
            depth += 1;
        } else if ch == close {
            depth -= 1;
            if depth == 0 {
                let slice = &text[start..start + offset + ch.len_utf8()];
                return serde_json::from_str(slice).ok();
            }
        }
    }
    None
}

fn accuracy_by_dim(results: &[(String, bool)]) -> BTreeMap<String, f64> {
    let mut counts: BTreeMap<String, (u32, u32)> = BTreeMap::new();
    for (dim, ok) in results {
        let c = counts.entry(dim.clone()).or_insert((0, 0));
        c.1 += 1;
        if *ok {
            c.0 += 1;
        }
    }
    counts
        .into_iter()
        .map(|(d, (correct, total))| (d, f64::from(correct) / f64::from(total)))
        .collect()
}

fn print_delta_table(base: &BTreeMap<String, f64>, cand: &BTreeMap<String, f64>) {
    eprintln!(
        "{:<16} {:>10} {:>12} {:>10}",
        "dimension", "base%", "cand%", "Δ(pp)"
    );
    let mut dims: BTreeSet<&String> = base.keys().collect();
    dims.extend(cand.keys());
    for d in dims {
        let b = base.get(d).copied().unwrap_or(0.0) * 100.0;
        let c = cand.get(d).copied().unwrap_or(0.0) * 100.0;
        eprintln!("{:<16} {:>9.0}% {:>11.0}% {:>+9.0}", d, b, c, c - b);
    }
}
