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
// Landlock's `pre_exec` self-restriction (toolhost/isolation.rs) is the single
// sanctioned unsafe block on Linux; everywhere else unsafe stays forbidden.
#![cfg_attr(not(target_os = "linux"), forbid(unsafe_code))]
#![cfg_attr(target_os = "linux", deny(unsafe_code))]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use fae_audio::AudioManager;
use fae_control_plane::{
    generate_token, hash_token, token_past_half_life, ClientClass, ClientRecord, ClientRegistry,
    Scope, TicketStore, PROTOCOL_VERSION,
};
use fae_engine::{
    kill_all_registered_sidecars, select_kv_cache_type, ChatEvent, KvCacheType,
    LazyLlamaServerAdapter, LlamaModelSource, LlamaServerAdapter, LlamaServerConfig, Loader,
    MockAdapter, MockTtsAdapter, ModelsLock, ProviderAdapter, RemoteModelArtifact, TtsAdapter,
};

mod agents;
/// Shared env-scrubbing allowlist for every daemon child spawn (jailed tool exec
/// + MCP servers) so provider secrets in the daemon's ambient env are never
/// inherited by a child. See `child_env.rs`.
mod child_env;
/// Phase G1 — pure context-compaction planning (token estimate, prompt budget,
/// oldest-first eviction with hysteresis). Shared by the delegate child loop and
/// the `conversation.compact` command. See `compaction.rs`.
mod compaction;
mod conductor;
/// Phase F1 — the native jailed agentic loop (`conversation.delegate`). The
/// daemon runs its own generate → execute-tool (jailed, `ToolOrigin::Delegated`)
/// → feed-back loop under hard iteration + token budgets, rooted at an ephemeral
/// jailed ToolHost. See `delegate.rs`.
mod delegate;
mod diagnostic;
mod events;
/// Phase F1+F2 — headless delegation proof (`--headless-delegate-test`). Drives
/// the native loop against scripted mock adapters with NO socket + NO real model,
/// asserting the jailed write lands, the receipt links its mutation receipt, an
/// out-of-root write is rejected, the budget-exhaustion path trips, and (F2) an
/// orchestrator fans out to parallel jailed leaves that link `parent_id` — with
/// no deadlock at concurrency cap 1 and a leaf's `delegate` call rejected.
mod headless_delegate_test;
/// Phase C — headless ToolHost + SkillHost execution proof (`--headless-tool-test`).
/// Builds the same governed host the protocol path builds, then runs
/// read/write/edit/bash + a jailed `run_skill` end-to-end WITHOUT a socket or a
/// model, asserting on every output. CI (`ci-linux.yml`) runs it to prove the
/// Landlock jail confines on the running kernel.
mod headless_tool_test;
/// Phase G3 — external MCP servers as a governed tool tier. Declared via
/// `FAE_MCP_CONFIG`, spawned as stdio subprocesses, exposed as `mcp:<server>:<tool>`
/// names routed through the governed ToolHost (scope + origin + allowlist gate;
/// NOT OS-jailed — external trusted subprocesses). See `mcp/mod.rs`.
mod mcp;
mod offline_turn;
/// Phase E — x0x peer messaging. Commit 1: `FAE_X0X_*` config + data-dir
/// discovery, sender-tier `SignatureVerifier` (`session_handoff` = owner-fleet
/// only), `session_handoff` payload schema + 64 KiB-capped builder, pure
/// per-kind dispatch. Commit 2: the x0xd SSE client + the `PeerIngress`
/// supervisor (the single governed inbound entry point) + `PeerOutbound` for the
/// `peer.*` commands. Spawned below behind `PeerConfig::from_env`.
mod peer;
mod server_request;
mod session;
/// ADR-013 Vision A (A2.5) — the daemon governed skill-execution host. Discovers
/// Fae's integrity'd skills (SKILL.md + MANIFEST.json + scripts/), fails closed
/// on any SHA-256 mismatch, and prepares `uv run --script` commands that route
/// through the EXISTING governed ToolHost bash path (no second execution lane).
mod skillhost;
/// ADR-013 Vision A — the daemon tool/skill execution host (fluers substrate).
/// Dormant in A1: wiring + reachability proof only. A2 builds the governed
/// ToolHost (fluers native tools + Skills over `SessionEnv`, behind a Fae
/// `ToolPolicy` impl = control-plane + DamageControl + PathPolicy + egress
/// membrane). Lives OUTSIDE `conductor/` (it's execution, not routing) and is
/// intentionally not covered by the mesh boundary guard (which protects the
/// conductor core from x0x-family deps; fluers is the sanctioned substrate).
#[allow(dead_code)]
mod toolhost;
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

    // Phase C headless governed-execution proof (`--headless-tool-test`): builds
    // the same governed ToolHost/SkillHost the protocol path builds, exercises
    // read/write/edit/bash + a jailed run_skill end-to-end, and asserts on every
    // output — NO socket, NO model. Exits nonzero (fails CI) on any failed step.
    {
        let argv: Vec<String> = std::env::args().skip(1).collect();
        if argv.first().is_some_and(|s| s == "--headless-tool-test") {
            let parsed = headless_tool_test::HeadlessToolTestArgs::parse(argv.into_iter().skip(1))?;
            match headless_tool_test::run(parsed).await {
                Ok(()) => {
                    println!("[headless-tool-test] ALL STEPS PASSED");
                    return Ok(());
                }
                Err(msg) => {
                    eprintln!("[headless-tool-test] FAILED: {msg}");
                    std::process::exit(1);
                }
            }
        }
    }

    // Phase F1 headless delegation proof (`--headless-delegate-test`): drives the
    // native jailed agentic loop against a scripted MockAdapter — NO socket, NO
    // model. Exits nonzero (fails CI) on any failed assertion.
    {
        let argv: Vec<String> = std::env::args().skip(1).collect();
        if argv
            .first()
            .is_some_and(|s| s == "--headless-delegate-test")
        {
            match headless_delegate_test::run().await {
                Ok(()) => {
                    println!("[headless-delegate-test] ALL STEPS PASSED");
                    return Ok(());
                }
                Err(msg) => {
                    eprintln!("[headless-delegate-test] FAILED: {msg}");
                    std::process::exit(1);
                }
            }
        }
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

    // Runtime-integrity verification gate (release CI, F21). Runs the SAME
    // models.lock + llama-server (+ Piper on Linux) digest checks the daemon does
    // at startup, but WITHOUT opening the socket or loading a model, then exits.
    // This lets `release.yml` catch a re-signed-bundle CDHash / lock drift on the
    // build box instead of only on the installed fleet. Optional flags override
    // the default bundled/installed resolution.
    {
        let argv: Vec<String> = std::env::args().skip(1).collect();
        if argv.first().is_some_and(|s| s == "--verify-runtime") {
            match verify_runtime_cli(&argv[1..]) {
                Ok(()) => {
                    println!("fae-daemon: runtime verification OK");
                    return Ok(());
                }
                Err((component, detail)) => {
                    // Mirror exit_fatal's JSON + code (78) as a CLEAN exit — no
                    // sidecars were spawned, so nothing to reap.
                    let event = serde_json::json!({
                        "event": "fatal",
                        "component": component,
                        "error": detail,
                    });
                    eprintln!("fae-daemon: fatal: {event}");
                    std::process::exit(78);
                }
            }
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

    // A3→B: the durable-workspace-root grant is an explicit owner opt-in,
    // default OFF (scope §5 / advisor #3). When `FAE_TOOLHOST_WORKSPACE_GRANT=1`
    // is set at daemon startup, the bootstrap SwiftFrontend client additionally
    // holds `ToolWorkspaceGrant`, letting it call `toolhost.set_root` (which then
    // requires a per-session owner approval of the SPECIFIC path via
    // `workspace.confirm_root`). A client-supplied payload is NEVER authority.
    let mut scopes: HashSet<_> = ClientClass::SwiftFrontend
        .default_scopes()
        .into_iter()
        .collect();
    let workspace_grant = std::env::var("FAE_TOOLHOST_WORKSPACE_GRANT")
        .ok()
        .map(|v| v.trim() == "1")
        .unwrap_or(false);
    if workspace_grant {
        scopes.insert(Scope::ToolWorkspaceGrant);
        println!(
            "workspace: durable-root grant ENABLED (FAE_TOOLHOST_WORKSPACE_GRANT). \
             toolhost.set_root is callable; each root still requires per-session owner approval."
        );
    }

    // Keep the resolved scope set so the rotation task can re-issue an identical
    // record with a fresh token + expiry (same trust model, new secret).
    let rotation_scopes = scopes.clone();
    let client = ClientRecord {
        client_id: fae_control_plane::BOOTSTRAP_CLIENT_ID.to_owned(),
        class: ClientClass::SwiftFrontend,
        scopes,
        issued_at_ms: now,
        expires_at_ms: now.saturating_add(THIRTY_DAYS_MS),
        revoked_at_ms: None,
        display_name: "Fae (this Mac)".to_owned(),
    };

    let mut registry = ClientRegistry::new();
    registry.insert(client, token_hash);
    let registry = Arc::new(registry);
    // Hot-swappable handle the Unix accept loop snapshots per connection. The
    // rotation task (below) republishes a fresh registry at token half-life so an
    // always-on daemon never loses auth for NEW connections after the 30-day
    // expiry. The opt-in diagnostic surface shares this same cell and snapshots
    // the CURRENT registry per request, so it follows rotations in lock-step.
    let registry_cell: transport::SharedRegistry = Arc::new(Mutex::new(Arc::clone(&registry)));
    {
        let cell = Arc::clone(&registry_cell);
        let token_path = token_path.clone();
        tokio::spawn(async move {
            rotation_loop(cell, token_path, rotation_scopes).await;
        });
    }
    let tickets = Arc::new(Mutex::new(TicketStore::new()));

    // On Linux the `.deb`/AppImage ship a reference `models.lock` beside the exe
    // but have no installer step to seed the per-user data dir (macOS does this
    // from the Swift app). Self-install it on first launch so the fail-closed
    // integrity gates below (engine, ASR, Piper TTS) have their lock.
    #[cfg(not(target_os = "macos"))]
    if let Err(detail) = ensure_models_lock_installed() {
        if models_lock_disabled_for_dev() {
            eprintln!(
                "fae-daemon: WARNING: models.lock self-install failed ({detail}); FAE_MODELS_LOCK=off allows continuing"
            );
        } else {
            exit_fatal("models_lock_install", &detail);
        }
    }

    let engine = build_engine().await;
    let info = engine.describe();
    println!("engine  : {} ({})", info.backend, info.model_id);
    let asr_fallback = build_asr_fallback_engine();
    if let Some(asr) = &asr_fallback {
        let info = asr.describe();
        // Parakeet loads eagerly (fail-closed fallback needs it); the llama.cpp
        // Qwen3-ASR lane is lazy.
        let state = if info.backend == "sherpa-onnx-parakeet" {
            "loaded"
        } else {
            "lazy"
        };
        println!("asr     : {} ({}) — {state}", info.backend, info.model_id);
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
    let model_mode = conductor_model_mode_from_env();
    let mut conductor_workers = conductor_worker_registry_from_env();
    // ADR-014 cloud lane: opt-in via FAE_PRIVACY_LANE=all + the OpenRouter env
    // contract (base URL + model + key). Present ⇒ register a RemoteProvider
    // worker and drive a real OpenRouter adapter behind the conductor egress
    // gates. Absent/any-other config keeps the mock provider — the daemon's
    // routing behavior is byte-for-byte unchanged unless the owner opts in.
    let conductor_cloud_lane = conductor_cloud_lane_from_env(model_mode);
    if let Some(lane) = &conductor_cloud_lane {
        conductor_workers.register_remote_provider(&lane.worker_id, true);
    }
    let conductor_policy = conductor::StaticDirectPolicy;
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
    let conductor_egress = match conductor_cloud_lane {
        Some(lane) => {
            // Model id only — the API key is never printed. It was moved into
            // the adapter and stays out of logs, the socket, and CloudRequest.
            println!(
                "conductor: cloud lane ENABLED — OpenRouter worker {} (RemoteAllowed)",
                lane.worker_id
            );
            let provider =
                std::sync::Arc::new(conductor::ProviderBackedCloudProvider::new(lane.adapter));
            conductor::ConductorEgress::production_with_provider(
                model_mode,
                budget_governor,
                provider_pricing,
                provider,
            )
        }
        None => {
            conductor::ConductorEgress::production(model_mode, budget_governor, provider_pricing)
        }
    };
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
    // A3: a clone of the conductor store for the per-session ToolHost audit sink
    // (toolhost_audit.jsonl). Cloned BEFORE `new_with_egress` moves the original;
    // both handles point at the same on-disk store dir.
    let toolhost_store = Arc::new(conductor_store.clone());
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
            // Share the rotatable registry cell (not the startup snapshot) so the
            // diagnostic surface follows bootstrap-token rotation in lock-step
            // with the Unix accept loop.
            registry: Arc::clone(&registry_cell),
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

    // A2.5: discover Fae's integrity'd skills once at startup. Default location
    // mirrors the Swift app (`<fae data dir>/skills`); `FAE_SKILLS_DIR` overrides
    // it. A missing dir yields an empty host (no skills) — never a startup error.
    // The skill lifecycle audit shares the conductor store (skillhost_audit.jsonl,
    // sibling to toolhost_audit.jsonl; NEVER fae.db).
    let skills_dir = std::env::var_os("FAE_SKILLS_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| conductor_data_dir.join("skills"));
    let skill_audit = std::sync::Arc::new(skillhost::audit::ConductorStoreSkillAudit::new(
        std::sync::Arc::clone(&toolhost_store),
    ));
    // Phase G4: usage counters persist next to the conductor store audit files
    // (skillhost_usage.json) so lifecycle curation survives daemon restarts.
    let usage_path = toolhost_store.dir().join("skillhost_usage.json");
    let skill_host = std::sync::Arc::new(skillhost::SkillHost::with_usage_path(
        skills_dir,
        skill_audit,
        usage_path,
    ));

    // Phase G3: external MCP tool tier. Declared servers only (`FAE_MCP_CONFIG`).
    // No env / no config => `None` (MCP silently absent). A malformed config is
    // loud (a typo must not silently disable a declared server) but never blocks
    // daemon startup. Spawned once here; the catalog is threaded into each
    // session's ToolHost so `mcp:<server>:<tool>` calls route through the gate.
    let mcp_catalog: Option<Arc<mcp::McpCatalog>> = match mcp::McpConfig::from_env() {
        None => None,
        Some(Ok(cfg)) => {
            let catalog = mcp::McpCatalog::spawn(&cfg).await;
            for h in catalog.health() {
                if h.healthy {
                    println!(
                        "fae-daemon: MCP server '{}' ({} tools)",
                        h.server, h.tool_count
                    );
                } else {
                    eprintln!(
                        "fae-daemon: MCP server '{}' unavailable: {}",
                        h.server,
                        h.note.as_deref().unwrap_or("unknown")
                    );
                }
            }
            if catalog.is_empty() {
                eprintln!("fae-daemon: MCP configured but no tools registered (check allowlists)");
            }
            Some(Arc::new(catalog))
        }
        Some(Err(e)) => {
            eprintln!("fae-daemon: MCP config error ({e}); MCP disabled");
            None
        }
    };

    // ── Phase E: x0x peer ingress (opt-in via FAE_X0X_INGRESS) ──────────
    // The SINGLE governed inbound entry point for peer content. `from_env`
    // returns `None` (ingress off) on any missing/invalid config, so the daemon's
    // behavior is unchanged unless the owner opts in. Discovery of our own agent
    // id + a reachable x0xd are required; any failure disables the lane loudly
    // but never blocks daemon startup. Returns the outbound handle threaded into
    // the socket serve (the `peer.*` commands need it).
    let peer_outbound = setup_peer_ingress(PeerIngressBackends {
        data_dir: conductor_data_dir.clone(),
        engine: Arc::clone(&engine),
        tts: Arc::clone(&tts),
        audio: Arc::clone(&audio),
        events: events.clone(),
        playbacks: playbacks.clone(),
        agents: agents.clone(),
    })
    .await;

    // Serves until the process is killed. Fails closed on bind/permission error.
    transport::serve_unix(
        socket_path,
        registry_cell,
        engine,
        asr_fallback,
        tts,
        audio,
        audit_path,
        events,
        playbacks,
        agents,
        conductor_runtime,
        toolhost_store,
        skill_host,
        mcp_catalog,
        peer_outbound,
    )
    .await?;
    Ok(())
}

/// Backends the peer ingress needs, cloned before `serve_unix` consumes the
/// originals.
struct PeerIngressBackends {
    data_dir: std::path::PathBuf,
    engine: Arc<dyn ProviderAdapter>,
    tts: Arc<dyn TtsAdapter>,
    audio: Arc<AudioManager>,
    events: events::EventBus,
    playbacks: events::PlaybackRegistry,
    agents: agents::AgentSessionRegistry,
}

/// Resolve `PeerConfig::from_env`, discover our agent id, spawn the ingress
/// supervisor, and return the outbound handle for the `peer.*` commands. Fully
/// fail-quiet: `None` ⇒ peer lane off, daemon proceeds normally.
async fn setup_peer_ingress(b: PeerIngressBackends) -> Option<Arc<peer::PeerOutbound>> {
    let cfg = peer::PeerConfig::from_env()?;
    let client = match peer::X0xPeerClient::new(cfg.base_url.clone(), cfg.token.clone()) {
        Ok(client) => client,
        Err(error) => {
            tracing::warn!("peer ingress disabled: client build failed: {error}");
            return None;
        }
    };
    // Reachability gate: if x0xd is not answering /health, do not spawn the
    // ingress (it would just backoff-loop). Fail-quiet — the owner can start
    // x0xd and restart the daemon.
    if !client.health().await {
        tracing::warn!(
            "peer ingress disabled: x0xd health probe failed ({})",
            cfg.base_url
        );
        return None;
    }
    let own_agent_id = match client.own_agent_id().await {
        Ok(id) => id,
        Err(error) => {
            tracing::warn!("peer ingress disabled: GET /agent failed: {error}");
            return None;
        }
    };
    let audit_path = b.data_dir.join("peer_envelope_audit.jsonl");
    let outbound = Arc::new(peer::PeerOutbound::new(
        client,
        own_agent_id.clone(),
        cfg.owner_fleet.clone(),
        audit_path.clone(),
    ));
    let deps = peer::PeerIngressDeps {
        engine: b.engine,
        tts: b.tts,
        audio: b.audio,
        events: b.events,
        playbacks: b.playbacks,
        agents: b.agents,
        audit_path,
    };
    // A never-cancelled token: the daemon runs the ingress for its whole life
    // (the process exit tears it down). The handle mirrors the toolhost cancel
    // pattern so a graceful-shutdown path can cancel it later.
    let cancel = tokio_util::sync::CancellationToken::new();
    let signing_mode = if cfg.allow_unsigned {
        "PERMISSIVE (FAE_X0X_ALLOW_UNSIGNED=1: unsigned envelopes flagged)"
    } else {
        "strict ML-DSA-65"
    };
    peer::PeerIngress::spawn(cfg, deps, Arc::clone(&outbound), cancel);
    let short: String = own_agent_id.chars().take(12).collect();
    println!(
        "peer    : x0x ingress ENABLED (agent {short}…, signatures {signing_mode}, \
         auto-reply gated by FAE_X0X_AUTO_REPLY)"
    );
    Some(outbound)
}

fn init_tracing() {
    let _ = tracing_subscriber::fmt().with_target(false).try_init();
}

fn conductor_model_mode_from_env() -> conductor::ModelMode {
    // ADR-014: FAE_PRIVACY_LANE is the authoritative cloud-lane selector.
    // local→pure-local, fleet→local-symphony, all→all-available (RemoteAllowed).
    // Missing OR unknown fails closed to pure-local. FAE_MODEL_MODE remains a
    // fallback for deployments predating the privacy selector.
    if let Some(raw) = first_non_empty_env(["FAE_PRIVACY_LANE"]) {
        let mode = conductor::ModelMode::from_privacy_lane(Some(&raw));
        // A present-but-unrecognized value fails closed to pure-local; surface it
        // rather than silently disabling a lane the owner meant to enable.
        let recognized = matches!(
            raw.trim().to_ascii_lowercase().as_str(),
            "local" | "fleet" | "all"
        );
        if !recognized {
            tracing::warn!(
                "unknown FAE_PRIVACY_LANE {raw:?}; failing closed to local (pure-local)"
            );
        }
        return mode;
    }
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

/// A constructed ADR-014 cloud lane: the vetted RemoteProvider worker id and the
/// real provider adapter (OpenRouter) to drive behind the conductor egress gates.
struct ConductorCloudLane {
    worker_id: String,
    adapter: std::sync::Arc<dyn ProviderAdapter>,
}

/// Build the cloud lane from the startup environment (ADR-014). Returns `Some`
/// ONLY when the owner opted into the RemoteAllowed cap (`FAE_PRIVACY_LANE=all` →
/// `AllAvailable`) AND the full OpenRouter contract is present. Any missing piece
/// keeps the local-only default (fail closed). The API key is moved into the
/// adapter and never logged, never printed, never placed on the NDJSON socket,
/// and never in a `CloudRequest`.
fn missing_openrouter_contract_fields(
    base_url: &Option<String>,
    model_id: &Option<String>,
    api_key: &Option<String>,
) -> Option<&'static str> {
    api_key.as_ref()?;
    match (base_url.is_none(), model_id.is_none()) {
        (true, true) => Some("FAE_REMOTE_BASE_URL, FAE_REMOTE_MODEL"),
        (true, false) => Some("FAE_REMOTE_BASE_URL"),
        (false, true) => Some("FAE_REMOTE_MODEL"),
        (false, false) => None,
    }
}

fn conductor_cloud_lane_from_env(mode: conductor::ModelMode) -> Option<ConductorCloudLane> {
    if mode != conductor::ModelMode::AllAvailable {
        return None;
    }
    let base_url = first_non_empty_env(["FAE_REMOTE_BASE_URL"]);
    let model_id = first_non_empty_env(["FAE_REMOTE_MODEL"]);
    let api_key = first_non_empty_env(["FAE_OPENROUTER_API_KEY"]);
    if let Some(missing_fields) = missing_openrouter_contract_fields(&base_url, &model_id, &api_key)
    {
        tracing::warn!(
            missing_fields,
            "FAE_OPENROUTER_API_KEY is set but the OpenRouter startup contract is incomplete; \
             cloud routing remains disabled"
        );
        return None;
    }
    let base_url = base_url?;
    let model_id = model_id?;
    let api_key = api_key?;
    let worker_id = conductor::workers::openrouter_worker_id(&model_id);
    let adapter = fae_engine::OpenRouterAdapter::new(fae_engine::OpenRouterConfig {
        base_url,
        model_id,
        api_key,
        // The specific OpenRouter model's window is not known from env; use the
        // conservative default (Phase G1).
        context_window: fae_engine::DEFAULT_OPENROUTER_CONTEXT_WINDOW,
    });
    Some(ConductorCloudLane {
        worker_id,
        adapter: std::sync::Arc::new(adapter),
    })
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
    // ADR-014: FAE_CLOUD_DAILY_BUDGET_MICROS caps rolling daily cloud spend
    // (micro-USD). Missing/invalid → the conservative default
    // (`BudgetLimits::default`, ~2.5M micros ≈ $2.50/day). LocalOnly routes
    // never consult this governor. Per-worker buckets stay available via
    // `conductor_worker_budget_limits_from_env`.
    let mut limits = conductor::BudgetLimits::default();
    if let Some(raw) = first_non_empty_env(["FAE_CLOUD_DAILY_BUDGET_MICROS"]) {
        match raw.trim().parse::<u64>() {
            Ok(micros) => limits.max_daily_cost_micros = micros,
            Err(_) => tracing::warn!(
                "invalid FAE_CLOUD_DAILY_BUDGET_MICROS; using conservative default daily cap"
            ),
        }
    }
    limits
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
            // ADR-014: OpenRouter remote-provider workers get a conservative
            // built-in price (`DEFAULT_OPENROUTER_PRICING`) so cloud egress is
            // never silently dead for lack of a pricing entry; other workers
            // keep the unit-price sentinel. `FAE_PROVIDER_PRICING` overrides both.
            let pricing =
                if worker_id.starts_with(conductor::workers::OPENROUTER_CLOUD_WORKER_PREFIX) {
                    conductor::pricing::DEFAULT_OPENROUTER_PRICING
                } else {
                    conductor::ProviderPricing {
                        input_micros_per_token: 1,
                        output_micros_per_token: 1,
                    }
                };
            table.insert(worker_id, pricing);
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
        // When `FAE_TTS_MODEL_ID` points at a LOCAL bundled Kokoro directory,
        // voice-tts loads it directly (no HuggingFace fetch, which 401s). Gate
        // that local bundle against models.lock (size + SHA-256), fail-closed.
        // The HF repo-id default is not verified here (voice-tts streams it).
        if Path::new(&model_repo).is_dir() {
            match verify_kokoro_artifacts(Path::new(&model_repo)) {
                Ok(()) => println!("tts     : kokoro local bundle {model_repo}"),
                Err(detail) => exit_fatal("kokoro_tts", &detail),
            }
        }
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
    if artifact.role != expected_role || artifact.loader != Loader::PiperSidecar {
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

/// Verify the bundled Kokoro model files (`config.json` + `kokoro-v1_0.safetensors`)
/// against `models.lock` (size + SHA-256). Mirrors the Linux Piper gate. macOS-only;
/// only invoked when the daemon loads a LOCAL bundled Kokoro directory (the HF
/// repo-id default is not gated). Fail-closed: any miss aborts. `FAE_MODELS_LOCK=off`
/// under `FAE_DEV` is the only escape, matching the Piper/engine gates.
#[cfg(target_os = "macos")]
fn verify_kokoro_artifacts(model_dir: &Path) -> Result<(), String> {
    if models_lock_disabled_for_dev() {
        eprintln!(
            "fae-daemon: WARNING: FAE_DEV allows FAE_MODELS_LOCK=off; skipping Kokoro artifact verification"
        );
        return Ok(());
    }
    let lock = load_installed_models_lock()?;
    verify_locked_kokoro_file(
        &lock,
        KOKORO_CONFIG_ARTIFACT_ID,
        &model_dir.join(KOKORO_CONFIG_FILENAME),
    )?;
    verify_locked_kokoro_file(
        &lock,
        KOKORO_WEIGHTS_ARTIFACT_ID,
        &model_dir.join(KOKORO_WEIGHTS_FILENAME),
    )?;
    Ok(())
}

/// Look up `id` in the lock, confirm its role + the `voice-tts` loader, then verify
/// the on-disk file's size + SHA-256 match the pinned artifact. Mirrors the Linux
/// [`verify_locked_file`] but for the macOS Kokoro (`voice-tts`) TTS lane.
#[cfg(target_os = "macos")]
fn verify_locked_kokoro_file(lock: &ModelsLock, id: &str, path: &Path) -> Result<(), String> {
    let artifact = lock
        .artifacts
        .iter()
        .find(|artifact| artifact.id == id)
        .ok_or_else(|| format!("missing required artifact {id}"))?;
    if artifact.role != "tts_model" || artifact.loader != Loader::VoiceTts {
        return Err(format!(
            "artifact {id} must be role=tts_model loader=voice-tts (got role={}, loader={})",
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
// Parakeet ASR (sherpa-onnx). NVIDIA parakeet-tdt-0.6b-v2 Int8 ONNX export,
// pinned to the csukuangfj/sherpa-onnx Hugging Face repo. The four artifacts
// (encoder/decoder/joiner Int8 ONNX + tokens) live under `models/parakeet` and
// are fail-closed verified (loader `"sherpa-onnx"`, size + SHA-256) by
// `locked_parakeet_path`. License CC-BY-4.0 (see THIRD_PARTY_LICENSES.md).
// All parakeet-only code is gated on the `parakeet` cargo feature (default on);
// without it these are absent and parakeet requests fall back to Gemma loudly.
#[cfg(feature = "parakeet")]
const PARAKEET_ASR_REPO: &str = "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8";
#[cfg(feature = "parakeet")]
const PARAKEET_ASR_REVISION: &str = "1ab9323565ddb038682214b292f588070a538ce2";
#[cfg(feature = "parakeet")]
const PARAKEET_ENCODER_ID: &str = "csukuangfj-parakeet-tdt-0-6b-v2-int8-encoder";
#[cfg(feature = "parakeet")]
const PARAKEET_DECODER_ID: &str = "csukuangfj-parakeet-tdt-0-6b-v2-int8-decoder";
#[cfg(feature = "parakeet")]
const PARAKEET_JOINER_ID: &str = "csukuangfj-parakeet-tdt-0-6b-v2-int8-joiner";
#[cfg(feature = "parakeet")]
const PARAKEET_TOKENS_ID: &str = "csukuangfj-parakeet-tdt-0-6b-v2-int8-tokens";
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

/// `models.lock` artifact ids for the bundled Kokoro-82M TTS model (macOS-only
/// TTS lane via voice-tts/mlx-rs). Only verified when the daemon is pointed at a
/// LOCAL bundled Kokoro directory (`FAE_TTS_MODEL_ID` = an existing dir); the HF
/// repo-id default streams from HuggingFace and is not integrity-gated here.
#[cfg(target_os = "macos")]
const KOKORO_CONFIG_ARTIFACT_ID: &str = "prince-canuma-kokoro-82m-config-json";
#[cfg(target_os = "macos")]
const KOKORO_WEIGHTS_ARTIFACT_ID: &str = "prince-canuma-kokoro-82m-safetensors";
#[cfg(target_os = "macos")]
const KOKORO_CONFIG_FILENAME: &str = "config.json";
#[cfg(target_os = "macos")]
const KOKORO_WEIGHTS_FILENAME: &str = "kokoro-v1_0.safetensors";

/// Build the inference backend. llama.cpp is now the only runtime path: the
/// daemon owns a `llama-server` sidecar and uses llama.cpp's `-hf` downloader to
/// fetch/cache the default Unsloth Gemma 4 12B GGUF on request. There is no
/// mistral.rs/candle fallback path in the runtime.
async fn build_engine() -> Arc<dyn ProviderAdapter> {
    if let Err(detail) = engine_selection() {
        exit_fatal("engine_selection", &detail);
    }
    // Dev/test-only: `FAE_ENGINE=mock` (validated FAE_DEV-gated in
    // `engine_selection`) swaps the real llama.cpp engine for a deterministic
    // scripted `MockAdapter` so a REAL daemon can serve the socket with NO model
    // — the substrate the Phase F live group-of-Fae proof spawns two of. Mirrors
    // `FAE_MODELS_LOCK=off`'s FAE_DEV gating: a production build fails closed in
    // `engine_selection` before reaching here, so it can never run a mock brain.
    if mock_engine_requested() {
        eprintln!(
            "fae-daemon: WARNING: FAE_DEV allows FAE_ENGINE=mock; serving a scripted \
             MockAdapter (NO model) — dev/test only"
        );
        return build_mock_engine();
    }
    build_llamacpp_engine().await
}

/// True when `FAE_ENGINE=mock` is requested. Gating (FAE_DEV) is enforced in
/// [`engine_selection`]; this only tests the value.
fn mock_engine_requested() -> bool {
    std::env::var("FAE_ENGINE").is_ok_and(|v| v.eq_ignore_ascii_case("mock"))
}

/// A deterministic scripted engine for the `FAE_ENGINE=mock` dev lane. Each
/// delegation loop consumes two scripted turns: (1) a `write` tool call that
/// overwrites the pre-committed `tracked.txt` inside the jailed workspace (so a
/// `git diff --name-only` in the workspace surfaces the mutation), then (2) a
/// final answer. Several pairs are queued so one daemon can serve multiple
/// sequential delegations before falling back to echo.
fn build_mock_engine() -> Arc<dyn ProviderAdapter> {
    const DELEGATIONS: usize = 8;
    let mut scripts: Vec<Vec<ChatEvent>> = Vec::with_capacity(DELEGATIONS * 2);
    for _ in 0..DELEGATIONS {
        scripts.push(vec![
            ChatEvent::ToolCall {
                name: "write".to_owned(),
                arguments:
                    "{\"path\":\"tracked.txt\",\"content\":\"changed by fae (mock delegate)\\n\"}"
                        .to_owned(),
            },
            ChatEvent::Done {
                finish_reason: "tool_calls".to_owned(),
            },
        ]);
        scripts.push(vec![
            ChatEvent::Token("delegated work complete".to_owned()),
            ChatEvent::Done {
                finish_reason: "stop".to_owned(),
            },
        ]);
    }
    Arc::new(MockAdapter::scripted("mock-delegate", scripts))
}

/// Select + build the daemon-owned dedicated ASR engine. Dispatches on the
/// `asr.engine` setting (`"parakeet"` via sherpa-onnx, or `"gemma"` via the
/// Qwen3-ASR llama.cpp sidecar — the default). Gated by `FAE_AUDIO_FALLBACK=0`.
///
/// `parakeet` constructs eagerly (the ONNX recognizer is loaded at build time)
/// so that an unloadable model is detected HERE and triggers a LOUD fallback to
/// the Gemma (Qwen3-ASR) pass-1 path — never a silent skip, never a mid-turn
/// crash. The eager load is the price of the fail-closed-fallback guarantee.
fn build_asr_fallback_engine() -> Option<Arc<dyn ProviderAdapter>> {
    if std::env::var("FAE_AUDIO_FALLBACK")
        .is_ok_and(|value| value == "0" || value.eq_ignore_ascii_case("false"))
    {
        return None;
    }
    match asr_engine_choice() {
        #[cfg(feature = "parakeet")]
        AsrEngine::Parakeet => match build_parakeet_asr_engine() {
            Some(adapter) => {
                eprintln!(
                    "fae-daemon: ASR engine = parakeet (sherpa-onnx, nvidia/parakeet-tdt-0.6b-v2 int8)"
                );
                Some(adapter)
            }
            None => {
                eprintln!(
                    "fae-daemon: ASR engine = parakeet requested, but the Parakeet model is \
                     missing/mismatched/unloadable — FALLING BACK to the Gemma (Qwen3-ASR) pass-1 \
                     path. Set asr.engine = \"gemma\" (or FAE_ASR_ENGINE=gemma) to silence this, or \
                     install the four Parakeet artifacts under {} (see THIRD_PARTY_LICENSES.md).",
                    parakeet_models_dir().display()
                );
                build_qwen3_asr_engine()
            }
        },
        AsrEngine::Gemma => build_qwen3_asr_engine(),
    }
}

/// Build the Gemma-class ASR engine — the Qwen3-ASR llama.cpp sidecar. Lazy: the
/// ~2.5 GB artifacts are downloaded + verified only if a fragile audio turn asks
/// for `audio.transcribe_fallback`.
fn build_qwen3_asr_engine() -> Option<Arc<dyn ProviderAdapter>> {
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
        // The ASR sidecar's 4K window makes its KV cache negligible; keep the
        // transcription pass exact regardless of the main-lane RAM tier.
        kv_cache_type: KvCacheType::F16,
        pidfile_root: run_directory().ok(),
    };
    Some(Arc::new(LazyLlamaServerAdapter::new(
        config,
        "qwen3-asr",
        std::time::Duration::from_secs(env_parsed("FAE_ASR_LLAMA_TIMEOUT_S", 180_u64)),
    )))
}

/// Build the Parakeet ASR engine (sherpa-onnx, nvidia/parakeet-tdt-0.6b-v2 int8
/// ONNX). All four artifacts are fail-closed verified against `models.lock`
/// (loader `"sherpa-onnx"`, size + SHA-256) before the recognizer is created.
/// Returns `None` on any failure so the caller can fall back to Gemma.
#[cfg(feature = "parakeet")]
fn build_parakeet_asr_engine() -> Option<Arc<dyn ProviderAdapter>> {
    let models_dir = parakeet_models_dir();
    let lock = match load_installed_models_lock() {
        Ok(lock) => lock,
        Err(detail) => {
            eprintln!("fae-daemon: parakeet ASR disabled; models.lock: {detail}");
            return None;
        }
    };
    let encoder =
        match locked_parakeet_path(&lock, PARAKEET_ENCODER_ID, "parakeet_encoder", &models_dir) {
            Ok(path) => path,
            Err(detail) => {
                eprintln!("fae-daemon: parakeet ASR disabled; {detail}");
                return None;
            }
        };
    let decoder =
        match locked_parakeet_path(&lock, PARAKEET_DECODER_ID, "parakeet_decoder", &models_dir) {
            Ok(path) => path,
            Err(detail) => {
                eprintln!("fae-daemon: parakeet ASR disabled; {detail}");
                return None;
            }
        };
    let joiner =
        match locked_parakeet_path(&lock, PARAKEET_JOINER_ID, "parakeet_joiner", &models_dir) {
            Ok(path) => path,
            Err(detail) => {
                eprintln!("fae-daemon: parakeet ASR disabled; {detail}");
                return None;
            }
        };
    let tokens =
        match locked_parakeet_path(&lock, PARAKEET_TOKENS_ID, "parakeet_tokens", &models_dir) {
            Ok(path) => path,
            Err(detail) => {
                eprintln!("fae-daemon: parakeet ASR disabled; {detail}");
                return None;
            }
        };
    match fae_engine::ParakeetAsrAdapter::new(encoder, decoder, joiner, tokens) {
        Ok(adapter) => Some(Arc::new(adapter)),
        Err(detail) => {
            eprintln!("fae-daemon: parakeet ASR disabled; sherpa-onnx load failed: {detail}");
            None
        }
    }
}

/// Resolve + fail-closed verify one Parakeet artifact from `models.lock`. Pins
/// loader `"sherpa-onnx"` and the Parakeet source repo/revision, then checks the
/// on-disk file's size + SHA-256. A missing/mismatched file is a hard error
/// (refuse to load) — the caller surfaces it as a loud Gemma fallback.
#[cfg(feature = "parakeet")]
fn locked_parakeet_path(
    lock: &ModelsLock,
    id: &str,
    expected_role: &str,
    models_dir: &Path,
) -> Result<PathBuf, String> {
    let artifact = lock
        .artifacts
        .iter()
        .find(|candidate| candidate.id == id)
        .ok_or_else(|| format!("missing required artifact {id}"))?;
    if artifact.role != expected_role {
        return Err(format!(
            "artifact {id} role mismatch: expected {expected_role}, got {}",
            artifact.role
        ));
    }
    if artifact.loader != Loader::SherpaOnnx {
        return Err(format!(
            "artifact {id} loader mismatch: expected sherpa-onnx, got {}",
            artifact.loader
        ));
    }
    if artifact.source_repo != PARAKEET_ASR_REPO
        || artifact.source_revision != PARAKEET_ASR_REVISION
    {
        return Err(format!(
            "artifact {id} pins unexpected source {}@{}",
            artifact.source_repo, artifact.source_revision
        ));
    }
    artifact
        .verify(models_dir)
        .map_err(|error| format!("artifact {id}: {error}"))?;
    Ok(artifact.resolved_path(models_dir))
}

/// The on-disk directory holding the four Parakeet artifacts. Overridable via
/// `FAE_PARAKEET_MODELS_DIR`; defaults to `<data>/models/parakeet`.
#[cfg(feature = "parakeet")]
fn parakeet_models_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("FAE_PARAKEET_MODELS_DIR") {
        return PathBuf::from(dir);
    }
    data_directory()
        .map(|dir| dir.join("models/parakeet"))
        .unwrap_or_else(|_| PathBuf::from("models/parakeet"))
}

/// The dedicated ASR engine to build, from `FAE_ASR_ENGINE` (highest precedence)
/// or the `[asr] engine` field of the data-dir `config.toml`; default `gemma`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AsrEngine {
    Gemma,
    #[cfg(feature = "parakeet")]
    Parakeet,
}

fn asr_engine_choice() -> AsrEngine {
    let raw = std::env::var("FAE_ASR_ENGINE")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(read_config_asr_engine)
        .unwrap_or_else(|| "gemma".to_owned());
    let requested_parakeet = raw.trim().eq_ignore_ascii_case("parakeet");
    #[cfg(feature = "parakeet")]
    {
        if requested_parakeet {
            return AsrEngine::Parakeet;
        }
    }
    #[cfg(not(feature = "parakeet"))]
    {
        // Parakeet was requested but this build was compiled WITHOUT the
        // `parakeet` feature (e.g. the zigbuild packaging lane). Never crash,
        // never silent: say so loudly and fall through to the Gemma lane below.
        if requested_parakeet {
            eprintln!(
                "fae-daemon: Parakeet ASR not compiled into this build — built without the \
                 `parakeet` feature; falling back to the Gemma (Qwen3-ASR) lane. Rebuild with \
                 `--features parakeet` (on by default) to enable it."
            );
        }
    }
    AsrEngine::Gemma
}

/// Read `[asr] engine` from the data-dir `config.toml`. `None` when the file is
/// absent, unparseable, or has no `[asr] engine`. Unknown fields are ignored so
/// the full Swift-era config schema parses cleanly.
fn read_config_asr_engine() -> Option<String> {
    #[derive(serde::Deserialize)]
    struct AsrSection {
        engine: String,
    }
    #[derive(serde::Deserialize)]
    struct ConfigRoot {
        #[serde(default)]
        asr: Option<AsrSection>,
    }
    let path = data_directory().ok()?.join("config.toml");
    let text = std::fs::read_to_string(&path).ok()?;
    let parsed: ConfigRoot = toml::from_str(&text).ok()?;
    let engine = parsed.asr?.engine;
    (!engine.trim().is_empty()).then_some(engine)
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

/// Trusted, in-process lock-path override set ONLY by the `--verify-runtime
/// --models-lock` CLI flag. It is never reachable from the process
/// environment — so a launchd/parent-process injection of
/// `FAE_MODELS_LOCK_PATH` cannot redirect verification at a crafted lock
/// matching a swapped model. A `RwLock<Option<PathBuf>>` (not `OnceLock`) is
/// deliberate: the test suite can reset it in `clear_fae_env()`, whereas a
/// process-global `OnceLock` can never be cleared — which would let the first
/// `--models-lock` test silently corrupt every later models-lock test.
static VERIFY_CLI_LOCK_PATH: std::sync::RwLock<Option<PathBuf>> = std::sync::RwLock::new(None);

fn load_installed_models_lock() -> Result<ModelsLock, String> {
    // Resolution order:
    // 1. Trusted CLI override (`--verify-runtime --models-lock`) — in-process
    //    only; the release-CI verifier's legitimate way to point the SAME
    //    checks at a specific lock (e.g. the re-signed bundle's copy).
    // 2. `FAE_MODELS_LOCK_PATH` env override — DEV ONLY, mirroring the
    //    `FAE_MODELS_LOCK=off` gate. A production build never honors an
    //    externally-injected lock path.
    // 3. The installed `<data>/models.lock` (normal operation).
    let dev = dev_mode();
    let cli_override = VERIFY_CLI_LOCK_PATH
        .read()
        // A poisoned lock means a panic held it mid-write; fail safe to "no
        // override" (→ installed lock) instead of propagating the panic.
        .map(|guard| guard.clone())
        .unwrap_or(None);
    let path: PathBuf = if let Some(cli_path) = cli_override {
        cli_path
    } else {
        let env_override = std::env::var_os("FAE_MODELS_LOCK_PATH");
        if env_override.is_some() && !dev {
            eprintln!(
                "fae-daemon: WARNING: ignoring FAE_MODELS_LOCK_PATH in production \
                 (set FAE_DEV=1 to honor it); using installed models.lock"
            );
        }
        match (env_override, dev) {
            (Some(override_path), true) => PathBuf::from(override_path),
            _ => data_directory()
                .map_err(|error| error.to_string())?
                .join("models.lock"),
        }
    };
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
    if artifact.loader != Loader::LlamacppSidecar {
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

/// `--verify-runtime` entrypoint (F21). Runs the SAME integrity checks the daemon
/// does at startup — llama-server digest (+ Piper artifacts on Linux) against the
/// installed/bundled `models.lock` — WITHOUT opening the socket or loading a
/// model. Returns `Err((component, detail))` on any drift so the caller can print
/// the `exit_fatal`-shaped JSON and exit 78. Optional flags:
/// - `--llama-server <path>`: verify this binary (else the resolved default).
/// - `--models-lock <path>`: verify against this lock (else the installed one).
///
/// `FAE_MODELS_LOCK=off` under `FAE_DEV` short-circuits the digest checks (same as
/// startup), which is intentional — a dev escape hatch, never a release path.
fn verify_runtime_cli(flags: &[String]) -> Result<(), (&'static str, String)> {
    let mut iter = flags.iter();
    while let Some(flag) = iter.next() {
        match flag.as_str() {
            "--llama-server" => {
                let value = iter.next().ok_or((
                    "verify_runtime",
                    "--llama-server requires a path".to_owned(),
                ))?;
                std::env::set_var("FAE_LLAMA_BIN", value);
            }
            "--models-lock" => {
                let value = iter
                    .next()
                    .ok_or(("verify_runtime", "--models-lock requires a path".to_owned()))?;
                // Route through the trusted in-process channel (not the env
                // var) so `--models-lock` works in release-CI without FAE_DEV,
                // while the external `FAE_MODELS_LOCK_PATH` env var stays
                // dev-gated. First value wins; passing the flag twice is an
                // operator error surfaced loudly.
                match VERIFY_CLI_LOCK_PATH.write() {
                    Ok(mut guard) => {
                        if guard.is_some() {
                            return Err(("verify_runtime", "--models-lock already set".to_owned()));
                        }
                        *guard = Some(PathBuf::from(value.as_str()));
                    }
                    Err(_) => {
                        return Err((
                            "verify_runtime",
                            "--models-lock: configuration lock poisoned".to_owned(),
                        ));
                    }
                }
            }
            other => {
                return Err((
                    "verify_runtime",
                    format!("unknown --verify-runtime flag: {other}"),
                ));
            }
        }
    }

    let binary = resolve_llama_server_binary().map_err(|detail| ("llamacpp_runtime", detail))?;
    verify_llama_server_binary(&binary).map_err(|detail| ("llamacpp_runtime_digest", detail))?;
    println!("fae-daemon: llama-server verified: {}", binary.display());

    #[cfg(not(target_os = "macos"))]
    {
        let install_dir = resolve_piper_install_dir().map_err(|detail| ("piper_tts", detail))?;
        let binary = install_dir.join("piper");
        let binary =
            executable_path(binary, "Piper runtime").map_err(|detail| ("piper_tts", detail))?;
        let voices_dir = install_dir.join("voices");
        let model_onnx = voices_dir.join(format!("{PIPER_VOICE_NAME}.onnx"));
        let model_config = voices_dir.join(format!("{PIPER_VOICE_NAME}.onnx.json"));
        verify_piper_artifacts(&binary, &model_onnx, &model_config)
            .map_err(|detail| ("piper_tts", detail))?;
        println!("fae-daemon: piper sidecar verified: {}", binary.display());
    }

    Ok(())
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
    if artifact.role != "asr_binary" || artifact.loader != Loader::LlamacppSidecar {
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

/// Probe for the packaged reference `models.lock` shipped beside the daemon exe
/// by the Linux installer, mirroring [`bundled_llama_server_path`]. The `.deb`
/// lays the lock at `/usr/lib/fae/models.lock`; the daemon exe is reached either
/// as `/usr/lib/fae/bin/fae-daemon` (FHS, via the `/usr/bin` symlink
/// `current_exe` resolves through) → `../models.lock`, or as a direct
/// `/usr/bin/fae-daemon` copy → `../lib/fae/models.lock`. The AppImage mirrors
/// the FHS payload, so `../models.lock` covers it too. Returns `None` when no
/// packaged copy exists (pre-install / dev tree).
#[cfg(not(target_os = "macos"))]
fn resolve_bundled_models_lock(exe_dir: &Path) -> Option<PathBuf> {
    for rel in ["../models.lock", "../lib/fae/models.lock"] {
        let candidate = exe_dir.join(rel);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

#[cfg(not(target_os = "macos"))]
fn bundled_models_lock_path() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    resolve_bundled_models_lock(exe.parent()?)
}

/// Seed or refresh `dest` from the `packaged` reference copy. Returns `Ok(true)`
/// when a copy was written, `Ok(false)` when nothing was done. The lock is
/// Fae-owned (never user-edited), so this mirrors the macOS Swift installer
/// (`DaemonLLMEngine.installBundledModelsLock`): on first install it seeds the
/// per-user lock, and on a package UPGRADE that bumps the runtime pins it
/// REPLACES the stale per-user lock whenever the packaged bytes differ — without
/// this, an upgraded runtime binary would fail the fail-closed digest gate on
/// every launch. A missing packaged copy is a no-op left for the downstream gate
/// to report (dev tree / pre-install). Writes go through a sibling temp file +
/// rename so a partial write can't leave a half-written lock the integrity gate
/// would then reject.
#[cfg(not(target_os = "macos"))]
fn install_bundled_models_lock(dest: &Path, packaged: Option<&Path>) -> Result<bool, String> {
    let Some(src) = packaged else {
        return Ok(false); // no packaged copy — downstream gate reports the miss
    };
    let packaged_bytes = std::fs::read(src)
        .map_err(|e| format!("read packaged models.lock {}: {e}", src.display()))?;
    if dest.is_file() {
        // Fae-owned lock: refresh only when the packaged reference has changed
        // (e.g. a runtime-bumping upgrade); byte-identical means nothing to do.
        match std::fs::read(dest) {
            Ok(installed) if installed == packaged_bytes => return Ok(false),
            Ok(_) => {}
            Err(e) => {
                return Err(format!(
                    "read installed models.lock {}: {e}",
                    dest.display()
                ))
            }
        }
    }
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("create data dir {}: {e}", parent.display()))?;
    }
    let tmp = dest.with_extension("lock.tmp");
    std::fs::write(&tmp, &packaged_bytes)
        .map_err(|e| format!("write packaged models.lock {}: {e}", src.display()))?;
    std::fs::rename(&tmp, dest)
        .map_err(|e| format!("install packaged models.lock → {}: {e}", dest.display()))?;
    Ok(true)
}

/// On Linux, self-install the packaged reference `models.lock` into the per-user
/// data dir. macOS ships this from the Swift app; the Linux `.deb`/AppImage have
/// no postinst/installer step, so the daemon seeds it itself before the
/// fail-closed integrity gate reads it. Seeds on first launch AND refreshes the
/// stale per-user lock after a package upgrade that bumps the runtime pins
/// (replace-on-diff — the lock is Fae-owned, never user-edited).
#[cfg(not(target_os = "macos"))]
fn ensure_models_lock_installed() -> Result<(), String> {
    let dest = data_directory()
        .map_err(|e| e.to_string())?
        .join("models.lock");
    if install_bundled_models_lock(&dest, bundled_models_lock_path().as_deref())? {
        println!(
            "models  : installed packaged models.lock → {}",
            dest.display()
        );
    }
    Ok(())
}

fn default_llama_cache_dir() -> Result<PathBuf, String> {
    Ok(data_directory()
        .map_err(|e| e.to_string())?
        .join("models/llamacpp"))
}

struct SharedLlamaServerSelection {
    root_url: String,
    model_id: String,
}

async fn resolve_shared_llama_server(
    requested_model_id: &str,
    explicit_model_id: bool,
) -> Option<SharedLlamaServerSelection> {
    let raw_url = env_path("FAE_LLAMA_SHARED_SERVER_URL")?;
    let root_url = match normalize_shared_llama_root_url(&raw_url) {
        Ok(url) => url,
        Err(detail) => {
            eprintln!(
                "fae-daemon: shared llama.cpp server ignored; invalid FAE_LLAMA_SHARED_SERVER_URL: {detail}"
            );
            return None;
        }
    };
    let timeout_ms = env_parsed("FAE_LLAMA_SHARED_SERVER_TIMEOUT_MS", 1500_u64);
    let model_ids = match probe_shared_llama_server(&root_url, timeout_ms).await {
        Ok(ids) => ids,
        Err(detail) => {
            eprintln!(
                "fae-daemon: shared llama.cpp server {root_url} unavailable ({detail}); falling back to Fae-owned sidecar"
            );
            return None;
        }
    };
    let model_id = select_shared_llama_model_id(requested_model_id, explicit_model_id, &model_ids);
    println!("engine  : llama.cpp — attaching to shared server {root_url} with model {model_id}");
    if !explicit_model_id && model_id != requested_model_id {
        eprintln!(
            "fae-daemon: shared llama.cpp server did not advertise default alias {requested_model_id:?}; selected advertised model {model_id:?}. Set FAE_MODEL_ID to pin a model."
        );
    }
    Some(SharedLlamaServerSelection { root_url, model_id })
}

fn normalize_shared_llama_root_url(raw_url: &str) -> Result<String, String> {
    let mut url = raw_url.trim().trim_end_matches('/').to_owned();
    if url.is_empty() {
        return Err("value is empty".to_owned());
    }
    if let Some(stripped) = url.strip_suffix("/v1") {
        url = stripped.to_owned();
    }
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err(format!("{raw_url:?} must start with http:// or https://"));
    }
    Ok(url)
}

async fn probe_shared_llama_server(root_url: &str, timeout_ms: u64) -> Result<Vec<String>, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_millis(timeout_ms))
        .build()
        .map_err(|error| format!("build HTTP client: {error}"))?;

    let health_url = format!("{root_url}/health");
    let health = client
        .get(&health_url)
        .send()
        .await
        .map_err(|error| format!("GET {health_url}: {error}"))?;
    let health_status = health.status();
    if !health_status.is_success() {
        return Err(format!("GET {health_url} returned {health_status}"));
    }

    let models_url = format!("{root_url}/v1/models");
    let models = client
        .get(&models_url)
        .send()
        .await
        .map_err(|error| format!("GET {models_url}: {error}"))?;
    let models_status = models.status();
    if !models_status.is_success() {
        return Err(format!("GET {models_url} returned {models_status}"));
    }
    let payload = models
        .json::<serde_json::Value>()
        .await
        .map_err(|error| format!("parse {models_url} JSON: {error}"))?;
    Ok(extract_llama_model_ids(&payload))
}

fn extract_llama_model_ids(payload: &serde_json::Value) -> Vec<String> {
    let mut ids = Vec::new();
    if let Some(models) = payload.get("data").and_then(serde_json::Value::as_array) {
        for model in models {
            push_unique_model_id(
                &mut ids,
                model.get("id").and_then(serde_json::Value::as_str),
            );
        }
    }
    if let Some(models) = payload.get("models").and_then(serde_json::Value::as_array) {
        for model in models {
            let id = model
                .get("model")
                .and_then(serde_json::Value::as_str)
                .or_else(|| model.get("id").and_then(serde_json::Value::as_str))
                .or_else(|| model.get("name").and_then(serde_json::Value::as_str));
            push_unique_model_id(&mut ids, id);
        }
    }
    ids
}

fn push_unique_model_id(ids: &mut Vec<String>, id: Option<&str>) {
    let Some(trimmed) = id.map(str::trim).filter(|value| !value.is_empty()) else {
        return;
    };
    let owned = trimmed.to_owned();
    if !ids.contains(&owned) {
        ids.push(owned);
    }
}

fn select_shared_llama_model_id(
    requested_model_id: &str,
    explicit_model_id: bool,
    advertised_model_ids: &[String],
) -> String {
    if explicit_model_id
        || advertised_model_ids.is_empty()
        || advertised_model_ids
            .iter()
            .any(|model_id| model_id == requested_model_id)
    {
        requested_model_id.to_owned()
    } else {
        advertised_model_ids
            .first()
            .cloned()
            .unwrap_or_else(|| requested_model_id.to_owned())
    }
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
    let explicit_model_id = env_path("FAE_MODEL_ID");
    let model_id = explicit_model_id
        .clone()
        .unwrap_or_else(|| DEFAULT_LLAMA_ALIAS.to_owned());

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

    if let Some(shared) = resolve_shared_llama_server(&model_id, explicit_model_id.is_some()).await
    {
        return Arc::new(LlamaServerAdapter::connect(
            shared.root_url,
            shared.model_id,
        ));
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
    // `FAE_LLAMA_LORA_GGUF` is a dev-only override (like `FAE_LLAMA_MODEL_GGUF`):
    // an un-gated, un-hashed adapter path here would bypass the Fae-owned
    // pinned/verified adapter loading. Production LoRA adapters arrive via the
    // governed `runtime.reload` path (validated + SHA'd), never this env knob.
    let lora_gguf = env_path("FAE_LLAMA_LORA_GGUF");
    if lora_gguf.is_some()
        && !std::env::var("FAE_DEV").is_ok_and(|v| v == "1" || v.eq_ignore_ascii_case("true"))
    {
        exit_fatal(
            "llamacpp_lora",
            "FAE_LLAMA_LORA_GGUF is dev-only; production loads personal adapters via the \
             governed runtime.reload path (validated + hashed)",
        );
    }
    // RAM-tiered KV-cache type (audit 2026-07-05 MEDIUM: fp16 KV below 32 GB
    // oversubscribes memory). `FAE_KV_CACHE=fp16|q8` forces either way; an
    // invalid value is a config error, mirroring `FAE_ENGINE` validation.
    let kv_cache_env = std::env::var("FAE_KV_CACHE").ok();
    let kv_cache_type = select_kv_cache_type(kv_cache_env.as_deref(), detect_total_ram_bytes())
        .unwrap_or_else(|detail| exit_fatal("kv_cache_config", &detail));
    let config = LlamaServerConfig {
        binary: binary.to_string_lossy().to_string(),
        model,
        lora_gguf,
        alias: alias.clone(),
        enable_thinking,
        mtp_draft_tokens,
        port: env_parsed("FAE_LLAMA_PORT", 18080),
        // Fae's base system prompt (37 tools + 30 skills + soul + directive +
        // memory) is ~6k tokens BEFORE any history, so an 8k window overflowed
        // after a few turns and every subsequent turn failed with "I hit a local
        // model problem". Gemma-4-E4B supports 128K; 32K is a safe memory
        // tradeoff. On macOS the Swift host is the RAM authority and passes a
        // RAM-scaled `FAE_LLAMA_CTX` (32768 / 16384 / 8192) that overrides this;
        // this raised default only applies to standalone/headless launches.
        ctx_size: env_parsed("FAE_LLAMA_CTX", 32_768),
        ngl: env_parsed("FAE_LLAMA_NGL", 999),
        kv_cache_type,
        pidfile_root: run_directory().ok(),
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
            "engine  : llama.cpp — lazy sidecar ready (repo {repo}@{revision}, base {}, mmproj {}, mtp {}, cache {}, kv-cache {}, alias {alias}, timeout {timeout_secs}s)",
            model.filename,
            mmproj.filename,
            mtp_draft
                .as_ref()
                .map_or("<off>", |artifact| artifact.filename.as_str()),
            cache_dir,
            config.kv_cache_type
        );
    } else {
        println!(
            "engine  : llama.cpp — lazy sidecar ready (model source {:?}, kv-cache {}, alias {alias}, timeout {timeout_secs}s)",
            config.model, config.kv_cache_type
        );
    }
    Arc::new(LazyLlamaServerAdapter::new(
        config,
        model_id,
        std::time::Duration::from_secs(timeout_secs),
    ))
}

/// Total physical RAM in bytes, best-effort. macOS: `sysctl -n hw.memsize`
/// (the same authority the Swift host uses via `physicalMemory`); Linux:
/// `MemTotal` from `/proc/meminfo`. `None` when detection fails —
/// [`select_kv_cache_type`] then keeps the exact fp16 default.
fn detect_total_ram_bytes() -> Option<u64> {
    #[cfg(target_os = "macos")]
    {
        let output = std::process::Command::new("/usr/sbin/sysctl")
            .args(["-n", "hw.memsize"])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        String::from_utf8(output.stdout).ok()?.trim().parse().ok()
    }
    #[cfg(target_os = "linux")]
    {
        let meminfo = std::fs::read_to_string("/proc/meminfo").ok()?;
        let kib: u64 = meminfo
            .lines()
            .find_map(|line| line.strip_prefix("MemTotal:"))?
            .trim()
            .trim_end_matches("kB")
            .trim()
            .parse()
            .ok()?;
        Some(kib.saturating_mul(1024))
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        None
    }
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
        // Dev/test-only scripted engine (Phase F live group-of-Fae proof). Fails
        // closed outside FAE_DEV so a production release can never run a mock
        // brain, mirroring `FAE_MODELS_LOCK=off`.
        Some("mock") => {
            if dev_mode() {
                Ok(())
            } else {
                Err(
                    "FAE_ENGINE=mock is a dev/test-only escape hatch; it requires FAE_DEV=1"
                        .to_owned(),
                )
            }
        }
        Some("mistralrs") => Err(
            "FAE_ENGINE=mistralrs was removed from the runtime path; Fae now uses \
             bundled llama.cpp + on-demand Unsloth Gemma 4 downloads only"
                .to_owned(),
        ),
        Some(other) => Err(format!(
            "unknown FAE_ENGINE={other:?} — valid values are 'llamacpp' (default) \
             and 'mock' (FAE_DEV only)"
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

/// How often the rotation task re-checks the bootstrap token's age. Far finer
/// than the ~15-day half-life at which rotation actually fires, so the token is
/// always refreshed with a full half-lifetime of slack.
const ROTATION_CHECK_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// Background task that keeps the always-on bootstrap token from expiring out from
/// under new connections. An always-on daemon has no restart to re-issue its
/// token; once the token passes half its lifetime this rotates it — rewriting the
/// `bootstrap.token` file the Swift frontend + orb bridge read and publishing a
/// fresh registry to `cell` — so reconnects, the TTS lane, and the orb bridge keep
/// authenticating past day 30. The trust model is unchanged: same client id, same
/// scopes, same owner-only file perms; only the secret + expiry roll forward.
async fn rotation_loop(
    cell: transport::SharedRegistry,
    token_path: PathBuf,
    scopes: HashSet<Scope>,
) {
    let mut interval = tokio::time::interval(ROTATION_CHECK_INTERVAL);
    loop {
        interval.tick().await;
        let due = {
            let guard = cell.lock().unwrap_or_else(PoisonError::into_inner);
            guard
                .record(fae_control_plane::BOOTSTRAP_CLIENT_ID)
                .map(|record| {
                    token_past_half_life(record.issued_at_ms, record.expires_at_ms, now_ms())
                })
                .unwrap_or(false)
        };
        if !due {
            continue;
        }
        match rotate_bootstrap(&cell, &token_path, &scopes) {
            Ok(()) => {
                println!("token   : rotated bootstrap token at half-life (new 30-day expiry)")
            }
            Err(error) => eprintln!("fae-daemon: bootstrap token rotation failed: {error}"),
        }
    }
}

/// Re-issue the bootstrap client with a fresh CSPRNG token + 30-day expiry: rewrite
/// the owner-only `bootstrap.token` file, then publish a registry that accepts the
/// new token. File-first so a client that reads the new token retries into a
/// registry that (a beat later) honours it; existing authenticated connections are
/// unaffected (they hold the registry snapshot they authenticated with).
fn rotate_bootstrap(
    cell: &transport::SharedRegistry,
    token_path: &Path,
    scopes: &HashSet<Scope>,
) -> DaemonResult<()> {
    let token = generate_token()?;
    let token_hash = hash_token(&token);
    let now = now_ms();
    let record = ClientRecord {
        client_id: fae_control_plane::BOOTSTRAP_CLIENT_ID.to_owned(),
        class: ClientClass::SwiftFrontend,
        scopes: scopes.clone(),
        issued_at_ms: now,
        expires_at_ms: now.saturating_add(THIRTY_DAYS_MS),
        revoked_at_ms: None,
        display_name: "Fae (this Mac)".to_owned(),
    };
    let mut registry = ClientRegistry::new();
    registry.insert(record, token_hash);
    write_secret_file(token_path, &token)?;
    let mut guard = cell.lock().unwrap_or_else(PoisonError::into_inner);
    *guard = Arc::new(registry);
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
            "FAE_LLAMA_SHARED_SERVER_URL",
            "FAE_LLAMA_SHARED_SERVER_TIMEOUT_MS",
            "FAE_MODELS_LOCK",
            "FAE_MODELS_LOCK_PATH",
            "FAE_AUDIO_FALLBACK",
            "FAE_ASR_LLAMA_CACHE_DIR",
        ] {
            std::env::remove_var(key);
        }
        // Reset the trusted CLI lock-path override so a `--models-lock` test
        // cannot leak into later models-lock tests (the RwLock is resettable,
        // unlike a OnceLock).
        if let Ok(mut guard) = VERIFY_CLI_LOCK_PATH.write() {
            *guard = None;
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
    fn missing_openrouter_contract_fields_reports_exact_missing_fields() {
        let base_url = Some("https://openrouter.ai/api/v1".to_owned());
        let model_id = Some("openai/gpt-4.1".to_owned());
        let api_key = Some("test-key".to_owned());

        assert_eq!(
            missing_openrouter_contract_fields(&None, &model_id, &api_key),
            Some("FAE_REMOTE_BASE_URL")
        );
        assert_eq!(
            missing_openrouter_contract_fields(&base_url, &None, &api_key),
            Some("FAE_REMOTE_MODEL")
        );
        assert_eq!(
            missing_openrouter_contract_fields(&None, &None, &api_key),
            Some("FAE_REMOTE_BASE_URL, FAE_REMOTE_MODEL")
        );
        assert_eq!(
            missing_openrouter_contract_fields(&base_url, &model_id, &api_key),
            None
        );
        assert_eq!(
            missing_openrouter_contract_fields(&None, &None, &None),
            None
        );
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

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn resolve_bundled_models_lock_finds_fhs_and_direct_layouts() {
        // FHS .deb: exe resolves to /usr/lib/fae/bin/fae-daemon (via the
        // /usr/bin symlink), lock at /usr/lib/fae/models.lock → ../models.lock.
        let root = tempfile::tempdir().unwrap();
        let fae = root.path().join("usr/lib/fae");
        std::fs::create_dir_all(fae.join("bin")).unwrap();
        std::fs::write(fae.join("models.lock"), b"schema_version = 1\n").unwrap();
        assert_eq!(
            resolve_bundled_models_lock(&fae.join("bin")).unwrap(),
            fae.join("bin/../models.lock")
        );
        // Direct copy: exe at /usr/bin/fae-daemon, lock still under
        // /usr/lib/fae → ../lib/fae/models.lock.
        std::fs::create_dir_all(root.path().join("usr/bin")).unwrap();
        assert_eq!(
            resolve_bundled_models_lock(&root.path().join("usr/bin")).unwrap(),
            root.path().join("usr/bin/../lib/fae/models.lock")
        );
        // No packaged copy on either probe path → None.
        assert!(resolve_bundled_models_lock(root.path()).is_none());
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn install_bundled_models_lock_seeds_and_refreshes_on_diff() {
        let root = tempfile::tempdir().unwrap();
        let packaged = root.path().join("packaged-models.lock");
        std::fs::write(&packaged, b"schema_version = 1\npackaged\n").unwrap();
        let dest = root.path().join("data/fae/models.lock");

        // First launch: seeds the per-user lock from the packaged copy.
        assert!(install_bundled_models_lock(&dest, Some(packaged.as_path())).unwrap());
        assert_eq!(
            std::fs::read(&dest).unwrap(),
            b"schema_version = 1\npackaged\n"
        );

        // Re-launch, packaged bytes unchanged: byte-identical → no-op.
        assert!(!install_bundled_models_lock(&dest, Some(packaged.as_path())).unwrap());
        assert_eq!(
            std::fs::read(&dest).unwrap(),
            b"schema_version = 1\npackaged\n"
        );

        // Package UPGRADE bumps the runtime pins → packaged bytes differ →
        // the Fae-owned per-user lock is refreshed so the digest gate passes.
        std::fs::write(&packaged, b"schema_version = 1\nupgraded\n").unwrap();
        assert!(install_bundled_models_lock(&dest, Some(packaged.as_path())).unwrap());
        assert_eq!(
            std::fs::read(&dest).unwrap(),
            b"schema_version = 1\nupgraded\n"
        );

        // No packaged copy and no per-user lock → no-op (downstream gate fatals).
        let missing = root.path().join("data2/fae/models.lock");
        assert!(!install_bundled_models_lock(&missing, None).unwrap());
        assert!(!missing.exists());
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
    fn models_lock_path_env_override_is_dev_only() {
        // Security gate (#1): a production build must load the INSTALLED lock
        // even when FAE_MODELS_LOCK_PATH is injected (launchd/parent), so a
        // crafted lock cannot redirect verification at a swapped model. Only
        // FAE_DEV honors the env override — mirroring FAE_MODELS_LOCK=off.
        let _g = _lock_env();
        clear_fae_env();
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("HOME", dir.path());

        // Installed lock carries "installed-marker"; a crafted override file
        // carries "override-marker".
        write_test_models_lock(
            dir.path(),
            &artifact_toml(
                "installed-marker",
                "asr_model",
                "installed.gguf",
                1,
                "0000000000000000000000000000000000000000000000000000000000000000",
            ),
        );
        let crafted = dir.path().join("crafted-override.lock");
        std::fs::write(
            &crafted,
            format!(
                "schema_version = 1\ncreated_at = \"test\"\n{}",
                artifact_toml(
                    "override-marker",
                    "asr_model",
                    "override.gguf",
                    2,
                    "1111111111111111111111111111111111111111111111111111111111111111",
                )
            ),
        )
        .unwrap();

        // PRODUCTION (no FAE_DEV): the injected override is ignored.
        std::env::set_var("FAE_MODELS_LOCK_PATH", &crafted);
        let loaded = load_installed_models_lock().expect("installed lock loads");
        assert!(
            loaded.artifacts.iter().any(|a| a.id == "installed-marker"),
            "production must ignore an injected FAE_MODELS_LOCK_PATH"
        );
        assert!(
            !loaded.artifacts.iter().any(|a| a.id == "override-marker"),
            "production must not honor an externally-injected lock path"
        );

        // DEV (FAE_DEV=1): the override IS honored — the escape hatch.
        std::env::set_var("FAE_DEV", "1");
        let loaded = load_installed_models_lock().expect("override lock loads in dev");
        assert!(
            loaded.artifacts.iter().any(|a| a.id == "override-marker"),
            "dev mode must honor FAE_MODELS_LOCK_PATH"
        );
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
    fn shared_llama_url_normalization_accepts_root_or_v1() {
        assert_eq!(
            normalize_shared_llama_root_url("http://127.0.0.1:8081").unwrap(),
            "http://127.0.0.1:8081"
        );
        assert_eq!(
            normalize_shared_llama_root_url("http://127.0.0.1:8081/v1/").unwrap(),
            "http://127.0.0.1:8081"
        );
        assert!(normalize_shared_llama_root_url("127.0.0.1:8081").is_err());
        assert!(normalize_shared_llama_root_url("   ").is_err());
    }

    #[test]
    fn shared_llama_model_ids_parse_router_and_single_model_shapes() {
        let router = serde_json::json!({
            "data": [
                { "id": "ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M" },
                { "id": "" }
            ]
        });
        assert_eq!(
            extract_llama_model_ids(&router),
            vec!["ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M".to_owned()]
        );

        let single = serde_json::json!({
            "models": [
                { "model": "gemma-4-e4b", "name": "ignored" },
                { "name": "fallback-name" },
                { "model": "gemma-4-e4b" }
            ]
        });
        assert_eq!(
            extract_llama_model_ids(&single),
            vec!["gemma-4-e4b".to_owned(), "fallback-name".to_owned()]
        );
    }

    #[test]
    fn shared_llama_model_selection_respects_explicit_model() {
        let advertised = vec!["actual-router-id".to_owned()];
        assert_eq!(
            select_shared_llama_model_id("gemma-4", false, &advertised),
            "actual-router-id"
        );
        assert_eq!(
            select_shared_llama_model_id("gemma-4", true, &advertised),
            "gemma-4"
        );
        assert_eq!(
            select_shared_llama_model_id("gemma-4", false, &[]),
            "gemma-4"
        );
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
