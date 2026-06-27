//! Fae headless-core daemon — **Phase 1, chunk 2a**.
//!
//! Control-plane-first: every byte a client sends is routed through
//! [`fae_control_plane`]. Chunk 1 built + tested the transport-free
//! authorization core; chunk 2a adds the **Unix-domain-socket** transport
//! (NDJSON), per-connection token authentication, per-message `authorize`, a
//! read-only command dispatch stub, and fail-closed audit. No TCP port is
//! opened — TCP-loopback + WS/SSE diagnostics with single-use stream tickets
//! are chunk 2c; the mistral.rs engine adapter is chunk 3.
//!
//! Run: `cargo run -p fae-daemon`. It bootstraps a private run dir + token,
//! then serves the socket until killed.
#![forbid(unsafe_code)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use fae_audio::AudioManager;
use fae_control_plane::{
    generate_token, hash_token, ClientClass, ClientRecord, ClientRegistry, TicketStore,
    PROTOCOL_VERSION,
};
use fae_engine::{
    kill_all_registered_sidecars, LazyLlamaServerAdapter, LlamaModelSource, LlamaServerAdapter,
    LlamaServerConfig, MockTtsAdapter, ModelsLock, ProviderAdapter, RemoteModelArtifact,
    TtsAdapter,
};

mod agents;
mod conductor;
mod diagnostic;
mod events;
mod offline_turn;
mod server_request;
mod session;
mod transport;

const THIRTY_DAYS_MS: u64 = 30 * 24 * 60 * 60 * 1000;

type DaemonResult<T> = Result<T, Box<dyn std::error::Error>>;

#[tokio::main]
async fn main() -> DaemonResult<()> {
    if std::env::args().any(|arg| arg == "--version") {
        println!(
            "fae-daemon {} — protocol v{PROTOCOL_VERSION}",
            env!("CARGO_PKG_VERSION")
        );
        return Ok(());
    }

    // Headless offline voice-turn driver (P5/D2-V5, Stage 3): clip → STT → LLM →
    // Piper TTS → spoken-answer WAV, with NO socket and NO audio device. This is
    // the CI-verifiable proof of the full Linux spine. It builds the same real
    // backends the server uses, then exits.
    let mut args = std::env::args().skip(1);
    if let Some(pos) = args.position(|arg| arg == "--offline-turn") {
        // Re-derive the args after the flag (position() consumed up to it).
        let rest = std::env::args().skip(1 + pos + 1);
        let parsed = offline_turn::OfflineTurnArgs::parse(rest)?;
        let tts = build_tts_engine();
        // Backend selection by mode:
        // - tts-only WITHOUT round-trip: no STT engine (cheapest Piper gate).
        // - tts-only WITH round-trip: build ONLY the Qwen3-ASR fallback (~2.5GB,
        //   no Gemma) — the round-trip transcribes the synth WAV to prove Piper
        //   intelligibility; re-proving the full LLM isn't the point.
        // - full turn: build all three real backends, as the server does.
        let (engine, asr_fallback) = if parsed.tts_text.is_some() {
            if parsed.roundtrip {
                (None, build_asr_fallback_engine())
            } else {
                (None, None)
            }
        } else {
            (Some(build_engine().await), build_asr_fallback_engine())
        };
        offline_turn::run(parsed, engine, asr_fallback, tts).await?;
        return Ok(());
    }

    // M3-C4: offline recipe-mutation CLI (`conductor metaopt-run --recipe ...`).
    // Same pattern as `--offline-turn`: a manual-args early branch that exits
    // before the server/runtime starts. The ONLY production construction site
    // for DaemonConductorRecipePort. Human-in-the-loop: apply requires `--yes`.
    // Mutation stays offline/CLI-only; NO scheduler / executor / session wiring.
    {
        let argv: Vec<String> = std::env::args().skip(1).collect();
        if argv.first().is_some_and(|s| s == "conductor")
            && argv.get(1).is_some_and(|s| s == "metaopt-run")
        {
            let parsed = conductor::metaopt_cli::MetaoptArgs::parse(argv.into_iter().skip(2))?;
            let conductor_data_dir = data_directory()?.join("conductor");
            let store = Arc::new(conductor::ConductorStore::open(conductor_data_dir)?);
            let outcome = conductor::metaopt_cli::run(parsed, store).await?;
            println!("{outcome}");
            return Ok(());
        }
    }

    init_tracing();
    println!("fae-daemon (Phase 1, chunk 2a) — protocol v{PROTOCOL_VERSION}");

    spawn_parent_watch();

    let run_dir = run_directory()?;
    create_private_dir(&run_dir)?;
    let socket_path = run_dir.join("fae-daemon.sock");
    let audit_path = run_dir.join("audit.jsonl");
    println!("run dir : {} (0700)", run_dir.display());

    // ── Bootstrap the first client (the Swift frontend launched by the owner) ──
    let now = now_ms();
    let token = generate_token()?;
    let token_hash = hash_token(&token);
    let token_path = run_dir.join("bootstrap.token");
    write_secret_file(&token_path, &token)?; // file fallback; CHUNK 2c: macOS Keychain
    println!("token   : {} (0600)", token_path.display());

    let client = ClientRecord {
        client_id: fae_control_plane::BOOTSTRAP_CLIENT_ID.to_owned(),
        class: ClientClass::SwiftFrontend,
        scopes: ClientClass::SwiftFrontend
            .default_scopes()
            .into_iter()
            .collect(),
        issued_at_ms: now,
        expires_at_ms: now.saturating_add(THIRTY_DAYS_MS),
        revoked_at_ms: None,
        display_name: "Fae (this Mac)".to_owned(),
    };

    let mut registry = ClientRegistry::new();
    registry.insert(client, token_hash);
    let registry = Arc::new(registry);
    let tickets = Arc::new(Mutex::new(TicketStore::new()));

    let engine = build_engine().await;
    let info = engine.describe();
    println!("engine  : {} ({})", info.backend, info.model_id);
    let asr_fallback = build_asr_fallback_engine();
    if let Some(asr) = &asr_fallback {
        let info = asr.describe();
        println!("asr     : {} ({}) — lazy", info.backend, info.model_id);
    } else {
        println!("asr     : disabled");
    }
    let tts = build_tts_engine();
    let tts_info = tts.describe();
    println!("tts     : {} ({})", tts_info.backend, tts_info.model_id);
    let audio = Arc::new(AudioManager::new());
    // Server-push event fan-out (voice spine V2). Held here so producers (V3
    // daemon-owned TTS playback → `audio.level`) can publish; the transport
    // registers `conversation.subscribe` clients as subscribers.
    let events = events::EventBus::new();
    // Live daemon-owned playback bookkeeping (voice spine V3a): resolves
    // end-reason (`completed` vs `interrupted`) for `audio.playback_ended`.
    let playbacks = events::PlaybackRegistry::new();
    // Live native-ACP sessions (gap A2): persistent agent sessions outlive the
    // connection that created them, so the registry is process-global.
    let agents = agents::AgentSessionRegistry::new();
    println!("audit   : {} (jsonl)", audit_path.display());
    println!(
        "client  : authenticate with {{\"command\":\"session.authenticate\",\"payload\":{{\"client_id\":\"{}\",\"token\":<file>}}}}",
        fae_control_plane::BOOTSTRAP_CLIENT_ID
    );

    // ── Learned conductor (M1) ──────────────────────────────────────────
    // The static-direct policy: always emits direct + local-model +
    // ApprovalClass::None. Byte-identical to the legacy inject_text path by
    // construction (the direct arm calls inject_text_core verbatim). Chain is
    // opt-in via FAE_CONDUCTOR_CHAIN (default off — F-3). Telemetry is
    // fire-and-forget to an isolated store; fingerprint continuity needs a
    // stable per-install key under the data dir.
    let chain_enabled = std::env::var("FAE_CONDUCTOR_CHAIN")
        .is_ok_and(|v| v == "1" || v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("yes"));
    let conductor_data_dir = data_directory().map_err(|e| e.to_string())?;
    let install_key =
        conductor::InstallKey::load_or_create(&conductor_data_dir.join("conductor-install.key"))
            .map_err(|e| format!("conductor install key: {e}"))?;
    let conductor_store = conductor::ConductorStore::open(conductor_data_dir.join("conductor"))
        .map_err(|e| format!("conductor store: {e}"))?;
    let conductor_recipes = conductor::RecipeSet::default(); // M1: no recipe needs loading (static-direct is hardcoded in the policy)
    let conductor_workers = conductor_worker_registry_from_env();
    let conductor_policy = conductor::StaticDirectPolicy;
    let model_mode = conductor_model_mode_from_env();
    let budget_limits = conductor_budget_limits_from_env();
    if let Err(error) = budget_limits.validate() {
        tracing::warn!("invalid conductor budget limits; cloud routes will fail closed: {error}");
    }
    let budget_governor = conductor::BudgetGovernor::with_worker_limits(
        conductor_store.clone(),
        budget_limits,
        conductor_worker_budget_limits_from_env(),
    );
    let provider_pricing = conductor_provider_pricing_from_env(&conductor_workers);
    let conductor_egress =
        conductor::ConductorEgress::production(model_mode, budget_governor, provider_pricing);
    if chain_enabled {
        eprintln!(
            "fae-daemon: conductor chain ENABLED (FAE_CONDUCTOR_CHAIN). Direct remains the default; chain executes only for vetted chain recipes."
        );
    }
    // Startup misconfiguration warning (spec §5.3 m4): if any loaded recipe
    // specifies Chain while chain is disabled, surface it. M1 loads no recipes
    // (static-direct is hardcoded), so this is a forward-looking no-op now and
    // a real guard once M2/M3 load candidate recipes.
    if !chain_enabled {
        // No recipes loaded in M1; nothing to warn about. The guard lives here
        // for M2/M3 to populate when recipe loading lands.
    }
    let conductor_runtime = Arc::new(
        conductor::ConductorRuntime::new_with_egress(
            conductor_policy,
            conductor_recipes,
            conductor_workers,
            conductor_store,
            install_key,
            chain_enabled,
            conductor_egress,
        )
        .with_shadow(),
    );
    let shadow_enabled = conductor_runtime.shadow_enabled();
    println!(
        "conductor: static-direct (mode {}, chain {}, shadow {}) — telemetry isolated",
        model_mode.as_str(),
        if chain_enabled { "on" } else { "off" },
        if shadow_enabled { "on" } else { "off" }
    );

    // Optional TCP-loopback HTTP/WS diagnostic surface (opt-in, never default).
    if let Some(port) = diagnostic_port() {
        let state = Arc::new(diagnostic::DiagnosticState {
            registry: Arc::clone(&registry),
            engine: Arc::clone(&engine),
            tts: Arc::clone(&tts),
            audio: Arc::clone(&audio),
            tickets: Arc::clone(&tickets),
            audit_path: audit_path.clone(),
            events: events.clone(),
            playbacks: playbacks.clone(),
            agents: agents.clone(),
            conductor: Arc::clone(&conductor_runtime),
            port,
        });
        println!("diag    : TCP loopback diagnostic enabled on port {port} (opt-in)");
        tokio::spawn(async move {
            if let Err(error) = diagnostic::serve_tcp(state).await {
                eprintln!("fae-daemon: diagnostic listener stopped: {error}");
            }
        });
    }
    println!();

    // Serves until the process is killed. Fails closed on bind/permission error.
    transport::serve_unix(
        socket_path,
        registry,
        engine,
        asr_fallback,
        tts,
        audio,
        audit_path,
        events,
        playbacks,
        agents,
        conductor_runtime,
    )
    .await?;
    Ok(())
}

fn init_tracing() {
    let _ = tracing_subscriber::fmt().with_target(false).try_init();
}

fn conductor_model_mode_from_env() -> conductor::ModelMode {
    let raw = std::env::var("FAE_MODEL_MODE").ok();
    let mode = conductor::ModelMode::from_env_value(raw.as_deref());
    if raw
        .as_deref()
        .is_some_and(|value| conductor::ModelMode::parse(value).is_none())
    {
        tracing::warn!("unknown FAE_MODEL_MODE; defaulting to pure-local");
    }
    mode
}

fn conductor_worker_registry_from_env() -> conductor::WorkerRegistry {
    conductor::WorkerRegistry::from_cloud_credentials([
        (
            conductor::workers::CODEX_CLOUD_WORKER_ID,
            first_non_empty_env(["FAE_CODEX_API_KEY", "OPENAI_API_KEY"]),
        ),
        (
            conductor::workers::CLAUDE_CLOUD_WORKER_ID,
            first_non_empty_env(["FAE_CLAUDE_API_KEY", "ANTHROPIC_API_KEY"]),
        ),
        (
            conductor::workers::GEMINI_CLOUD_WORKER_ID,
            first_non_empty_env(["FAE_GEMINI_API_KEY", "GOOGLE_API_KEY"]),
        ),
        (
            conductor::workers::COPILOT_CLOUD_WORKER_ID,
            first_non_empty_env(["FAE_COPILOT_API_KEY", "GITHUB_TOKEN"]),
        ),
    ])
}

fn first_non_empty_env<const N: usize>(names: [&str; N]) -> Option<String> {
    names.into_iter().find_map(|name| {
        std::env::var(name)
            .ok()
            .filter(|value| !value.trim().is_empty())
    })
}

fn conductor_budget_limits_from_env() -> conductor::BudgetLimits {
    // Stage 1 exposes the per-worker bucket machinery while keeping startup
    // config deliberately conservative and simple. Unknown/unset values fall
    // back to the safe default; LocalOnly routes never consult this governor.
    conductor::BudgetLimits::default()
}

fn conductor_worker_budget_limits_from_env() -> HashMap<String, conductor::BudgetLimits> {
    HashMap::new()
}

fn conductor_provider_pricing_from_env(
    workers: &conductor::WorkerRegistry,
) -> conductor::ProviderPricingTable {
    let raw = std::env::var("FAE_PROVIDER_PRICING").ok();
    let mut table = match conductor::ProviderPricingTable::from_env_value(raw.as_deref()) {
        Ok(table) => table,
        Err(error) => {
            tracing::warn!(
                "invalid FAE_PROVIDER_PRICING; cloud routes without pricing fail closed: {error}"
            );
            conductor::ProviderPricingTable::empty()
        }
    };

    // Sentinel pricing defaults keep the §5.4 cost-gate path exercisable
    // without live provider billing. They are NON-AUTHORITATIVE test
    // scaffolding (owner decision 2026-06-23): provider-side spend caps are the
    // real cost control, not conductor estimates. These are not a billing
    // promise; operator-configured pricing (FAE_PROVIDER_PRICING) is an
    // optional opt-in layer for operators who want conductor-level cost
    // governance, not a prerequisite for real adapters or the all-available
    // default.
    for worker_id in workers.worker_ids() {
        if worker_id != conductor::workers::LOCAL_MODEL_WORKER_ID
            && !table.contains_worker(&worker_id)
        {
            table.insert(
                worker_id,
                conductor::ProviderPricing {
                    input_micros_per_token: 1,
                    output_micros_per_token: 1,
                },
            );
        }
    }
    table
}

/// Build the TTS backend (S19). On macOS: Kokoro via voice-tts/mlx-rs, with
/// weights loading lazily on the first `tts.synthesize`. `FAE_TTS_MODEL_ID`
/// overrides the repo. On Linux: the SHA-pinned Piper sidecar (P5/D2-V5).
/// `FAE_TTS=mock` forces the mock on any platform (test/CI override).
fn build_tts_engine() -> Arc<dyn TtsAdapter> {
    if std::env::var("FAE_TTS").is_ok_and(|value| value == "mock") {
        return Arc::new(MockTtsAdapter::new("mock-tts"));
    }
    #[cfg(target_os = "macos")]
    {
        let model_repo = std::env::var("FAE_TTS_MODEL_ID")
            .ok()
            .filter(|id| !id.is_empty())
            .unwrap_or_else(|| "prince-canuma/Kokoro-82M".to_owned());
        let voices_dir = local_voices_directory();
        if let Some(dir) = &voices_dir {
            println!("voices  : {} (custom voices, optional)", dir.display());
        }
        match fae_engine::VoiceTtsAdapter::spawn(model_repo, voices_dir) {
            Ok(adapter) => return Arc::new(adapter),
            Err(error) => {
                eprintln!("fae-daemon: tts worker spawn failed ({error}); using mock tts");
            }
        }
        Arc::new(MockTtsAdapter::new("mock-tts"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        // Linux TTS = Piper sidecar, integrity-gated like the llama-server
        // runtime. A missing/unverified sidecar is FATAL in production (we never
        // silently emit silence). `FAE_MODELS_LOCK=off` under FAE_DEV is the only
        // escape hatch; it also lets the mock path be selected via `FAE_TTS=mock`.
        match build_piper_tts_engine() {
            Ok(adapter) => Arc::new(adapter),
            Err(detail) => {
                if models_lock_disabled_for_dev() {
                    eprintln!(
                        "fae-daemon: WARNING: FAE_DEV allows FAE_MODELS_LOCK=off; piper unavailable ({detail}); using mock tts"
                    );
                    return Arc::new(MockTtsAdapter::new("mock-tts"));
                }
                exit_fatal("piper_tts", &detail)
            }
        }
    }
}

/// Resolve + integrity-verify the Piper sidecar (binary + voice model), then
/// build the adapter. Mirrors the llama-server gate: confinement to the Fae-owned
/// install dir, existence, and SHA-256 against `models.lock`. The voice files
/// live under `<install>/voices/` (installed by `install-piper-runtime.py`).
#[cfg(not(target_os = "macos"))]
fn build_piper_tts_engine() -> Result<fae_engine::PiperTtsAdapter, String> {
    let install_dir = resolve_piper_install_dir()?;
    let binary = install_dir.join("piper");
    let binary = executable_path(binary, "Piper runtime")?;
    let voices_dir = install_dir.join("voices");
    let model_onnx = voices_dir.join(format!("{PIPER_VOICE_NAME}.onnx"));
    let model_config = voices_dir.join(format!("{PIPER_VOICE_NAME}.onnx.json"));
    let espeak_data = install_dir.join("espeak-ng-data");

    verify_piper_artifacts(&binary, &model_onnx, &model_config)?;

    let espeak = espeak_data.is_dir().then_some(espeak_data);
    println!(
        "tts     : piper sidecar {} (voice {PIPER_VOICE_NAME})",
        binary.display()
    );
    Ok(fae_engine::PiperTtsAdapter::new(
        binary,
        model_onnx,
        model_config,
        espeak,
        PIPER_VOICE_NAME,
    ))
}

/// Resolution order for the Piper install dir, mirroring `resolve_llama_server_binary`:
/// 1. `FAE_PIPER_DIR` explicit override (dev/test/staging)
/// 2. bundled sibling of the daemon exe (`../piper` or `../lib/fae/piper`, FHS)
/// 3. owner app-support install (`<data>/runtimes/piper`)
#[cfg(not(target_os = "macos"))]
fn resolve_piper_install_dir() -> Result<PathBuf, String> {
    if let Some(dir) = std::env::var_os("FAE_PIPER_DIR") {
        let path = PathBuf::from(dir);
        if path.join("piper").is_file() {
            return Ok(path);
        }
        return Err(format!(
            "FAE_PIPER_DIR set but {}/piper does not exist",
            path.display()
        ));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            for rel in ["../piper", "../lib/fae/piper"] {
                let candidate = exe_dir.join(rel);
                if candidate.join("piper").is_file() {
                    return Ok(candidate);
                }
            }
        }
    }
    let install = data_directory()
        .map_err(|e| e.to_string())?
        .join("runtimes/piper");
    if install.join("piper").is_file() {
        return Ok(install);
    }
    Err(format!(
        "Piper TTS runtime not installed. Run \
         `python3 scripts/install-piper-runtime.py --install-dir {}`.",
        install.display()
    ))
}

/// Verify the Piper binary + voice files against `models.lock` (size + SHA-256).
/// Fail-closed: any miss aborts and the caller treats it as fatal in production.
#[cfg(not(target_os = "macos"))]
fn verify_piper_artifacts(
    binary: &Path,
    model_onnx: &Path,
    model_config: &Path,
) -> Result<(), String> {
    if models_lock_disabled_for_dev() {
        eprintln!(
            "fae-daemon: WARNING: FAE_DEV allows FAE_MODELS_LOCK=off; skipping Piper artifact verification"
        );
        return Ok(());
    }
    let lock = load_installed_models_lock()?;
    verify_locked_file(&lock, PIPER_BINARY_ARTIFACT_ID, "tts_binary", binary)?;
    verify_locked_file(&lock, PIPER_VOICE_ONNX_ARTIFACT_ID, "tts_model", model_onnx)?;
    verify_locked_file(
        &lock,
        PIPER_VOICE_CONFIG_ARTIFACT_ID,
        "tts_model",
        model_config,
    )?;
    Ok(())
}

/// Look up `id` in the lock, confirm its role + the `piper-sidecar` loader, then
/// verify the on-disk file's size + SHA-256 match the pinned artifact.
#[cfg(not(target_os = "macos"))]
fn verify_locked_file(
    lock: &ModelsLock,
    id: &str,
    expected_role: &str,
    path: &Path,
) -> Result<(), String> {
    let artifact = lock
        .artifacts
        .iter()
        .find(|artifact| artifact.id == id)
        .ok_or_else(|| format!("missing required artifact {id}"))?;
    if artifact.role != expected_role || artifact.loader != "piper-sidecar" {
        return Err(format!(
            "artifact {id} must be role={expected_role} loader=piper-sidecar (got role={}, loader={})",
            artifact.role, artifact.loader
        ));
    }
    let metadata = std::fs::metadata(path)
        .map_err(|error| format!("stat {} ({id}): {error}", path.display()))?;
    if artifact.size_bytes != 0 && metadata.len() != artifact.size_bytes {
        return Err(format!(
            "{id} size mismatch for {}: expected {}, got {}",
            path.display(),
            artifact.size_bytes,
            metadata.len()
        ));
    }
    let expected = artifact.sha256.trim().to_ascii_lowercase();
    if expected.len() != 64 || !expected.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(format!("artifact {id} must pin a 64-hex sha256"));
    }
    let actual =
        sha256_file(path).map_err(|error| format!("hash {} ({id}): {error}", path.display()))?;
    if actual != expected {
        return Err(format!(
            "{id} sha256 mismatch for {}: expected {expected}, got {actual}",
            path.display()
        ));
    }
    Ok(())
}

/// Directory holding custom voice embeddings (`{voice}.safetensors`) checked
/// before the HF repo — `<fae data dir>/voices`, sibling of the run dir. The
/// Swift frontend installs Fae's own voice here. `None` when HOME is unset
/// (the adapter then serves HF repo voices only).
#[cfg(target_os = "macos")]
fn local_voices_directory() -> Option<PathBuf> {
    run_directory()
        .ok()
        .and_then(|run| run.parent().map(|base| base.join("voices")))
}

const DEFAULT_LLAMA_REPO: &str = "unsloth/gemma-4-E4B-it-qat-GGUF";
const DEFAULT_LLAMA_REVISION: &str = "bbcd9d849c2541ecc2af7ef64b3c3c2c7aa14e96";
const DEFAULT_LLAMA_ALIAS: &str = "gemma-4";
const DEFAULT_MODEL_FILE: &str = "gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf";
const DEFAULT_MODEL_SIZE: u64 = 4_215_693_760;
const DEFAULT_MODEL_SHA256: &str =
    "b3052f962d6449b4eb2075733c068bdec1c51eadb7b237e6c3157bfbb7b1dae0";
const DEFAULT_MMPROJ_FILE: &str = "mmproj-BF16.gguf";
const DEFAULT_MMPROJ_SIZE: u64 = 991_552_320;
const DEFAULT_MMPROJ_SHA256: &str =
    "7c9bafa27f82d658eda805c1d82ef62bb0368e1ff75f64f77de58ad318beaaf9";
const DEFAULT_MTP_FILE: &str = "mtp-gemma-4-E4B-it.gguf";
const DEFAULT_MTP_SIZE: u64 = 59_676_544;
const DEFAULT_MTP_SHA256: &str = "b0005dc39d47ede950c3ec413cb20e832f15b216126eae368d9f572676153cb6";

const QWEN3_ASR_REPO: &str = "ggml-org/Qwen3-ASR-1.7B-GGUF";
const QWEN3_ASR_REVISION: &str = "36a678687ba7d07a74ca70ccb0e36902e005fb80";
const QWEN3_ASR_MODEL_ARTIFACT_ID: &str = "ggml-org-qwen3-asr-1-7b-q8-0-gguf";
const QWEN3_ASR_MMPROJ_ARTIFACT_ID: &str = "ggml-org-qwen3-asr-1-7b-mmproj-q8-0-gguf";
const LLAMACPP_RUNTIME_RELEASE: &str = "b9692";
/// `models.lock` artifact id for the bundled `llama-server` binary, per target.
/// Each platform ships its own prebuilt from the same llama.cpp release, so the
/// integrity gate must look up the entry matching the binary it actually runs.
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
const LLAMA_SERVER_BINARY_ARTIFACT_ID: &str = "llamacpp-b9692-llama-server-macos-arm64";
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
const LLAMA_SERVER_BINARY_ARTIFACT_ID: &str = "llamacpp-b9692-llama-server-linux-x86_64";
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
const LLAMA_SERVER_BINARY_ARTIFACT_ID: &str = "llamacpp-b9692-llama-server-linux-aarch64";
#[cfg(target_os = "macos")]
const LLAMA_SERVER_SIGNED_CDHASH: &str = "3d5c9574d44b155e1d2551cc082cbff8c5d9d0c8";
#[cfg(target_os = "macos")]
const LLAMA_SERVER_SIGNED_TEAM_ID: &str = "MEGSB2GXGZ";

/// `models.lock` artifact ids for the Piper TTS sidecar (Linux-only TTS lane,
/// P5/D2-V5). Each Linux target ships its own prebuilt `piper` binary from the
/// same rhasspy/piper release, so the integrity gate looks up the entry matching
/// the binary it actually runs. macOS uses Kokoro/voice-tts and never reads these.
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
const PIPER_BINARY_ARTIFACT_ID: &str = "rhasspy-piper-2023-11-14-2-linux-x86_64";
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
const PIPER_BINARY_ARTIFACT_ID: &str = "rhasspy-piper-2023-11-14-2-linux-aarch64";
#[cfg(not(target_os = "macos"))]
const PIPER_VOICE_ONNX_ARTIFACT_ID: &str = "rhasspy-piper-voices-en-us-lessac-medium-onnx";
#[cfg(not(target_os = "macos"))]
const PIPER_VOICE_CONFIG_ARTIFACT_ID: &str = "rhasspy-piper-voices-en-us-lessac-medium-onnx-json";
/// The pinned voice's display id (status + audit only).
#[cfg(not(target_os = "macos"))]
const PIPER_VOICE_NAME: &str = "en_US-lessac-medium";

/// Build the inference backend. llama.cpp is now the only runtime path: the
/// daemon owns a `llama-server` sidecar and uses llama.cpp's `-hf` downloader to
/// fetch/cache the default Unsloth Gemma 4 12B GGUF on request. There is no
/// mistral.rs/candle fallback path in the runtime.
async fn build_engine() -> Arc<dyn ProviderAdapter> {
    if let Err(detail) = engine_selection() {
        exit_fatal("engine_selection", &detail);
    }
    build_llamacpp_engine().await
}

/// Build the optional daemon-owned Qwen3-ASR sidecar. It is lazy: the ~2.5 GB
/// Qwen3-ASR artifacts are downloaded and verified only if a fragile audio turn
/// asks for `audio.transcribe_fallback`.
fn build_asr_fallback_engine() -> Option<Arc<dyn ProviderAdapter>> {
    if std::env::var("FAE_AUDIO_FALLBACK")
        .is_ok_and(|value| value == "0" || value.eq_ignore_ascii_case("false"))
    {
        return None;
    }
    let binary = match resolve_llama_server_binary() {
        Ok(path) => path,
        Err(detail) => {
            eprintln!("fae-daemon: ASR fallback disabled; llama.cpp runtime unavailable: {detail}");
            return None;
        }
    };
    if let Err(detail) = verify_llama_server_binary(&binary) {
        eprintln!("fae-daemon: ASR fallback disabled; llama.cpp runtime digest failed: {detail}");
        return None;
    }
    let cache_dir = std::env::var_os("FAE_ASR_LLAMA_CACHE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            default_llama_cache_dir()
                .unwrap_or_else(|_| PathBuf::from("models/llamacpp"))
                .join("asr")
        });
    if let Err(error) = std::fs::create_dir_all(&cache_dir) {
        eprintln!(
            "fae-daemon: ASR fallback disabled; create cache {}: {error}",
            cache_dir.display()
        );
        return None;
    }
    let (repo, revision, model, mmproj) = match qwen3_asr_locked_artifacts() {
        Ok(artifacts) => artifacts,
        Err(detail) => {
            eprintln!("fae-daemon: ASR fallback disabled; models.lock: {detail}");
            return None;
        }
    };
    let config = LlamaServerConfig {
        binary: binary.to_string_lossy().to_string(),
        model: LlamaModelSource::PinnedHuggingFace {
            repo,
            revision,
            cache_dir: cache_dir.to_string_lossy().to_string(),
            model,
            mmproj,
            mtp_draft: None,
        },
        lora_gguf: None,
        alias: "qwen3-asr".to_owned(),
        enable_thinking: false,
        mtp_draft_tokens: None,
        port: env_parsed("FAE_ASR_LLAMA_PORT", 18_081_u16),
        ctx_size: env_parsed("FAE_ASR_LLAMA_CTX", 4096_u32),
        ngl: env_parsed("FAE_ASR_LLAMA_NGL", 999_u32),
    };
    Some(Arc::new(LazyLlamaServerAdapter::new(
        config,
        "qwen3-asr",
        std::time::Duration::from_secs(env_parsed("FAE_ASR_LLAMA_TIMEOUT_S", 180_u64)),
    )))
}

fn qwen3_asr_locked_artifacts(
) -> Result<(String, String, RemoteModelArtifact, RemoteModelArtifact), String> {
    let lock = load_installed_models_lock()?;
    let model = locked_remote_artifact(&lock, QWEN3_ASR_MODEL_ARTIFACT_ID, "asr_model")?;
    let mmproj = locked_remote_artifact(&lock, QWEN3_ASR_MMPROJ_ARTIFACT_ID, "asr_mmproj")?;
    if model.source_repo != mmproj.source_repo || model.source_revision != mmproj.source_revision {
        return Err("Qwen3-ASR model/mmproj lock entries must share repo and revision".to_owned());
    }
    if model.source_repo != QWEN3_ASR_REPO || model.source_revision != QWEN3_ASR_REVISION {
        return Err(format!(
            "Qwen3-ASR lock entry points at unexpected source {}@{}",
            model.source_repo, model.source_revision
        ));
    }
    Ok((
        model.source_repo.clone(),
        model.source_revision.clone(),
        remote_artifact_from_lock(&model),
        remote_artifact_from_lock(&mmproj),
    ))
}

fn load_installed_models_lock() -> Result<ModelsLock, String> {
    let path = data_directory()
        .map_err(|error| error.to_string())?
        .join("models.lock");
    ModelsLock::load(&path).map_err(|error| error.to_string())
}

fn locked_remote_artifact(
    lock: &ModelsLock,
    id: &str,
    expected_role: &str,
) -> Result<fae_engine::Artifact, String> {
    let artifact = lock
        .artifacts
        .iter()
        .find(|artifact| artifact.id == id)
        .ok_or_else(|| format!("missing required artifact {id}"))?;
    if artifact.role != expected_role {
        return Err(format!(
            "artifact {id} role mismatch: expected {expected_role}, got {}",
            artifact.role
        ));
    }
    if artifact.loader != "llamacpp-sidecar" {
        return Err(format!(
            "artifact {id} loader mismatch: expected llamacpp-sidecar, got {}",
            artifact.loader
        ));
    }
    if artifact.source_repo.is_empty() || artifact.source_revision.is_empty() {
        return Err(format!(
            "artifact {id} must pin source_repo and source_revision"
        ));
    }
    if artifact.size_bytes == 0 {
        return Err(format!("artifact {id} must pin size_bytes"));
    }
    let sha = artifact.sha256.trim();
    if sha.len() != 64 || !sha.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(format!("artifact {id} must pin a 64-hex sha256"));
    }
    Ok(artifact.clone())
}

fn remote_artifact_from_lock(artifact: &fae_engine::Artifact) -> RemoteModelArtifact {
    RemoteModelArtifact {
        filename: artifact.filename.clone(),
        size_bytes: artifact.size_bytes,
        sha256: artifact.sha256.clone(),
    }
}

/// Resolve the `llama-server` binary. Fae owns this runtime; production never
/// relies on PATH. Resolution order:
/// 1. `FAE_LLAMA_BIN` explicit override (dev/test)
/// 2. bundled app resource: `Fae.app/Contents/Resources/LlamaCpp/llama-server`
/// 3. `FAE_LLAMACPP_RUNTIME_DIR/llama-server` (installer/staging override)
/// 4. owner app-support install: `<data>/runtimes/llamacpp/llama-server`
fn resolve_llama_server_binary() -> Result<PathBuf, String> {
    if let Some(path) = env_path("FAE_LLAMA_BIN") {
        return executable_path(PathBuf::from(path), "FAE_LLAMA_BIN");
    }
    if let Some(path) = bundled_llama_server_path() {
        if path.is_file() {
            return executable_path(path, "bundled llama.cpp runtime");
        }
    }
    if let Some(dir) = std::env::var_os("FAE_LLAMACPP_RUNTIME_DIR") {
        let path = PathBuf::from(dir).join("llama-server");
        if path.is_file() {
            return executable_path(path, "FAE_LLAMACPP_RUNTIME_DIR");
        }
    }
    let install_path = data_directory()
        .map_err(|e| e.to_string())?
        .join("runtimes/llamacpp/llama-server");
    if install_path.is_file() {
        return executable_path(install_path, "Fae app-support llama.cpp runtime");
    }
    Err(format!(
        "llama.cpp runtime not installed. Bundle it with `just embed-llamacpp-runtime` \
         or run `python3 scripts/install-llamacpp-runtime.py --install-dir {}`. \
         Fae no longer falls back to mistral.rs.",
        install_path
            .parent()
            .map_or_else(|| "<install-dir>".to_owned(), |p| p.display().to_string())
    ))
}

fn executable_path(path: PathBuf, label: &str) -> Result<PathBuf, String> {
    if !path.is_file() {
        return Err(format!("{label} does not exist: {}", path.display()));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path)
            .map_err(|e| format!("stat {label} {}: {e}", path.display()))?
            .permissions()
            .mode();
        if mode & 0o111 == 0 {
            return Err(format!("{label} is not executable: {}", path.display()));
        }
    }
    Ok(path)
}

fn verify_llama_server_binary(path: &Path) -> Result<(), String> {
    if models_lock_disabled_for_dev() {
        eprintln!(
            "fae-daemon: WARNING: FAE_DEV allows FAE_MODELS_LOCK=off; skipping llama-server digest verification"
        );
        return Ok(());
    }
    match verify_unsigned_llama_server_binary(path) {
        Ok(()) => Ok(()),
        Err(raw_error) => {
            #[cfg(target_os = "macos")]
            {
                verify_signed_llama_server_binary(path).map_err(|signed_error| {
                    format!("{raw_error}; signed runtime verification also failed: {signed_error}")
                })
            }
            #[cfg(not(target_os = "macos"))]
            {
                Err(raw_error)
            }
        }
    }
}

fn verify_unsigned_llama_server_binary(path: &Path) -> Result<(), String> {
    let lock = load_installed_models_lock()?;
    let artifact = lock
        .artifacts
        .iter()
        .find(|artifact| artifact.id == LLAMA_SERVER_BINARY_ARTIFACT_ID)
        .ok_or_else(|| format!("missing required artifact {LLAMA_SERVER_BINARY_ARTIFACT_ID}"))?;
    if artifact.role != "asr_binary" || artifact.loader != "llamacpp-sidecar" {
        return Err(format!(
            "artifact {LLAMA_SERVER_BINARY_ARTIFACT_ID} must be role=asr_binary loader=llamacpp-sidecar"
        ));
    }
    let metadata = std::fs::metadata(path)
        .map_err(|error| format!("stat llama-server {}: {error}", path.display()))?;
    if metadata.len() != artifact.size_bytes {
        return Err(format!(
            "llama-server binary size mismatch for {} (runtime {LLAMACPP_RUNTIME_RELEASE}): expected {}, got {}",
            path.display(),
            artifact.size_bytes,
            metadata.len()
        ));
    }
    let actual = sha256_file(path)
        .map_err(|error| format!("hash llama-server {}: {error}", path.display()))?;
    let expected = artifact.sha256.trim().to_ascii_lowercase();
    if actual != expected {
        return Err(format!(
            "llama-server binary sha256 mismatch for {} (runtime {LLAMACPP_RUNTIME_RELEASE}): expected {}, got {}",
            path.display(),
            expected,
            actual
        ));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn verify_signed_llama_server_binary(path: &Path) -> Result<(), String> {
    let output = std::process::Command::new("/usr/bin/codesign")
        .args(["-dv", "--verbose=4"])
        .arg(path)
        .output()
        .map_err(|error| format!("spawn codesign: {error}"))?;
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() {
        return Err(format!("codesign failed: {}", stderr.trim()));
    }
    let cdhash = codesign_field(&stderr, "CDHash=")
        .ok_or_else(|| "codesign output missing CDHash".to_owned())?;
    if cdhash != LLAMA_SERVER_SIGNED_CDHASH {
        return Err(format!(
            "CDHash mismatch: expected {LLAMA_SERVER_SIGNED_CDHASH}, got {cdhash}"
        ));
    }
    let team = codesign_field(&stderr, "TeamIdentifier=")
        .ok_or_else(|| "codesign output missing TeamIdentifier".to_owned())?;
    if team != LLAMA_SERVER_SIGNED_TEAM_ID {
        return Err(format!(
            "TeamIdentifier mismatch: expected {LLAMA_SERVER_SIGNED_TEAM_ID}, got {team}"
        ));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn codesign_field(output: &str, prefix: &str) -> Option<String> {
    output.lines().find_map(|line| {
        line.strip_prefix(prefix)
            .map(|value| value.trim().to_owned())
    })
}

fn validate_models_lock_escape() -> Result<(), String> {
    let disabled =
        std::env::var("FAE_MODELS_LOCK").is_ok_and(|value| value.eq_ignore_ascii_case("off"));
    if disabled && !dev_mode() {
        Err("FAE_MODELS_LOCK=off is only allowed when FAE_DEV=1".to_owned())
    } else {
        Ok(())
    }
}

fn models_lock_disabled_for_dev() -> bool {
    std::env::var("FAE_MODELS_LOCK").is_ok_and(|value| value.eq_ignore_ascii_case("off"))
        && dev_mode()
}

fn dev_mode() -> bool {
    std::env::var("FAE_DEV").is_ok_and(|value| value == "1" || value.eq_ignore_ascii_case("true"))
}

fn sha256_file(path: &Path) -> std::io::Result<String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;

    let mut file = std::fs::File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 1024 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(hex::encode(digest.finalize()))
}

fn bundled_llama_server_path() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let exe_dir = exe.parent()?;
    #[cfg(target_os = "macos")]
    {
        // Fae.app/Contents/MacOS/fae-daemon → ../Resources/LlamaCpp/llama-server
        Some(exe_dir.join("../Resources/LlamaCpp/llama-server"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        // The runtime ships in `<prefix>/lib/fae/llamacpp`. The daemon's real exe
        // can sit in two places depending on package + launch: `<prefix>/lib/fae/
        // bin/fae-daemon` (the FHS `.deb`, reached via the `/usr/bin` symlink that
        // `current_exe` resolves through) — relative `../llamacpp` — OR
        // `<prefix>/bin/fae-daemon` (a direct copy) — relative `../lib/fae/llamacpp`.
        // No single fixed path serves both, so probe by existence.
        for rel in [
            "../llamacpp/llama-server",
            "../lib/fae/llamacpp/llama-server",
        ] {
            let candidate = exe_dir.join(rel);
            if candidate.exists() {
                return Some(candidate);
            }
        }
        // Neither resolved (e.g. pre-install); default to the FHS sibling layout
        // so the caller's existence check reports a clear miss.
        Some(exe_dir.join("../llamacpp/llama-server"))
    }
}

fn default_llama_cache_dir() -> Result<PathBuf, String> {
    Ok(data_directory()
        .map_err(|e| e.to_string())?
        .join("models/llamacpp"))
}

fn default_llama_model_source() -> Result<LlamaModelSource, String> {
    if let Some(model_gguf) = env_path("FAE_LLAMA_MODEL_GGUF") {
        if std::env::var("FAE_DEV").is_ok_and(|v| v == "1" || v.eq_ignore_ascii_case("true")) {
            return Ok(LlamaModelSource::Local {
                model_gguf,
                mmproj: env_path("FAE_LLAMA_MMPROJ"),
                mtp_draft: env_path("FAE_LLAMA_MTP_GGUF"),
            });
        }
        return Err(
            "FAE_LLAMA_MODEL_GGUF is dev-only; production uses the Fae-owned \
             llama.cpp pinned download-on-request path"
                .to_owned(),
        );
    }
    let cache_dir = std::env::var_os("FAE_LLAMA_CACHE_DIR")
        .map(PathBuf::from)
        .unwrap_or(default_llama_cache_dir()?);
    std::fs::create_dir_all(&cache_dir)
        .map_err(|e| format!("create model cache {}: {e}", cache_dir.display()))?;
    Ok(LlamaModelSource::PinnedHuggingFace {
        repo: DEFAULT_LLAMA_REPO.to_owned(),
        revision: DEFAULT_LLAMA_REVISION.to_owned(),
        cache_dir: cache_dir.to_string_lossy().to_string(),
        model: RemoteModelArtifact {
            filename: DEFAULT_MODEL_FILE.to_owned(),
            size_bytes: DEFAULT_MODEL_SIZE,
            sha256: DEFAULT_MODEL_SHA256.to_owned(),
        },
        mmproj: RemoteModelArtifact {
            filename: DEFAULT_MMPROJ_FILE.to_owned(),
            size_bytes: DEFAULT_MMPROJ_SIZE,
            sha256: DEFAULT_MMPROJ_SHA256.to_owned(),
        },
        mtp_draft: Some(RemoteModelArtifact {
            filename: DEFAULT_MTP_FILE.to_owned(),
            size_bytes: DEFAULT_MTP_SIZE,
            sha256: DEFAULT_MTP_SHA256.to_owned(),
        }),
    })
}

async fn build_llamacpp_engine() -> Arc<dyn ProviderAdapter> {
    let model_id = env_path("FAE_MODEL_ID").unwrap_or_else(|| DEFAULT_LLAMA_ALIAS.to_owned());

    if let Some(url) = env_path("FAE_LLAMA_SERVER_URL") {
        if !std::env::var("FAE_DEV").is_ok_and(|v| v == "1" || v.eq_ignore_ascii_case("true")) {
            exit_fatal(
                "llamacpp_attach",
                "FAE_LLAMA_SERVER_URL is dev-only; production must use a Fae-owned sidecar",
            );
        }
        println!("engine  : llama.cpp — attaching to dev server {url}");
        return Arc::new(LlamaServerAdapter::connect(url, model_id));
    }

    let binary = resolve_llama_server_binary()
        .unwrap_or_else(|detail| exit_fatal("llamacpp_runtime", &detail));
    verify_llama_server_binary(&binary)
        .unwrap_or_else(|detail| exit_fatal("llamacpp_runtime_digest", &detail));
    validate_models_lock_escape().unwrap_or_else(|detail| exit_fatal("models_lock", &detail));
    let model = default_llama_model_source()
        .unwrap_or_else(|detail| exit_fatal("llamacpp_model_source", &detail));
    let alias = env_path("FAE_LLAMA_ALIAS").unwrap_or_else(|| DEFAULT_LLAMA_ALIAS.to_owned());
    let enable_thinking = std::env::var("FAE_GEMMA_THINKING")
        .map(|v| v != "0" && !v.eq_ignore_ascii_case("false"))
        .unwrap_or(true);
    // Gemma 4 E4B QAT ships a repo-root E4B-matched MTP drafter (`mtp-gemma-4-E4B-it.gguf`).
    // Fae downloads/verifies it with the base model and passes it via
    // `--model-draft`; default on for the enhanced path, with `FAE_LLAMA_MTP=0`
    // as the escape hatch if memory is too tight.
    let mtp_draft_tokens = if std::env::var("FAE_LLAMA_MTP")
        .map(|v| v == "0" || v.eq_ignore_ascii_case("false"))
        .unwrap_or(false)
    {
        None
    } else {
        Some(env_parsed("FAE_LLAMA_MTP_DRAFT_TOKENS", 4_u32))
    };
    let config = LlamaServerConfig {
        binary: binary.to_string_lossy().to_string(),
        model,
        lora_gguf: env_path("FAE_LLAMA_LORA_GGUF"),
        alias: alias.clone(),
        enable_thinking,
        mtp_draft_tokens,
        port: env_parsed("FAE_LLAMA_PORT", 18080),
        ctx_size: env_parsed("FAE_LLAMA_CTX", 8192),
        ngl: env_parsed("FAE_LLAMA_NGL", 999),
    };
    config
        .preflight_pinned_artifacts()
        .unwrap_or_else(|error| exit_fatal("llamacpp_model_digest", &error.to_string()));
    let timeout_secs = env_parsed("FAE_LLAMA_READY_TIMEOUT_SECS", 1800_u64);
    if let LlamaModelSource::PinnedHuggingFace {
        repo,
        revision,
        cache_dir,
        model,
        mmproj,
        mtp_draft,
    } = &config.model
    {
        println!(
            "engine  : llama.cpp — lazy sidecar ready (repo {repo}@{revision}, base {}, mmproj {}, mtp {}, cache {}, alias {alias}, timeout {timeout_secs}s)",
            model.filename,
            mmproj.filename,
            mtp_draft
                .as_ref()
                .map_or("<off>", |artifact| artifact.filename.as_str()),
            cache_dir
        );
    } else {
        println!(
            "engine  : llama.cpp — lazy sidecar ready (model source {:?}, alias {alias}, timeout {timeout_secs}s)",
            config.model
        );
    }
    Arc::new(LazyLlamaServerAdapter::new(
        config,
        model_id,
        std::time::Duration::from_secs(timeout_secs),
    ))
}

/// Parse an env var into any `FromStr` numeric, falling back to `default` when
/// unset or unparseable.
fn env_parsed<T: std::str::FromStr>(key: &str, default: T) -> T {
    std::env::var(key)
        .ok()
        .and_then(|raw| raw.parse().ok())
        .unwrap_or(default)
}

/// Validate `FAE_ENGINE`. llama.cpp is the only runtime path; setting
/// `FAE_ENGINE=mistralrs` is now a hard error, not a fallback.
fn engine_selection() -> Result<(), String> {
    match std::env::var("FAE_ENGINE")
        .ok()
        .filter(|v| !v.is_empty())
        .as_deref()
    {
        None | Some("") | Some("llamacpp") => Ok(()),
        Some("mistralrs") => Err(
            "FAE_ENGINE=mistralrs was removed from the runtime path; Fae now uses \
             bundled llama.cpp + on-demand Unsloth Gemma 4 downloads only"
                .to_owned(),
        ),
        Some(other) => Err(format!(
            "unknown FAE_ENGINE={other:?} — valid value is 'llamacpp' (default)"
        )),
    }
}

/// Read a non-empty env var as an optional path string.
fn env_path(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|p| !p.is_empty())
}

/// Fatal exit for an unrecoverable engine/runtime error. Logs a structured
/// event then exits with status 78 (config). Used instead of any model-engine
/// fallback: if the Fae-owned llama.cpp runtime is missing, the daemon stops
/// with an actionable install/bundle message.
fn exit_fatal(component: &str, detail: &str) -> ! {
    let event = serde_json::json!({
        "event": "fatal",
        "component": component,
        "error": detail,
    });
    eprintln!("fae-daemon: fatal: {event}");
    kill_all_registered_sidecars();
    std::process::exit(78);
}

/// Exit when the launching parent dies. The daemon must never outlive the
/// app that spawned it (recurring orphan bug: fae-daemon survived app quit
/// holding the model in RAM). When the parent exits, the daemon is reparented
/// (getppid changes), which a 2 s poll catches — this also covers parent
/// crashes and SIGKILL, where no clean shutdown command ever arrives.
/// `FAE_NO_PARENT_WATCH=1` disables it for standalone/diagnostic runs.
fn spawn_parent_watch() {
    if std::env::var_os("FAE_NO_PARENT_WATCH").is_some() {
        return;
    }
    let parent = std::os::unix::process::parent_id();
    if parent <= 1 {
        return; // already daemonized — nothing meaningful to watch
    }
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_secs(2));
        if std::os::unix::process::parent_id() != parent {
            // stderr is a pipe into the parent — it is gone too, so this
            // write may fail with EPIPE. eprintln! would PANIC on that and
            // kill only this thread, leaving the orphan alive; write
            // best-effort instead and exit unconditionally.
            use std::io::Write;
            let _ = writeln!(
                std::io::stderr(),
                "fae-daemon: parent process {parent} exited — shutting down"
            );
            // process::exit skips Drop, so reap spawned llama-server children
            // explicitly before exiting — otherwise they survive the daemon as
            // orphans holding GPU memory (the recurring orphan bug).
            kill_all_registered_sidecars();
            std::process::exit(0);
        }
    });
}

/// Diagnostic TCP port from `FAE_DIAGNOSTIC_TCP_PORT`, if set to a non-zero
/// value. Absent/invalid/zero → the diagnostic surface stays off.
fn diagnostic_port() -> Option<u16> {
    std::env::var("FAE_DIAGNOSTIC_TCP_PORT")
        .ok()
        .and_then(|raw| raw.parse::<u16>().ok())
        .filter(|port| *port != 0)
}

/// Owner-private run directory: `~/Library/Application Support/fae/run` on macOS,
/// `$XDG_DATA_HOME/fae/run` (or `~/.local/share/fae/run`) on Linux.
fn data_directory() -> DaemonResult<PathBuf> {
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    let home = PathBuf::from(home);
    #[cfg(target_os = "macos")]
    let base = home.join("Library/Application Support/fae");
    #[cfg(not(target_os = "macos"))]
    let base = match std::env::var_os("XDG_DATA_HOME") {
        Some(xdg) => PathBuf::from(xdg).join("fae"),
        None => home.join(".local/share/fae"),
    };
    Ok(base)
}

fn run_directory() -> DaemonResult<PathBuf> {
    Ok(data_directory()?.join("run"))
}

/// Create the private run directory with `0700` from birth. The leaf is created
/// in a single syscall at mode `0700` (no world-readable window between
/// `create` and `chmod`); only its ancestors go through `create_dir_all`. If
/// the leaf already exists we re-tighten it.
fn create_private_dir(path: &Path) -> DaemonResult<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        match std::fs::DirBuilder::new().mode(0o700).create(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
            }
            Err(error) => return Err(error.into()),
        }
    }
    #[cfg(not(unix))]
    std::fs::create_dir_all(path)?;
    Ok(())
}

/// Write a secret to a `0600` file that is created fresh and exclusively. Any
/// stale file is removed first, then `create_new` (`O_EXCL`) + `mode(0600)`
/// creates the file atomically at the right permissions — there is no window
/// where the plaintext lives in a pre-existing, looser-permissioned file. On
/// `0600` the owner bits are immune to umask, so no post-chmod is needed.
fn write_secret_file(path: &Path, contents: &str) -> DaemonResult<()> {
    use std::io::Write;
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    let mut open = std::fs::OpenOptions::new();
    open.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        open.mode(0o600);
    }
    let mut file = open.open(path)?;
    file.write_all(contents.as_bytes())?;
    Ok(())
}

/// Current wall clock in epoch-ms. Infallible: a pre-1970 clock yields 0 and an
/// impossibly-far-future clock saturates — never panics.
pub(crate) fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|dur| u64::try_from(dur.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// Monotonic, non-secret audit correlation id. An event id only needs to be
/// unique and ordered — never use a CSPRNG bearer token here (that conflates
/// secret material with log fields and makes every command pay a `getrandom`
/// syscall that could fail the command).
pub(crate) fn next_event_id(now_ms: u64) -> String {
    static EVENT_SEQ: AtomicU64 = AtomicU64::new(0);
    let seq = EVENT_SEQ.fetch_add(1, Ordering::Relaxed);
    format!("evt-{now_ms}-{seq}")
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]
    use super::*;
    use std::sync::Mutex;

    static ENV_GUARD: Mutex<()> = Mutex::new(());

    fn _lock_env() -> std::sync::MutexGuard<'static, ()> {
        ENV_GUARD.lock().expect("env guard poisoned")
    }

    fn clear_fae_env() {
        for key in [
            "FAE_ENGINE",
            "FAE_DEV",
            "FAE_MODEL_ID",
            "FAE_LLAMA_BIN",
            "FAE_LLAMACPP_RUNTIME_DIR",
            "FAE_LLAMA_MODEL_GGUF",
            "FAE_LLAMA_MMPROJ",
            "FAE_LLAMA_HF_SPEC",
            "FAE_LLAMA_CACHE_DIR",
            "FAE_LLAMA_ALIAS",
            "FAE_GEMMA_THINKING",
            "FAE_LLAMA_SERVER_URL",
            "FAE_MODELS_LOCK",
            "FAE_AUDIO_FALLBACK",
            "FAE_ASR_LLAMA_CACHE_DIR",
        ] {
            std::env::remove_var(key);
        }
    }

    fn write_test_models_lock(home: &Path, extra_artifacts: &str) {
        #[cfg(target_os = "macos")]
        let dir = home.join("Library/Application Support/fae");
        #[cfg(not(target_os = "macos"))]
        let dir = home.join(".local/share/fae");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("models.lock"),
            format!("schema_version = 1\ncreated_at = \"test\"\n{extra_artifacts}"),
        )
        .unwrap();
    }

    fn artifact_toml(id: &str, role: &str, filename: &str, size: u64, sha256: &str) -> String {
        format!(
            r#"
[[artifact]]
id = "{id}"
role = "{role}"
loader = "llamacpp-sidecar"
source_repo = "{QWEN3_ASR_REPO}"
source_revision = "{QWEN3_ASR_REVISION}"
filename = "{filename}"
size_bytes = {size}
sha256 = "{sha256}"
signature = ""
license = "test"
hardware_profile = "test"
approved_by = "test"
created_at = "test"
"#
        )
    }

    #[test]
    fn engine_selection_accepts_only_llamacpp_default() {
        let _g = _lock_env();
        clear_fae_env();
        assert!(engine_selection().is_ok());
        std::env::set_var("FAE_ENGINE", "llamacpp");
        assert!(engine_selection().is_ok());
        std::env::set_var("FAE_ENGINE", "mistralrs");
        let err = engine_selection().unwrap_err();
        assert!(err.contains("removed"), "unexpected error: {err}");
        std::env::set_var("FAE_ENGINE", "mock");
        assert!(engine_selection().is_err());
    }

    #[test]
    fn resolve_llama_server_binary_prefers_env_override() {
        let _g = _lock_env();
        clear_fae_env();
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("llama-server");
        std::fs::write(&bin, b"#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::env::set_var("FAE_LLAMA_BIN", &bin);
        assert_eq!(resolve_llama_server_binary().unwrap(), bin);
        std::env::set_var("FAE_DEV", "1");
        std::env::set_var("FAE_MODELS_LOCK", "off");
        verify_llama_server_binary(&bin).unwrap();
    }

    #[test]
    fn resolve_llama_server_binary_finds_runtime_dir() {
        let _g = _lock_env();
        clear_fae_env();
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("llama-server");
        std::fs::write(&bin, b"#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::env::set_var("FAE_LLAMACPP_RUNTIME_DIR", dir.path());
        assert_eq!(resolve_llama_server_binary().unwrap(), bin);
        std::env::set_var("FAE_DEV", "1");
        std::env::set_var("FAE_MODELS_LOCK", "off");
        verify_llama_server_binary(&bin).unwrap();
    }

    #[test]
    fn resolve_llama_server_binary_missing_is_actionable() {
        let _g = _lock_env();
        clear_fae_env();
        std::env::set_var("FAE_LLAMACPP_RUNTIME_DIR", "/definitely/missing/fae-llama");
        let err = resolve_llama_server_binary().unwrap_err();
        assert!(
            err.contains("install-llamacpp-runtime"),
            "unexpected error: {err}"
        );
        assert!(err.contains("mistral.rs"), "unexpected error: {err}");
    }

    #[test]
    fn runtime_digest_lock_off_is_dev_only() {
        let _g = _lock_env();
        clear_fae_env();
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("llama-server");
        std::fs::write(&bin, b"#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::env::set_var("HOME", dir.path());
        write_test_models_lock(
            dir.path(),
            &artifact_toml(
                LLAMA_SERVER_BINARY_ARTIFACT_ID,
                "asr_binary",
                "llama-server",
                999,
                "0000000000000000000000000000000000000000000000000000000000000000",
            ),
        );
        assert!(verify_llama_server_binary(&bin)
            .unwrap_err()
            .contains("size mismatch"));
        std::env::set_var("FAE_MODELS_LOCK", "off");
        assert!(validate_models_lock_escape()
            .unwrap_err()
            .contains("FAE_DEV=1"));
        assert!(verify_llama_server_binary(&bin)
            .unwrap_err()
            .contains("size mismatch"));
        std::env::set_var("FAE_DEV", "1");
        validate_models_lock_escape().unwrap();
        verify_llama_server_binary(&bin).unwrap();
    }

    #[test]
    fn qwen_asr_artifacts_are_resolved_from_models_lock() {
        let _g = _lock_env();
        clear_fae_env();
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("HOME", dir.path());
        let sha = "1111111111111111111111111111111111111111111111111111111111111111";
        let toml = format!(
            "{}{}",
            artifact_toml(
                QWEN3_ASR_MODEL_ARTIFACT_ID,
                "asr_model",
                "model.gguf",
                123,
                sha
            ),
            artifact_toml(
                QWEN3_ASR_MMPROJ_ARTIFACT_ID,
                "asr_mmproj",
                "mmproj.gguf",
                456,
                sha
            )
        );
        write_test_models_lock(dir.path(), &toml);

        let (repo, revision, model, mmproj) = qwen3_asr_locked_artifacts().unwrap();
        assert_eq!(repo, QWEN3_ASR_REPO);
        assert_eq!(revision, QWEN3_ASR_REVISION);
        assert_eq!(model.filename, "model.gguf");
        assert_eq!(model.size_bytes, 123);
        assert_eq!(model.sha256, sha);
        assert_eq!(mmproj.filename, "mmproj.gguf");
        assert_eq!(mmproj.size_bytes, 456);
    }

    #[test]
    fn qwen_asr_artifacts_fail_closed_when_lock_entry_missing() {
        let _g = _lock_env();
        clear_fae_env();
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("HOME", dir.path());
        let sha = "1111111111111111111111111111111111111111111111111111111111111111";
        write_test_models_lock(
            dir.path(),
            &artifact_toml(
                QWEN3_ASR_MODEL_ARTIFACT_ID,
                "asr_model",
                "model.gguf",
                123,
                sha,
            ),
        );

        let err = qwen3_asr_locked_artifacts().unwrap_err();
        assert!(
            err.contains(QWEN3_ASR_MMPROJ_ARTIFACT_ID),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn qwen_asr_artifacts_fail_closed_on_unpinned_hash() {
        let _g = _lock_env();
        clear_fae_env();
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("HOME", dir.path());
        let toml = format!(
            "{}{}",
            artifact_toml(
                QWEN3_ASR_MODEL_ARTIFACT_ID,
                "asr_model",
                "model.gguf",
                123,
                "not-a-sha"
            ),
            artifact_toml(
                QWEN3_ASR_MMPROJ_ARTIFACT_ID,
                "asr_mmproj",
                "mmproj.gguf",
                456,
                "1111111111111111111111111111111111111111111111111111111111111111"
            )
        );
        write_test_models_lock(dir.path(), &toml);

        let err = qwen3_asr_locked_artifacts().unwrap_err();
        assert!(err.contains("64-hex sha256"), "unexpected error: {err}");
    }

    #[test]
    fn default_model_source_is_pinned_e4b_download_on_request() {
        let _g = _lock_env();
        clear_fae_env();
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("FAE_LLAMA_CACHE_DIR", dir.path());
        let source = default_llama_model_source().unwrap();
        let LlamaModelSource::PinnedHuggingFace {
            repo,
            revision,
            cache_dir,
            model,
            mmproj,
            mtp_draft,
        } = source
        else {
            panic!("expected pinned HF source");
        };
        assert_eq!(repo, DEFAULT_LLAMA_REPO);
        assert_eq!(revision, DEFAULT_LLAMA_REVISION);
        assert_eq!(cache_dir, dir.path().to_string_lossy());
        assert_eq!(model.filename, DEFAULT_MODEL_FILE);
        assert_eq!(model.size_bytes, DEFAULT_MODEL_SIZE);
        assert_eq!(model.sha256, DEFAULT_MODEL_SHA256);
        assert_eq!(mmproj.filename, DEFAULT_MMPROJ_FILE);
        let mtp = mtp_draft.expect("MTP pinned by default");
        assert_eq!(mtp.filename, DEFAULT_MTP_FILE);
    }

    #[test]
    fn local_gguf_override_is_dev_only() {
        let _g = _lock_env();
        clear_fae_env();
        std::env::set_var("FAE_LLAMA_MODEL_GGUF", "/tmp/model.gguf");
        assert!(default_llama_model_source()
            .unwrap_err()
            .contains("dev-only"));
        std::env::set_var("FAE_DEV", "1");
        let source = default_llama_model_source().unwrap();
        assert_eq!(
            source,
            LlamaModelSource::Local {
                model_gguf: "/tmp/model.gguf".to_owned(),
                mmproj: None,
                mtp_draft: None,
            }
        );
    }

    #[test]
    fn llama_server_artifact_id_matches_host_platform() {
        // The integrity gate must look up the lock entry for the binary it
        // actually runs; each platform ships its own prebuilt from the same
        // llama.cpp release, so the artifact id must track target_os/target_arch.
        #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
        assert_eq!(
            LLAMA_SERVER_BINARY_ARTIFACT_ID,
            "llamacpp-b9692-llama-server-macos-arm64"
        );
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        assert_eq!(
            LLAMA_SERVER_BINARY_ARTIFACT_ID,
            "llamacpp-b9692-llama-server-linux-x86_64"
        );
        #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
        assert_eq!(
            LLAMA_SERVER_BINARY_ARTIFACT_ID,
            "llamacpp-b9692-llama-server-linux-aarch64"
        );
        // Whatever the host, the id is release-pinned and platform-qualified.
        assert!(LLAMA_SERVER_BINARY_ARTIFACT_ID.starts_with("llamacpp-b9692-llama-server-"));
    }

    #[test]
    fn bundled_llama_server_path_is_platform_shaped() {
        // Resolution is relative to the daemon executable. Confirm the per-OS
        // bundle layout: macOS → ../Resources/LlamaCpp, Linux → ../lib/fae/llamacpp.
        let path = bundled_llama_server_path().expect("current_exe resolves under test");
        let text = path.to_string_lossy();
        assert!(text.ends_with("llama-server"), "unexpected path: {text}");
        #[cfg(target_os = "macos")]
        assert!(text.contains("Resources/LlamaCpp"), "macOS layout: {text}");
        // Under `cargo test` neither bundle layout exists next to the test
        // binary, so resolution falls back to the FHS sibling path `../llamacpp`.
        // The authoritative bundle-resolution proof is the CI run-smoke that
        // installs the .deb and starts the daemon.
        #[cfg(not(target_os = "macos"))]
        assert!(
            text.ends_with("llamacpp/llama-server"),
            "linux layout: {text}"
        );
    }
}
