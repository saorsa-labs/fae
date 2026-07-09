//! P9/C4 v2 BASE DRY-RUN (manual only — NOT a test, never runs in CI).
//!
//! Phase 2 of the daemon-ab-eval-v2 build: run the BASE model (scale 0, NO
//! adapter) over the 64-item v2 held-out eval set and score each item with a
//! Rust port of the FULL v2 `DaemonEvalScorer.isCorrect`. The goal is to find
//! which items the base model already aces (so they can't discriminate a better
//! adapter) and confirm base lands in a ~60–80% band on the hard dimensions,
//! leaving headroom. This is the validation v1 lacked.
//!
//! Run manually (crate cargo commands REQUIRE `env -u RUSTFLAGS`):
//! ```sh
//! env -u RUSTFLAGS cargo run --release --manifest-path crates/Cargo.toml \
//!   -p fae-engine --example v2_base_dryrun
//! ```
//! Scoring rules are a faithful port of `DaemonEvalScorer.isCorrect` in
//! `native/macos/Fae/Sources/Fae/Scheduler/DaemonABEvaluator.swift` — INCLUDING
//! the v2 arms `expectConcise` (maxChars/maxLines + optional anyOf/allOf) and the
//! `allOf` extension to `expectKeywords`.

use std::collections::{BTreeMap, BTreeSet};

use fae_engine::{
    ChatEvent, ChatMessage, ChatRequest, LlamaModelSource, LlamaServerAdapter, LlamaServerConfig,
    ProviderAdapter, Role, ToolSpec,
};
use futures_util::StreamExt;
use serde_json::Value;

const EVAL_JSON: &str =
    include_str!("../../../native/macos/Fae/Sources/Fae/Resources/Models/daemon-ab-eval-v2.json");

/// One scored inference: the model's text + any tool calls it emitted.
struct Inference {
    text: String,
    tool_calls: Vec<(String, BTreeSet<String>)>, // (name, arg keys)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let home = std::env::var("HOME")?;

    let base = format!("{home}/llama-spike/gguf/gemma-4-E4B-it-Q4_K_M.gguf");
    let server = format!("{home}/llama-spike/llama.cpp/build/bin/llama-server");

    let examples = parse_examples(EVAL_JSON)?;
    eprintln!(
        "[v2-dryrun] loaded {} eval examples (suiteVersion check in JSON)",
        examples.len()
    );

    // Spawn ONE sidecar: BASE model only, NO LoRA. The dry-run measures the base
    // model alone, so there is nothing to scale — scale 0 with no adapter IS the
    // base. (We still call set_adapter_scale(0.0) for parity with the gate path,
    // which is a no-op without a loaded adapter.)
    let config = LlamaServerConfig {
        binary: server,
        model: LlamaModelSource::Local {
            model_gguf: base,
            mmproj: None,
            mtp_draft: None,
        },
        lora_gguf: None,
        alias: "gemma-4-e4b".to_owned(),
        enable_thinking: false, // deterministic, fast — no thinking span
        mtp_draft_tokens: None,
        port: 18134,
        ctx_size: 4096,
        ngl: 99,
        pidfile_root: None,
    };
    eprintln!("[v2-dryrun] spawning sidecar (BASE model, no LoRA)…");
    let adapter = LlamaServerAdapter::spawn(config, "gemma-4-e4b").await?;
    let _ = adapter.set_adapter_scale(0.0); // parity no-op; ignore if no adapter

    eprintln!("\n[v2-dryrun] === BASE-ONLY RUN (scale 0, no adapter) ===");
    let results = run_suite(&adapter, &examples).await?;

    // ---- Machine-readable per-item results (parsed by the analysis step) ----
    eprintln!("\n[v2-dryrun] === PER-ITEM RESULTS (RESULT lines) ===");
    for (ex, correct) in examples.iter().zip(results.iter()) {
        // RESULT <id> <dimension> <CORRECT|WRONG>
        println!(
            "RESULT {} {} {}",
            ex.id,
            ex.dimension,
            if *correct { "CORRECT" } else { "WRONG" }
        );
    }

    // ---- Per-dimension accuracy summary -------------------------------------
    let dim_results: Vec<(String, bool)> = examples
        .iter()
        .zip(results.iter())
        .map(|(ex, c)| (ex.dimension.clone(), *c))
        .collect();
    let acc = accuracy_by_dim(&dim_results);
    eprintln!("\n[v2-dryrun] === PER-DIMENSION BASE ACCURACY ===");
    eprintln!("{:<16} {:>8} {:>8}", "dimension", "correct", "acc%");
    let mut dims: Vec<&String> = acc.keys().collect();
    dims.sort();
    for d in &dims {
        let (correct, total) = dim_count(&dim_results, d);
        eprintln!(
            "{:<16} {:>4}/{:<3} {:>7.0}%",
            d,
            correct,
            total,
            acc.get(*d).copied().unwrap_or(0.0) * 100.0
        );
    }
    println!("ACCSUMMARY START");
    for d in &dims {
        let (correct, total) = dim_count(&dim_results, d);
        println!("ACC {d} {correct} {total}");
    }
    println!("ACCSUMMARY END");

    eprintln!("\n[v2-dryrun] base dry-run complete; exit");
    Ok(())
}

// ---------------------------------------------------------------------------
// Eval harness
// ---------------------------------------------------------------------------

struct Example {
    id: String,
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
        .ok_or("daemon-ab-eval-v2.json missing examples[]")?;
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
            id: e["id"].as_str().unwrap_or_default().to_owned(),
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
) -> Result<Vec<bool>, Box<dyn std::error::Error>> {
    let mut results = Vec::new();
    for (i, ex) in examples.iter().enumerate() {
        let inf = run_one(adapter, ex).await?;
        let correct = is_correct(&inf, &ex.scoring);
        // Show a concrete prompt→output for the first item per dimension so the
        // run is verifiable (real inference ran, not fabricated).
        if i == 0
            || (i < examples.len() && examples[..i].iter().all(|p| p.dimension != ex.dimension))
        {
            eprintln!(
                "  [sample {}] dim={} prompt={:?}\n           text={:?} toolCalls={:?} -> {}",
                ex.id,
                ex.dimension,
                ex.prompt.chars().take(120).collect::<String>(),
                inf.text.chars().take(160).collect::<String>(),
                inf.tool_calls.iter().map(|(n, _)| n).collect::<Vec<_>>(),
                if correct { "CORRECT" } else { "WRONG" }
            );
        }
        results.push(correct);
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
// Scorer — faithful port of DaemonEvalScorer.isCorrect (Swift), v2 arms included
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
            let required: BTreeSet<String> = string_array(scoring, "requiredArgs");
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
            // v2 `allOf`: EVERY listed substring must be present. When both `allOf`
            // and `anyOf` are given, require all-of AND at least one any-of.
            let all_of = lower_array(scoring, "allOf");
            if !all_of.is_empty() && !all_of.iter().all(|k| lower.contains(k)) {
                return false;
            }
            let any_of = lower_array(scoring, "anyOf");
            if any_of.is_empty() {
                // No anyOf: pass on a satisfied allOf (above) or a non-empty answer.
                return !text.is_empty();
            }
            any_of.iter().any(|k| lower.contains(k))
        }
        "expectConcise" => {
            // Deterministic brevity check: a forbidden phrase still hard-fails, then
            // the answer must be non-empty and within the char/line bounds given.
            if contains_forbidden(&lower, scoring) {
                return false;
            }
            if text.is_empty() {
                return false;
            }
            if let Some(max_chars) = scoring["maxChars"].as_u64() {
                // Swift `text.count` counts Characters (grapheme clusters).
                if text.chars().count() > max_chars as usize {
                    return false;
                }
            }
            if let Some(max_lines) = scoring["maxLines"].as_u64() {
                let lines = text
                    .lines()
                    .map(str::trim)
                    .filter(|l| !l.is_empty())
                    .count();
                if lines > max_lines as usize {
                    return false;
                }
            }
            // v2: expectConcise may also assert keyword presence so a concise-but-
            // wrong answer fails — brevity alone is not correctness.
            let all_of = lower_array(scoring, "allOf");
            if !all_of.is_empty() && !all_of.iter().all(|k| lower.contains(k)) {
                return false;
            }
            let any_of = lower_array(scoring, "anyOf");
            if !any_of.is_empty() && !any_of.iter().any(|k| lower.contains(k)) {
                return false;
            }
            true
        }
        "expectNonEmpty" => !contains_forbidden(&lower, scoring) && !text.is_empty(),
        _ => false,
    }
}

/// Lowercased string array from a scoring field (for case-insensitive matching).
fn lower_array(scoring: &Value, key: &str) -> Vec<String> {
    scoring[key]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_lowercase()))
                .collect()
        })
        .unwrap_or_default()
}

/// As-written string set from a scoring field (tool arg keys are case-sensitive).
fn string_array(scoring: &Value, key: &str) -> BTreeSet<String> {
    scoring[key]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
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

fn dim_count(results: &[(String, bool)], dim: &str) -> (u32, u32) {
    let mut correct = 0;
    let mut total = 0;
    for (d, ok) in results {
        if d == dim {
            total += 1;
            if *ok {
                correct += 1;
            }
        }
    }
    (correct, total)
}
