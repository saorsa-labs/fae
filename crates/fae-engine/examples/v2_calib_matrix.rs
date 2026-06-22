//! P9/C4 v2 CALIBRATION MATRIX (manual only — NOT a test, never runs in CI).
//!
//! Phase 4 of the daemon-ab-eval-v2 build: decide whether the v2 eval set is
//! TRUSTWORTHY as a deploy gate, using only BASE + ONE known-good adapter (no
//! separately-trained bad adapter is needed). The 64-item suite is scored ONCE
//! under BASE (scale 0) and ONCE under the GOOD adapter (reload + scale 1); those
//! two per-dimension accuracy vectors are reused to synthesise three fixtures by
//! choosing which is the candidate and which is the baseline:
//!
//!   - GOOD = candidate GOOD vs baseline BASE  → must IMPROVE  → `.pass`
//!   - BAD  = candidate BASE vs baseline GOOD  (roles swapped) → must REGRESS → `.fail`
//!   - NULL = base vs base                     → all-flat      → `.blockedNoMeasurement`
//!
//! Each fixture's per-dimension delta = candidate − baseline (percentage points).
//! The gate decision is a faithful Rust port of `AdapterGate.decide` in
//! `native/macos/Fae/Sources/Fae/Memory/ExternalReviewGate.swift`.
//!
//! The scorer is REUSED verbatim from the v2 base dry-run, so the deltas this
//! harness computes are scored exactly as the dry-run scores BASE — and as
//! faithfully to production Swift `DaemonEvalScorer.isCorrect` as that port is.
//!
//! Build (crate cargo commands REQUIRE `env -u RUSTFLAGS`):
//! ```sh
//! env -u RUSTFLAGS cargo build --release --manifest-path crates/Cargo.toml \
//!   -p fae-engine --example v2_calib_matrix
//! ```
//! Run the real matrix (needs the known-good adapter to exist):
//! ```sh
//! env -u RUSTFLAGS cargo run --release --manifest-path crates/Cargo.toml \
//!   -p fae-engine --example v2_calib_matrix -- \
//!   <BASE_gguf> <GOOD_adapter_gguf>
//! ```
//! Args (both optional; CLI overrides env overrides default):
//!   argv[1] / FAE_CALIB_BASE  — BASE model gguf (default: the dry-run base)
//!   argv[2] / FAE_CALIB_GOOD  — known-good adapter gguf
//!                               (default: ~/llama-spike/personal-v2-calib-good.gguf)
//!
//! Exits NON-ZERO if the acceptance checks fail, so it is a real gate.

use std::collections::{BTreeMap, BTreeSet};

use fae_engine::{
    ChatEvent, ChatMessage, ChatRequest, LlamaModelSource, LlamaServerAdapter, LlamaServerConfig,
    ProviderAdapter, Role, ToolSpec,
};
use futures_util::StreamExt;
use serde_json::Value;

const EVAL_JSON: &str =
    include_str!("../../../native/macos/Fae/Sources/Fae/Resources/Models/daemon-ab-eval-v2.json");

/// The four gate dimensions, in `GateDimension.allCases` order. A delta vector is
/// only a COMPLETE measurement when all four are present (matches the Swift gate).
const GATE_DIMENSIONS: [&str; 4] = [
    "toolCalling",
    "faeCapability",
    "assistantFit",
    "serialization",
];

/// One scored inference: the model's text + any tool calls it emitted.
struct Inference {
    text: String,
    tool_calls: Vec<(String, BTreeSet<String>)>, // (name, arg keys)
}

/// A fixture's per-dimension delta (percentage points; candidate − baseline) plus
/// the gate decision over it.
struct Fixture {
    name: &'static str,
    /// delta per dimension, in `GATE_DIMENSIONS` order; `None` = dimension absent.
    deltas: BTreeMap<String, f64>,
    decision: GateDecision,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let home = std::env::var("HOME")?;

    // ---- Resolve artifact paths (CLI > env > default) -----------------------
    let args: Vec<String> = std::env::args().skip(1).collect();
    let base = args
        .first()
        .cloned()
        .or_else(|| std::env::var("FAE_CALIB_BASE").ok())
        .unwrap_or_else(|| format!("{home}/llama-spike/gguf/gemma-4-E4B-it-Q4_K_M.gguf"));
    let good = args
        .get(1)
        .cloned()
        .or_else(|| std::env::var("FAE_CALIB_GOOD").ok())
        .unwrap_or_else(|| format!("{home}/llama-spike/personal-v2-calib-good.gguf"));
    let server = format!("{home}/llama-spike/llama.cpp/build/bin/llama-server");

    eprintln!("[v2-calib] BASE  = {base}");
    eprintln!("[v2-calib] GOOD  = {good}");

    let examples = parse_examples(EVAL_JSON)?;
    eprintln!("[v2-calib] loaded {} eval examples", examples.len());

    // Spawn ONE sidecar on the BASE model. The GOOD adapter is loaded later via
    // `reload_adapter` so we A/B without restarting the harness. Start at scale 0
    // for the BASE measurement.
    let config = LlamaServerConfig {
        binary: server,
        model: LlamaModelSource::Local {
            model_gguf: base,
            mmproj: None,
            mtp_draft: None,
        },
        lora_gguf: None,
        alias: "gemma-4-e4b".to_owned(),
        enable_thinking: false,
        mtp_draft_tokens: None,
        port: 18135,
        ctx_size: 4096,
        ngl: 99,
    };
    eprintln!("[v2-calib] spawning sidecar (BASE model, no LoRA)…");
    let adapter = LlamaServerAdapter::spawn(config, "gemma-4-e4b").await?;

    // ---- Measurement 1: BASE (scale 0, no adapter) --------------------------
    let _ = adapter.set_adapter_scale(0.0);
    eprintln!("\n[v2-calib] === BASE RUN (scale 0, no adapter) ===");
    let base_results = run_suite(&adapter, &examples).await?;
    let base_acc = accuracy_by_dim(&dim_pairs(&examples, &base_results));

    // ---- Measurement 2: GOOD (reload adapter + scale 1) ---------------------
    eprintln!("\n[v2-calib] === reload_adapter(GOOD) + scale 1 ===");
    adapter.reload_adapter(Some(good.clone())).await?;
    adapter.set_adapter_scale(1.0)?;
    match adapter.loaded_adapter() {
        Some(la) => eprintln!(
            "[v2-calib] loaded_adapter: path={} sha256={} scale={}",
            la.path, la.sha256, la.scale
        ),
        None => return Err("GOOD adapter reload reported no loaded_adapter".into()),
    }
    eprintln!("\n[v2-calib] === GOOD RUN (scale 1, GOOD adapter) ===");
    let good_results = run_suite(&adapter, &examples).await?;
    let good_acc = accuracy_by_dim(&dim_pairs(&examples, &good_results));

    // ---- Restore to base and confirm ----------------------------------------
    eprintln!("\n[v2-calib] === restore: reload base + scale 0 ===");
    adapter.reload_adapter(None).await?;
    let _ = adapter.set_adapter_scale(0.0);
    match adapter.loaded_adapter() {
        None => eprintln!("[v2-calib] restored: loaded_adapter == base (None) ✓"),
        Some(la) => {
            return Err(format!(
                "restore failed: loaded_adapter still present (path={})",
                la.path
            )
            .into())
        }
    }

    // ---- Build the three fixtures from the two accuracy vectors --------------
    // Accuracy is in [0,1]; deltas are in PERCENTAGE POINTS to match the Swift
    // gate's −5.0 / 0.0 thresholds (which operate on pp).
    let good_fixture = make_fixture("GOOD", &good_acc, &base_acc); // candidate GOOD vs base BASE
    let bad_fixture = make_fixture("BAD", &base_acc, &good_acc); // candidate BASE vs base GOOD
    let null_fixture = make_fixture("NULL", &base_acc, &base_acc); // base vs base

    let fixtures = [&good_fixture, &bad_fixture, &null_fixture];

    // ---- Report -------------------------------------------------------------
    let base_label = base_path(&args, &home);
    let mut report = String::new();
    report.push_str("# P9/C4 v2 calibration matrix\n\n");
    report.push_str(&format!("BASE = `{base_label}`\n\n"));
    report.push_str(&format!("GOOD = `{good}`\n\n"));

    report.push_str("## Per-dimension accuracy (correct / 16)\n\n");
    report.push_str("| dimension | BASE acc% | GOOD acc% |\n|---|---:|---:|\n");
    for d in GATE_DIMENSIONS {
        report.push_str(&format!(
            "| {d} | {:.1} | {:.1} |\n",
            base_acc.get(d).copied().unwrap_or(0.0) * 100.0,
            good_acc.get(d).copied().unwrap_or(0.0) * 100.0,
        ));
    }
    report.push('\n');

    report.push_str("## Per-fixture per-dimension delta (pp) + gate decision\n\n");
    report.push_str(
        "| fixture | toolCalling | faeCapability | assistantFit | serialization | decision |\n",
    );
    report.push_str("|---|---:|---:|---:|---:|---|\n");
    for f in fixtures {
        report.push_str(&format!("| {} ", f.name));
        for d in GATE_DIMENSIONS {
            match f.deltas.get(d) {
                Some(v) => report.push_str(&format!("| {:+.1} ", v)),
                None => report.push_str("| — "),
            }
        }
        report.push_str(&format!("| `{}` |\n", f.decision.as_str()));
    }
    report.push('\n');

    // ---- Acceptance checks --------------------------------------------------
    let good_max = max_delta(&good_fixture.deltas);
    let bad_max = max_delta(&bad_fixture.deltas);
    let bad_min = min_delta(&bad_fixture.deltas);

    // GOOD: .pass AND ≥ +12.5pp on toolCalling or serialization.
    let good_decision_ok = good_fixture.decision == GateDecision::Pass;
    let good_lift = good_fixture
        .deltas
        .get("toolCalling")
        .copied()
        .unwrap_or(f64::MIN)
        .max(
            good_fixture
                .deltas
                .get("serialization")
                .copied()
                .unwrap_or(f64::MIN),
        );
    let good_lift_ok = good_lift >= 12.5;
    let good_ok = good_decision_ok && good_lift_ok;

    // BAD: .fail (≤ −5pp on some dim).
    let bad_ok = bad_fixture.decision == GateDecision::Fail;

    // NULL: .blockedNoMeasurement.
    let null_ok = null_fixture.decision == GateDecision::BlockedNoMeasurement;

    // SEPARATION: (GOOD max-dim) − (BAD max-dim) ≥ 25pp.
    let separation = good_max - bad_max;
    let separation_ok = separation >= 25.0;

    let overall = good_ok && bad_ok && null_ok && separation_ok;

    report.push_str("## Acceptance checks\n\n");
    report.push_str(&format!(
        "- GOOD → `.pass` AND ≥+12.5pp on toolCalling|serialization: **{}** (decision={}, best-lift={:+.1}pp)\n",
        pass_fail(good_ok),
        good_fixture.decision.as_str(),
        good_lift,
    ));
    report.push_str(&format!(
        "- BAD → `.fail` (≤−5pp on some dim): **{}** (decision={}, min-delta={:+.1}pp)\n",
        pass_fail(bad_ok),
        bad_fixture.decision.as_str(),
        bad_min,
    ));
    report.push_str(&format!(
        "- NULL → `.blockedNoMeasurement`: **{}** (decision={})\n",
        pass_fail(null_ok),
        null_fixture.decision.as_str(),
    ));
    report.push_str(&format!(
        "- SEPARATION ≥25pp (GOOD max {:+.1} − BAD max {:+.1} = {:+.1}pp): **{}**\n",
        good_max,
        bad_max,
        separation,
        pass_fail(separation_ok),
    ));
    report.push_str(&format!("\n## Overall: **{}**\n", pass_fail(overall)));

    print!("{report}");
    if let Err(e) = std::fs::write("/tmp/v2-p4-matrix.md", &report) {
        eprintln!("[v2-calib] WARNING: could not write /tmp/v2-p4-matrix.md: {e}");
    } else {
        eprintln!("[v2-calib] wrote /tmp/v2-p4-matrix.md");
    }

    if overall {
        eprintln!("[v2-calib] ACCEPTANCE PASS — v2 eval set is calibrated");
        Ok(())
    } else {
        eprintln!("[v2-calib] ACCEPTANCE FAIL — v2 eval set did not separate good from bad");
        std::process::exit(1);
    }
}

/// Resolve the BASE path label for the report (mirrors main's resolution).
fn base_path(args: &[String], home: &str) -> String {
    args.first()
        .cloned()
        .or_else(|| std::env::var("FAE_CALIB_BASE").ok())
        .unwrap_or_else(|| format!("{home}/llama-spike/gguf/gemma-4-E4B-it-Q4_K_M.gguf"))
}

fn pass_fail(ok: bool) -> &'static str {
    if ok {
        "PASS"
    } else {
        "FAIL"
    }
}

/// Maximum delta across the present dimensions (best improvement). `MIN` if empty.
fn max_delta(deltas: &BTreeMap<String, f64>) -> f64 {
    deltas.values().copied().fold(f64::MIN, f64::max)
}

/// Minimum delta across the present dimensions (worst regression). `MAX` if empty.
fn min_delta(deltas: &BTreeMap<String, f64>) -> f64 {
    deltas.values().copied().fold(f64::MAX, f64::min)
}

/// Build a fixture: candidate − baseline per dimension (in pp), gated by the
/// faithful `AdapterGate.decide` port.
fn make_fixture(
    name: &'static str,
    candidate: &BTreeMap<String, f64>,
    baseline: &BTreeMap<String, f64>,
) -> Fixture {
    let mut deltas: BTreeMap<String, f64> = BTreeMap::new();
    for d in GATE_DIMENSIONS {
        // accuracy is [0,1]; both vectors carry every dimension (16 items each),
        // so both lookups succeed in practice. Absent ⇒ dimension excluded, which
        // the gate treats as an incomplete measurement.
        if let (Some(c), Some(b)) = (candidate.get(d), baseline.get(d)) {
            deltas.insert(d.to_owned(), (c - b) * 100.0);
        }
    }
    let decision = gate_decide(&deltas);
    Fixture {
        name,
        deltas,
        decision,
    }
}

// ---------------------------------------------------------------------------
// Gate — faithful Rust port of AdapterGate.decide (ExternalReviewGate.swift)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GateDecision {
    Pass,
    Concern,
    Fail,
    BlockedNoMeasurement,
}

impl GateDecision {
    fn as_str(self) -> &'static str {
        match self {
            GateDecision::Pass => "pass",
            GateDecision::Concern => "concern",
            GateDecision::Fail => "fail",
            GateDecision::BlockedNoMeasurement => "blockedNoMeasurement",
        }
    }
}

/// Faithful port of `AdapterGate.decide` (`ExternalReviewGate.swift:386`):
/// - require ALL four correctness dimensions present, else `.blockedNoMeasurement`
/// - any dim < −5.0 ⇒ `.fail`
/// - any dim < 0.0  ⇒ `.concern`
/// - any dim > 0.0  ⇒ `.pass`
/// - all flat       ⇒ `.blockedNoMeasurement`
fn gate_decide(deltas: &BTreeMap<String, f64>) -> GateDecision {
    let values: Vec<f64> = GATE_DIMENSIONS
        .iter()
        .filter_map(|d| deltas.get(*d).copied())
        .collect();
    if values.len() != GATE_DIMENSIONS.len() {
        return GateDecision::BlockedNoMeasurement;
    }
    if values.iter().any(|v| *v < -5.0) {
        return GateDecision::Fail;
    }
    if values.iter().any(|v| *v < 0.0) {
        return GateDecision::Concern;
    }
    if values.iter().any(|v| *v > 0.0) {
        return GateDecision::Pass;
    }
    GateDecision::BlockedNoMeasurement
}

// ---------------------------------------------------------------------------
// Eval harness (item loading, inference, scoring) — reused from v2_base_dryrun
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

/// Pair each example's dimension with its scored result (for accuracy_by_dim).
fn dim_pairs(examples: &[Example], results: &[bool]) -> Vec<(String, bool)> {
    examples
        .iter()
        .zip(results.iter())
        .map(|(ex, c)| (ex.dimension.clone(), *c))
        .collect()
}

async fn run_suite(
    adapter: &LlamaServerAdapter,
    examples: &[Example],
) -> Result<Vec<bool>, Box<dyn std::error::Error>> {
    let mut results = Vec::new();
    for (i, ex) in examples.iter().enumerate() {
        let inf = run_one(adapter, ex).await?;
        let correct = is_correct(&inf, &ex.scoring);
        if i == 0
            || (i < examples.len() && examples[..i].iter().all(|p| p.dimension != ex.dimension))
        {
            eprintln!(
                "  [sample {}] dim={} -> {}",
                ex.id,
                ex.dimension,
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
// (kept byte-for-byte identical to v2_base_dryrun so both harnesses score the
// same way).
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
            let all_of = lower_array(scoring, "allOf");
            if !all_of.is_empty() && !all_of.iter().all(|k| lower.contains(k)) {
                return false;
            }
            let any_of = lower_array(scoring, "anyOf");
            if any_of.is_empty() {
                return !text.is_empty();
            }
            any_of.iter().any(|k| lower.contains(k))
        }
        "expectConcise" => {
            if contains_forbidden(&lower, scoring) {
                return false;
            }
            if text.is_empty() {
                return false;
            }
            if let Some(max_chars) = scoring["maxChars"].as_u64() {
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
