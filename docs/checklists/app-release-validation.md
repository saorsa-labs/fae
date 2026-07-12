# Fae App Release Validation Contract

Last updated: July 12, 2026

This is the canonical end-to-end validation contract for shipping Fae. It is the
**single** release-validation artifact: it carries both the release-readiness
checklist and the step-by-step live scenario script (the former standalone
CoWork-era scenario script was removed in the Great Cleanup and absorbed here).

Do not mark Fae, a model change, a prompt change, a routing change, a tool-policy change, or a UI refresh as release-ready unless this contract has been executed against the real app and the relevant scripted phases have passed.

If a capability exists in the product but is not covered by an automated or guided step below, add coverage in the same change before claiming production readiness.

## When this contract is mandatory

Run this full contract when any of the following changes:

- local text or vision model selection
- prompt templates, tool prompting, or tool repair logic
- voice capture, STT, wake logic, TTS, or playback timing
- permissions, approval popups, key input, or security/export review
- memory capture/recall or scheduler behavior
- skills management or Python-runtime integration
- JSC tool-program runtime, typed adapters, batch approval, or dry-run mode
- Rust orb UI shell, orb visibility/state bridge, right-click menu, or webview/browser panel behavior
- accidental restoration of Cowork/canvas as product UI surfaces
- legacy dual-model or concierge compatibility changes
- settings that affect loaded models, policy, or diagnostics
- **learned-conductor surfaces: routing policy/recipes, reward aggregation, shadow routing, the content-aware task classifier, recipe mutation, or the fae-metaopt boundary**
- **daemon ToolHost routing (B-Swift Layer 3): the `read`-to-daemon routing slice, workspace-root provisioning/auto-approve, path confinement, or the `DaemonToolHostSession` persistent-connection wiring**
- **cloud lane (ADR-014): `llm.privacyLane`, `llm.cloudDailyBudgetUSD`, API key Keychain path, daemon spawn env injection (`FAE_REMOTE_*`, `FAE_OPENROUTER_API_KEY`), or fallback surfacing**
- **x0x peer ingress / handoff / trust-decision quarantine, the MCP tool tier, the delegate (`fae.delegate`) / symphony-runner agentic loop, or conversation-compaction behavior**
- any release candidate build

## Required environment

1. Clean native build and real app launch with `just run-native` or `just rebuild`.
2. Rust orb shell validation with `just check-ui-shell` and a live `just run-ui-shell` smoke test whenever UI shell code changes.
3. Test-server launch with `just test-serve`.
3. Chatterbox available for real audio playback on `http://127.0.0.1:8000`.
4. Screenshot evidence captured from the live app during validation.
5. Relevant `tests/comprehensive/specs/*.yaml` phases run and archived.

## Evidence required

For every release-validation run, retain:

- latest comprehensive JSON report from `tests/comprehensive/reports/`
- screenshots for startup, onboarding, permissions, Rust orb shell states, right-click orb menu, browser/data panel, and any failing state
- test-server evidence from `/status`, `/conversation`, and `/events` for failures
- notes of any manual-only checks and their outcome

Suggested screenshot root:

- `/tmp/fae-live-check/`

## Run order

1. Clean build and model verification.
2. Scripted infrastructure and policy phases.
3. Rust orb shell live validation.
4. Legacy main-window live validation while migration remains incomplete.
5. Settings, scheduler, skills, and popup validation.
6. Confirm Cowork/canvas do not appear as product UI surfaces.
7. Final regression rerun after fixes.

## Preflight

- [ ] `just rebuild` or `just run-native` launches exactly one real Fae app bundle.
- [ ] `just check-ui-shell` passes when `native/rust/fae-ui-shell` changed.
- [ ] `just run-ui-shell` launches the Rust orb shell when UI shell behavior is in scope.
- [ ] `just test-serve` exposes `/health` on `127.0.0.1:7433`.
- [ ] The active local text model and configured vision model are visible in Settings without truncation.
- [ ] The runtime reports the expected local text model, context size, tool mode, and llama.cpp source (`FAE_LLAMA_SHARED_SERVER_URL` attached shared server vs Fae-owned sidecar).
- [ ] With port 18080 held by a `llama-server` from another Fae app-bundle path, daemon startup fails loud with the real listener PID/executable, explains the cross-install mismatch, and recommends `just kill-stale-sidecars`; it never kills the mismatched process automatically.
- [ ] `just kill-stale-sidecars` defaults to a dry-run, lists only executables ending in `/Fae.app/Contents/Resources/LlamaCpp/llama-server`, leaves `/opt/homebrew/bin/llama serve` and bare/non-Fae llama processes untouched, and requires the explicit `kill` action before TERM → grace → KILL.
- [ ] The active local text model matches `FaeConfig.recommendedModel()`. Active (Qwen fallback — Gemma 4 pending mlx-swift-lm): `Qwen3.5-9B-Unsloth` (≥16 GB) / `Qwen3.5-4B` (8–15 GB) / `Qwen3.5-2B-OptiQ` (<8 GB). Target (Gemma 4, not yet available): `E4B` (16–31 GB) / `E2B` (<16 GB) / `26B-A4B` (≥32 GB).
- [ ] On a cache-cleared or clean-install machine, first local text-model load completes without `Worker command timed out: load` while model download is in progress.
- [ ] Any stale onboarding, memory, scheduler, or approval state needed for the scenario is reset intentionally through the test server.

## Scripted harness phases

These phases are the minimum scripted baseline:

- [ ] `00-infrastructure`
- [ ] `01-baseline`
- [ ] `02-core-tools`
- [ ] `03-memory`
- [ ] `04-self-config`
- [ ] `05-skills`
- [ ] `06-scheduler`
- [ ] `07-permissions`
- [ ] `08-voice-commands`
- [ ] `09-conversation`
- [ ] `10-policy-profiles`
- [ ] `11-voice-pipeline`
- [ ] `12-onboarding`
- [ ] `14-dual-model` (legacy compatibility coverage only when that path is intentionally touched)

Acceptance:

- [ ] All required phases pass on the shipping bundle.
- [ ] Any failure is either fixed or captured as an explicit release blocker.
- [ ] If a capability changed and no phase covers it, a new phase or deterministic test is added in the same change.

## Rust orb shell scenarios

These scenarios are mandatory for the new canonical UI shell once it is included in a release candidate, and mandatory immediately for shell-only changes.

- [ ] Quiescent state has no visible animated orb and no continuous redraw loop.
- [ ] Startup/model-loading status appears through the orb itself, including progress affordance, with no separate startup shell.
- [ ] Thinking/speaking states show the orb and resume rendering only while active; idle/listening remain visually quiescent.
- [ ] The orb window is frameless, transparent, movable, and visually reads as just the orb.
- [ ] Right-click on the orb opens the Fae menu.
- [ ] Default menu (9 items): Talk to Fae · Settings… · [Hand off submenu if fleet non-empty] · Reset Conversation · Hide Fae · Stop · Ask Fae for Help · Rescue Mode… · Quit Fae. Engineering items (Scheduler, Skills, Edit Soul, Edit Custom Instructions, permissions ×6, Memory Inbox) are NOT present unless `ui.advancedMenus = true` in config (applies at next launch).
- [ ] Rust shell menu does not include Cowork or Open Work with Fae.
- [ ] Stop, Hide, and Quit perform their expected action.
- [ ] Open Browser/Data Panel opens an orb-launched browser/webview surface for charts, data, documents, and video.
- [ ] Scheduler and Skills open orb-owned temporary panels rather than Cowork.
- [ ] Rich output does not require a permanent canvas or Cowork surface.
- [ ] Screenshots capture quiescent, startup/progress orb, thinking/speaking orb, Messages panel, right-click menu, and browser/data panel.

## Legacy main Fae window scenarios

The Swift main window scenarios remain required while the live pipeline is still hosted by the Swift shell. They become legacy migration checks once the Rust orb shell bridge owns startup and command routing.

### Startup and first impression

- [ ] Startup lands on one coherent main surface, not a stray empty canvas.
- [ ] The screen tells a new user what Fae is for within 3 seconds.
- [ ] On a true first run after license acceptance, the startup intro/crawl appears exactly once while Fae finishes loading.
- [ ] The orb/visual focus feels calm and intentional rather than blurry or noisy.
- [ ] The main window can be resized and moved without layout breakage.
- [ ] A clean-install or cache-cleared first launch can wait through local model download without failing the pipeline or dropping local worker diagnostics into an error state.
- [ ] The default local startup path is the single-model Qwen3.5 flow, not an implicit dual-model / concierge boot path.
- [ ] On subsequent launches of an already-initialized install, the startup intro does not reappear.
- [ ] Startup progress remains visible through download, model load, verification, and first-response warmup instead of disappearing on a timer.
- [ ] The live conversation surface does not unlock early; input becomes available only after the pipeline is actually ready to respond.

### Onboarding and enrollment

- [ ] `Let me get to know you` uses real audio recording, not injected text.
- [ ] Three real audio enrollment samples can be recorded end to end.
- [ ] Enrollment completion removes the onboarding CTA immediately.
- [ ] Post-enrollment owner state is visible in `/status`.

### Voice input and output

- [ ] Fae can hear real audio input through the native recorder.
- [ ] Fae speaks replies audibly through the configured TTS path.
- [ ] Voice listening starts promptly enough to catch the intended utterance.
- [ ] Saying `stop`, `be quiet`, or `that's enough` while Fae is speaking stops playback promptly and leaves Fae quietly listening in the background instead of re-answering.
- [ ] Wake-word clipping does not cause normal owner follow-up speech to be ignored.
- [ ] During an active conversation, a short pause does not force the user to say the wake phrase again before continuing.
- [ ] When Fae finishes speaking, an owner utterance that starts promptly afterward is still captured rather than being dropped in a post-playback dead zone.
- [ ] Continuation cues such as `wait`, `hold on`, or `let me check` are treated as the same turn rather than an immediate handoff back to idle.
- [ ] After an explicit quiet request, ordinary owner speech does not wake Fae again until a wake phrase or wake-name address is used.
- [ ] Typing can continue while listening remains active.
- [ ] A spoken long-form request produces a substantial answer when appropriate, not an over-compressed reply.

### Text and conversation quality

- [ ] A trivial typed prompt gets a timely, relevant answer.
- [ ] A longer essay-style request gets a comprehensive answer when asked.
- [ ] Overlapping turns are handled cleanly without silent drops or permanent `Thinking...`.
- [ ] When a turn enters a thinking phase, the conversation surface shows the crawl panel before reply streaming begins.
- [ ] When a thinking phase finishes, the crawl collapses cleanly and leaves a replayable thinking icon tied to that turn.

### Tools, approvals, and popups

- [ ] Read-only tools work in allowed modes.
- [ ] Mutating tools work only in allowed modes.
- [ ] Approval popups appear when required and match actual pending approval state.
- [ ] Deny paths actually deny side effects.
- [ ] Key/input popups accept and return entered values correctly.
- [ ] macOS permission prompts are understandable and unblock the intended feature.
- [ ] Tool access copy is trustworthy and not hallucinatory.
- [ ] First-use vision turns (`screenshot`, `camera`, `read_screen`) can wait through capture and VLM load/inference without failing on an internal tool timeout.

### Daemon ToolHost routing (B-Swift Layer 3)

Layer 3 makes the governed daemon ToolHost **reachable** on the live app for the
first time. 3a provisions Fae's default workspace (`~/Documents/Fae`) and
auto-roots it on a persistent session; 3b routes `read` to the daemon, confined
to that workspace. `write`/`edit`/`bash` stay local until Layer 4 provisions the
server-side dangerous scope. Validate the live boundary:

- [ ] A `read` of a file **inside** `~/Documents/Fae` executes in the daemon (governed/audited), and its content returns to the conversation.
- [ ] A `read` of an **absolute** path, a `..` traversal, or a symlink that escapes the workspace is **denied** with a clear error and never reaches the daemon.
- [ ] `write`/`edit`/`bash` and Apple/scheduler tools **stay local** — no `toolhost.execute` frame for them.
- [ ] One persistent daemon session/connection is **reused** across multiple reads (no reconnect per call).
- [ ] With the daemon **absent** (unbundled / not running), `read` falls back to the existing local behavior (low-risk; was always local).
- [ ] If the daemon drops **before** the workspace root is approved, the read **fails closed** — never reads locally on an un-approved root that bypasses the server root guard.
- [ ] The workspace root is the Fae-owned default (`~/Documents/Fae`) — **never inferred from a requested file path** (a `read /etc/passwd` must not become "approve /etc as root").
- [ ] Routing never auto-approves `tool.confirm` (only the default `workspace.confirm_root` is auto-approved, marker-gated — 3a's job).
- [ ] No-double-approval: a daemon-routed `read` does not also surface the Swift DamageControl card.

### Memory, scheduler, and skills

- [ ] Memory capture and recall work from the main window.
- [ ] Session search can recover a prior conversation after a conversation reset, with transcript snippets that match what was actually said.
- [ ] Memory Inbox supports pasted text, file import, and URL import in the real app.
- [ ] Files dropped into `~/Library/Application Support/fae/memory-inbox/pending/` can be ingested by the scheduler or manual trigger path.
- [ ] Asking Fae what she learned recently surfaces digest-first recall before raw supporting memories.
- [ ] Recall output shows trustworthy provenance labels for imported artifacts or derived digests.
- [ ] Scheduler list/create/update/delete/trigger flows work.
- [ ] Skills list/add/edit/remove/execute flows work.
- [ ] With a second trusted x0x machine online and connect forwarding enabled, the `collaborate` skill can add a numeric-loopback tailnet forward, carry bytes through it, list the exact mapping, and remove the listener.
- [ ] Two trusted x0x agents can create/join a replicated store, set/get the same text value across agents, list its key, and replicate its removal.
- [ ] Staged skill drafts can be listed, inspected, and only applied or dismissed after explicit user confirmation.
- [ ] Any generated or edited artifacts appear where the UI says they will.

### x0x peer mesh

Validate the governed peer ingress + handoff path (Phase E + the
`trust_decision` quarantine). These run only with `FAE_X0X_INGRESS` set and a
reachable `x0xd`.

- [ ] With ingress misconfigured (missing `FAE_X0X_*` / unreachable `x0xd`), ingress is OFF — `peer.*` commands refuse and no SSE task starts (fail-closed, never an error surface).
- [ ] Every inbound envelope is run through `gate_and_audit` BEFORE dispatch; a bad signature/shape/algorithm is dropped at the gate and never reaches the event bus.
- [ ] A transport sender that does not match the signed sender is rejected (cross-check), even if the envelope itself is well-formed.
- [ ] A `direct_message` from a peer whose `trust_decision` is `accept_with_flag` is QUARANTINED (not surfaced as a normal message) until an owner consent decision is recorded via `peer.consent_respond`.
- [ ] `peer.send` delivers a plain-text `direct_message`; `peer.handoff_send` round-trips a `session_handoff` payload (decode + 64 KiB cap); an oversized or unknown-field handoff is rejected.
- [ ] Ingress reconnects with jittered exponential backoff after a dropped SSE connection, without spinning or flooding.

### Delegate (`fae.delegate`) + symphony runner

Validate the daemon's native jailed agentic loop and the symphony runner
(Phase F1/F2). `fae.delegate` runs generate → execute-tool → feed-back with a
restricted toolset, OS-jailed `ToolOrigin::Delegated`, and hard budgets.

- [ ] A delegated turn executes only tools in the delegated `toolset` allowlist; a tool outside the allowlist is denied, not silently invoked.
- [ ] Every delegated tool call is OS-jailed (`ToolOrigin::Delegated`) and audited like a host tool call.
- [ ] Tripping the iteration ceiling (`MAX_ITERATIONS_CEILING`) or the cumulative token budget yields a `budget_exhausted` status with a PARTIAL receipt — not a hang or a silent truncation.
- [ ] A delegated agent's mid-turn client callbacks work: `session/request_permission` surfaces an approval and `fs/read_text_file` / `fs/write_text_file` round-trip a file, and the loop resumes correctly from the client's answer.
- [ ] A parallel leaf batch (Phase F2 orchestrator fan-out) executes under the engine permit without concurrent-engine contention and reassembles in order.
- [ ] The symphony runner (`fae-symphony-runner`) drives a multi-step delegated composition end to end and terminates cleanly on completion or budget exhaustion.

### MCP tool tier

Validate the external-MCP tool tier (Phase G3). MCP servers are owner-declared
subprocesses with the daemon's AMBIENT authority — the OS jail does NOT confine
them — so the entire gate is declaration + allowlist + scope + origin.

- [ ] With no `FAE_MCP_CONFIG`, MCP is silently absent: `mcp.list` returns an empty catalog and any `mcp:` invocation denies `mcp_not_configured` (never spawns a server).
- [ ] A tool the server offers but the owner did not `allowed_tools`-list is never registered; invoking it denies `mcp_tool_not_declared`.
- [ ] `Scope::McpInvoke` is re-checked per call; an `mcp:` invoke without the scope denies fail-closed.
- [ ] Only `OwnerInteractive` and `Delegated` origins may invoke MCP; a proactive / scheduler / auto-skill / script-block origin denies fail-closed (no autonomous loop reaches an unconfined external process).
- [ ] A server that dies AFTER startup makes its `invoke` return a typed `McpError::Invoke`; the catalog is not re-listed until daemon restart (v1: no reconnect).
- [ ] `mcp.list` surfaces per-server health and records why a failed server's tools are absent.
- [ ] The trust model is honest in diagnostics: an MCP invoke is surfaced as an external unconfined tool, not as a jailed host tool.

### Conversation compaction

Validate context-compaction planning (Phase G1/G2). The delegate child loop is
the only daemon-owned history that can outgrow a model's context window.

- [ ] A long delegated conversation crosses the 80% compaction ceiling and compaction fires (oldest turns folded into a summary); the most-recent `RETAINED_TAIL_MESSAGES` (4) turns are kept verbatim.
- [ ] Once a summary is pinned, the main lane assembles prompts as `system ++ pinned_summary ++ kept_turns`; between recompactions `system` and `pinned_summary` are byte-identical so the serving prefix cache keeps hitting (the stable-prefix invariant).
- [ ] Hysteresis holds: compaction does not re-fire on every single turn after the first crossing (waits `RECOMPUTE_EVICTION_THRESHOLD` further turns, or a hard tail-over-budget trip).
- [ ] Compaction produces a faithful summary (not a silent hard-truncate); if the summarizer is unavailable the behavior is surfaced (logged + retained), not silent data loss.
- [ ] The pure planner (`plan_compaction`, `estimate_tokens`, `PromptBudget`) unit tests pass — they are the exhaustive correctness boundary.

## Cowork scenarios (removed)

CoWork was removed from the product in the Great Cleanup (2026-06-11). The historical scenarios were removed with it (see git history). The only remaining CoWork-related checks are the anti-restoration guards above (Cowork/canvas must NOT appear as product UI surfaces).

## Settings and diagnostics scenarios

- [ ] Settings clearly show the active local text model and configured vision model without clipping.
- [ ] Diagnostics surface worker health, route, restart count, and last error correctly. If legacy dual mode is explicitly enabled, concierge diagnostics remain coherent.
- [ ] Theme appearance follows the system appearance unless intentionally overridden.
- [ ] Privacy/security settings match the actual runtime behavior under test.

## Accessibility scenarios

- [ ] Main window controls are reachable and understandable with accessibility labels.
- [ ] Return-to-send and Shift-Return-for-newline behaviors work where documented.
- [ ] Small targets, truncation, and low-contrast areas have been reviewed live.
- [ ] A live VoiceOver pass has been completed before release.

## Learned conductor (chain) release-validation blockers

The learned conductor ships with `direct` topology byte-identical to the legacy
path (proven in M1). `chain` topology (Thinker → Worker → Verifier) is
**triple-gated dormant** in M1: the `FAE_CONDUCTOR_CHAIN` env flag + a vetted
chain recipe must be loaded + `chain_enabled` must be true. Before
`FAE_CONDUCTOR_CHAIN` is ever enabled for real users, ALL of the following must
be fixed and re-validated (see `docs/research/fae-learned-conductor-m2-decisions-2026-06-22.md` D-M2-2):

- [ ] **Generating-event pair.** `run_chain` calls `run_turn` directly, not
  `inject_text_core`, so the `assistant.generating {active:true/false}` pair is
  never published — the orb host's generating indicator breaks. Chain must
  publish the paired signal exactly like the direct path.
- [ ] **NaN-logits retry.** Same root cause: the Metal NaN retry loop lives in
  `inject_text_core`. A NaN-triggering chain turn fails where direct recovers.
- [ ] **Verifier FAIL-branch leaks the verdict.** On FAIL the full verifier
  body (`FAIL\n<reason>\n<corrected answer>`) is surfaced; strip the leading
  verdict line so the user sees only the corrected answer.
- [ ] **`max_tokens` hardcoded at 1024** per chain role-call — must be
  recipe/budget-governed.
- [ ] **ACP egress classification resolved** (D-M2-1): no ACP worker may be
  routed as Tier A / `LocalOnly`; cloud-backed ACP maps to a non-local lane and
  Tier B/C with budget governance. "Local process ≠ local data."

Until these pass, `FAE_CONDUCTOR_CHAIN` stays unset and no chain recipe is
loaded.

## Egress coverage + cost authority

- [ ] **NOTE-2: route `agent.run`/`agent.prompt` through the conductor (M2 Stage 3 prerequisite).** These commands (`crates/fae-daemon/src/session.rs` ~430/~500) pre-date the M2 §5 gate pipeline and reach `fae_acp`/cloud providers DIRECTLY, bypassing mode cap / PII membrane / budget / approval. Before any `all-available` default cutover, ALL daemon egress surfaces must fall under §5. (Advisor-prioritized next work — this is a gap in the safety story, not a feature.)

**Cost authority is external (owner decision 2026-06-23):** provider-side spend caps (OpenAI/Anthropic/etc.) are the authoritative cost control. The conductor makes NO spend guarantee; `FAE_PROVIDER_PRICING` + the `budget.rs` cost dimensions are an optional opt-in governance layer for operators who want conductor-level cost limits, not a billing promise. Operator/provider caps are an external responsibility and are NOT validated by this checklist.

**`fae-metaopt` wiring gate (M3 BLOCKER-1 sequencing constraint, 2026-06-24):** the `fae-metaopt` crate is **dormant/unwired** (zero refs from `fae-daemon`, not in its Cargo.toml) and contains a real latent config-write hole — `optimizer.rs:309-323` writes unlisted config keys unconditionally, bypassing `ConfigBound` validation (so `FAE_MODEL_MODE` is writable if the crate were wired in). The M3 spec mandates an `is_protected_config_key()` denylist to close it; **that denylist does not exist in code yet.** **Hard rule:** `fae-metaopt` MUST NOT be wired into the daemon (no Cargo dependency, no `apply_change` call site) until the protected-key denylist exists and its tests pass. Wiring it first ships the live hole. Verify with: `grep -rn fae-metaopt crates/fae-daemon/` (must be empty) until the denylist lands.

## Release gate

Do not claim production readiness unless all of the following are true:

- [ ] The scripted phases relevant to the change pass on the shipping bundle.
- [ ] Main-window live validation passes.
- [ ] Audio input and output are validated with real audio, not text injection.
- [ ] Required screenshots and failure evidence are captured.
- [ ] Docs were updated for any user-visible or policy-visible behavior change.
- [ ] Any remaining issue is explicitly recorded as a blocker rather than silently waived.

## Mapping to commands

Use these commands as the baseline workflow:

```bash
just rebuild
just test-serve
bash scripts/test-comprehensive.sh --skip-llm
bash scripts/test-comprehensive.sh --skip-llm --phase 11
bash scripts/test-comprehensive.sh --skip-llm --phase 12
```

For live UI validation, keep using the real app plus screenshots, the test server, and real audio playback through Chatterbox.

## Model switching and RAM-tier validation

- Verify Settings model changes do not require a full app restart.
- In Settings, switch from one cached local model to another and confirm the pipeline reloads in-app and returns to `running`.
- If selecting an uncached model, verify the app communicates that the model will download during the reload flow and that the current session is replaced only by the new pipeline, not by a full application restart.
- Validate `Auto (Recommended)` model selection against available RAM tiers (per `FaeConfig.recommendedModel()`):
  - Active (Qwen — Gemma 4 pending mlx-swift-lm): `<8 GB` → Qwen3.5 2B, `8-15 GB` → Qwen3.5 4B, `16+ GB` → Qwen3.5 9B
  - Target (Gemma 4 — not yet available): `<16 GB` → E2B unified, `16-31 GB` → E4B unified, `≥32 GB` → E2B (ASR) + 26B-A4B (LLM)
- Validate `Auto (Recommended)` vision selection against available RAM tiers:
  - under `16 GB` available RAM: vision model remains off by default
  - `16+ GB` available RAM: `SmolVLM2-500M` (4bit, on-demand deep path); `SmolVLM2-256M` (always-on proactive awareness)
- In `--test-server` or other low-memory validation flows, confirm the runtime clamp is actually applied and reported consistently:
  - operator model resolves to `Qwen3.5 2B · 4bit`
  - effective context is `8192`
  - startup/memory-policy logs report the same effective context as the runtime configuration
- For each RAM tier under validation, capture:
  - idle app RSS
  - peak combined app + worker RSS during at least one real tool turn
  - whether the turn completed natively, via repair fallback, or timed out

## Phase 12: JSC Tool Program Runtime

Validates the JavaScriptCore tool-program execution path end-to-end.

### 12.1 Script execution via LLM
- [ ] Prompt the LLM with a multi-step task (e.g. "check my calendar, find conflicts, then remind me")
- [ ] Verify LLM emits a `<tool_program>` block (not individual tool calls)
- [ ] Verify script executes through JSCRuntime with real per-turn context
- [ ] Verify tool calls within the script honor the current tool mode
- [ ] Verify the script result appears in the conversation

### 12.2 Security enforcement
- [ ] In read-only tool mode, verify script tool calls are blocked
- [ ] Verify speaker identity is enforced (non-owner cannot trigger script tools)
- [ ] Verify proactive context restrictions apply to script tool calls
- [ ] Verify budget limits trigger correctly (set a low budget, confirm budgetExceeded)

### 12.3 Batch approval
- [ ] Execute a script that calls the same tool 3+ times in a loop
- [ ] Verify first invocation shows approval popup
- [ ] Verify subsequent invocations of the same tool are auto-approved (batch grant)
- [ ] Verify different tool names still require their own approval

### 12.4 Dry-run mode
- [ ] Execute a `<tool_program>` with dry-run flag
- [ ] Verify `DryRunPlan` records all intended calls without executing them
- [ ] Verify typed adapters (`fae.calendar.list()` etc.) work in dry-run mode

### 12.5 Typed adapters
- [ ] Execute a script using `fae.calendar.list()` — verify structured data returned
- [ ] Execute a script using `fae.web.search(query)` — verify structured results
- [ ] Verify `fae.fs.read(path)` returns file content

### 12.6 Capability tickets
- [ ] Verify script-scoped ticket is issued at script start
- [ ] Verify ticket is revoked after script completion
- [ ] Verify ticket is revoked after script failure/cancellation

## Phase 13: Cloud Lane (ADR-014)

Validates the cloud privacy lane configuration end-to-end.
Mandatory when: `llm.privacyLane`, `llm.cloudDailyBudgetUSD`, cloud API key, or
`FAE_REMOTE_*` / `FAE_OPENROUTER_API_KEY` env injection changes.

### 13.1 Config round-trip
- [ ] Set `llm.privacyLane = "all"` + `llm.cloudDailyBudgetUSD = 3.0` in config.toml; confirm values survive a load → serialize cycle (`FaeConfigParsingTests` suite).
- [ ] Set `llm.privacyLane = "unknown"` in config.toml; confirm it resolves to `"local"` (no crash, no silent accept).
- [ ] Confirm `cloudDailyBudgetUSD = 0.0` clamps to 0.01 and `cloudDailyBudgetUSD = 999.0` clamps to 100.0.

### 13.2 Keychain key storage
- [ ] Open Settings > Models & Privacy > Cloud Models; paste an API key and press Save.
- [ ] Confirm the "API key stored in Keychain" indicator appears.
- [ ] Quit and relaunch; confirm the indicator persists (key survived across launches).
- [ ] Press Remove; confirm the indicator clears and the key is gone from Keychain.

### 13.3 Daemon spawn env injection
- [ ] Set lane = "all", store an API key, restart the daemon (`just run-dev`).
- [ ] Confirm `DaemonLLMEngine` log line "cloud lane active (lane=all, …)" appears.
- [ ] Confirm `FAE_OPENROUTER_API_KEY` does NOT appear in `~/Library/Logs/` or NSLog output.
- [ ] With lane = "all" and `FAE_OPENROUTER_API_KEY` set, unset either `FAE_REMOTE_BASE_URL` or `FAE_REMOTE_MODEL`; confirm startup warns that the OpenRouter contract is incomplete, names the missing configuration fields without logging the key, and keeps cloud routing disabled.
- [ ] Set lane = "local"; confirm the log line does NOT appear (no cloud vars injected).

### 13.4 Fallback surface
- [ ] Simulate a `conductor.fallback` `runtimeProgress` event (e.g. via test-server inject or by exhausting the budget).
- [ ] Confirm a visible pill/subtitle notice appears: "Running locally (cloud request fell back: …)".
- [ ] Confirm the notice clears after the auto-hide timer (not persistent).

### 13.5 Settings tab layout
- [ ] Open Settings > Models & Privacy; confirm three-state lane selector renders correctly.
- [ ] Confirm "Changes apply at next daemon start" warning appears when lane != "local".
- [ ] Confirm provider preset, base URL, model, budget fields are present and editable.
- [ ] Confirm Instrument Serif header font and Scottish palette colours (no system .blue).
