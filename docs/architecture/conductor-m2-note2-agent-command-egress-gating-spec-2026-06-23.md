# M2 NOTE-2: Agent-command egress gating

- **Status:** v2.1 — G-M2-NOTE2-spec **PASSED** (re-review run `b32b86c2`, 2026-06-23: zero BLOCKER / zero MAJOR; all v1 findings verified fixed; all v2 questions resolved; no fourth bypass surface). v2.1 folds 3 residual MINORs/NOTEs (claude-code alias footnote; strengthened scope guard; `prompt_session` added to the trait per v2-Q2 resolution). **Implementation-authorized.**
- **Date:** 2026-06-23 (v1); v2 same day after review.
- **Scope:** Close the egress-coverage gap surfaced by the Stage 1 red-team (NOTE-2): `agent.run`, `agent.prompt`, and `agent.session_start` reach cloud-backed coding agents via `fae_acp` WITHOUT passing through the conductor §5 gate pipeline.
- **Parent spec:** `docs/architecture/conductor-m2-reward-eval-shadow-routing-spec-2026-06-23.md` (§5 gate pipeline; §15 Stage 3 prerequisites).

## v1 → v2 changes (review-driven)

- **BLOCKER fix:** `agent.session_start` (`session.rs:540`) added to the gated surface — it spawns a persistent ACP session via `fae_acp::AcpSession::start` with no gate. Under `pure-local` a session process would spawn even with no prompt. Now gated identically to the other two. (Was missing from v1 §6.)
- **MAJOR-1 fix (resolution table):** §3.1 now names the exact `agent → worker_id` table and flags that `pi`/`opencode` are advertised (`KNOWN_AGENTS`) + resolvable (`fae_acp`) but have no `WorkerRegistry` credential env var today — a pre-existing inconsistency across THREE lists (`KNOWN_AGENTS` 6, `fae_acp::resolve_agent` 7, `WorkerRegistry` 4). v2 specifies the fail-closed default + the impl decision.
- **MAJOR-2 fix (spawn seam):** §6 now explicitly requires introducing an `AcpAgentRunner` trait (thin test double, NOT a full ACP provider abstraction — scope guard) so tests #1/#2 can count spawns. v1's "mirroring CloudRequestBuilder" was aspirational; the ACP boundary is currently concrete functions with no trait.
- **MINOR-1 fix:** test #7 added (`agent.session_start` under pure-local → zero starts).
- **MINOR-2 carried:** `eprintln!` → `tracing::warn!` migration in `agent_run`/`agent_session_start`/`agent_prompt_inner` (carried M2 §9 obligation).
- **MINOR-3 noted:** `classify_agent_error`'s `UnknownAgent → "unknown_agent"` overlaps the gate's `unknown_agent`; the §3.1 resolution table is the single source of truth so both paths agree.

## 1. Problem

The M2 Stage 1 egress pipeline (`crates/fae-daemon/src/conductor/executor.rs`, `execute_cloud_role_call`) gates cloud egress from the conductor with:

```
§5.2 mode cap (pure-local never egresses)
§5.3 PII membrane (fae_pii_membrane::should_block_remote_egress) — before construction
§5.4 budget (cost — now OPTIONAL/non-authoritative per owner decision 2026-06-23)
§5.5 approval (provisioning constitutes the grant)
§5.6 construction + provider call
```

This pipeline ONLY covers `conversation.inject_text`. THREE other daemon commands reach cloud providers via a **different egress surface** (`fae_acp` subprocess + ACP protocol) and bypass every gate (verified in review run `a9341fe5`):

- **`agent.run`** (`session.rs:433`): `fae_acp::run_one_shot(agent, cwd, prompt, policy)` — one-shot delegation. Raw `prompt` flows unscanned.
- **`agent.prompt`** (`session.rs:572` → `agent_prompt_inner:584`): submits a prompt to a live `fae_acp::AcpSession`. Raw prompt, no scan.
- **`agent.session_start`** (`session.rs:540`): `fae_acp::AcpSession::start(agent, cwd, policy)` — spawns the persistent session. (BLOCKER: missed in v1.)

**Data-leak scenario:** a prompt containing credentials/PII (`"review this sk-…"`) flows directly to a cloud coding agent with no membrane scan. Under `pure-local` (the landing default) all three commands are still fully functional — the mode cap does not apply. The conductor's safety story claims "no cloud egress under pure-local"; these three commands break that claim — both for data (`agent.run`/`agent.prompt`) and for process creation (`agent.session_start`).

## 2. Approach: gate-at-entry (NOT unification)

Two architectures could close this gap:

- **Approach A — gate-at-entry (THIS spec):** run the same gate sequence (mode cap → PII membrane → provisioning/approval) at the entry of `agent_run`, `agent_session_start`, and `agent_prompt_inner`, BEFORE any `fae_acp` call. On any gate failure, fail closed (refuse; do NOT spawn/start/submit). `fae_acp` remains the egress mechanism; the conductor gates are applied as a shim around it.
- **Approach B — unify `fae_acp` as a `CloudProvider` adapter:** model each ACP agent as a conductor cloud worker so the ONLY path to an ACP agent is a conductor route decision. Large refactor; changes command semantics; entangles the ACP streaming/session model with the conductor's request/response model.

**This spec adopts Approach A** (review-confirmed sound). The Stage 3 prerequisite is a *safety* gate, not architectural unification. Approach A applies the exact same gates as §5, is independently reviewable, and is far less invasive. Approach B is recorded as future work (§7) — not required for the Stage 3 default cutover.

## 3. The gate sequence

Applied identically at the entry of **all three** functions (`agent_run`, `agent_session_start`, `agent_prompt_inner`), operating on the resolved `(agent, prompt)` — where `prompt` is `None` for `session_start` (session creation carries no user prompt, so the membrane scan is skipped for that call but mode + provisioning still apply):

### 3.1 Resolve agent → worker (MAJOR-1 fix)

Map the payload `agent` string to a conductor worker id. The resolution table (the single source of truth — also drives `classify_agent_error`'s unknown-agent path):

| payload `agent` | worker_id | credential env var(s) | status |
|---|---|---|---|
| `claude` | `acp:claude` | `FAE_CLAUDE_API_KEY` / `ANTHROPIC_API_KEY` | provisioned today |
| `codex` | `acp:codex` | `FAE_CODEX_API_KEY` / `OPENAI_API_KEY` | provisioned today |
| `gemini` | `acp:gemini` | `FAE_GEMINI_API_KEY` / `GOOGLE_API_KEY` | provisioned today |
| `copilot` | `acp:copilot` | `FAE_COPILOT_API_KEY` / `GITHUB_TOKEN` | provisioned today |
| `pi` | `acp:pi` | **TBD** (`npx pi-acp` — credential model not env-var-based) | **not provisioned today** |
| `opencode` | `acp:opencode` | **TBD** (`npx opencode-ai` — credential model not env-var-based) | **not provisioned today** |
| anything else | — | — | `unknown_agent` (fail closed) |

**Alias:** `fae_acp::resolve_agent` also accepts `"claude-code"` as an alias for `"claude"` (same `acp:claude` worker / same credential env vars). The `claude-code` payload name maps to `acp:claude`. (`fae_acp` also accepts `"mock"` — dev/test only, never advertised to users.)

**Pre-existing inconsistency (flagged, not silently fixed):** `KNOWN_AGENTS` (session.rs:423) advertises 6 agents including `pi`/`opencode`; `fae_acp::resolve_agent` (lib.rs:83) resolves 7 (adds `claude-code` alias + `mock`); `WorkerRegistry` (main.rs:276-288) provisions only 4. `pi`/`opencode` are advertised + resolvable but have **no conductor credential env var**, so under the §3.4 gate they resolve to a worker id but fail `is_provisioned` → `not_provisioned` (fail closed). This is the correct fail-closed default. **Impl decision (Q1, §8):** either (a) extend `WorkerRegistry::from_cloud_credentials`/`main.rs` with `pi`/`opencode` credential env vars once their auth model is determined from `fae_acp`, or (b) remove `pi`/`opencode` from `KNOWN_AGENTS`/`agent.list` as a product decision. The spec does NOT prescribe which; it prescribes the fail-closed default + that the three lists be reconciled to a single source of truth.

### 3.2 Mode cap (§5.2 equivalent)
`mode_permits_lane(model_mode, PrivacyLane::CloudBacked)`. Under `pure-local` (landing default) → FAILS → all three commands refused. Under `all-available`/`local-symphony` → passes. **This is the load-bearing fix for the mode gap:** under the default, `agent.run`/`agent.prompt`/`agent.session_start` become unavailable, matching the conductor's "pure-local = no cloud egress" claim. (Review-confirmed: blocking an explicit `agent.run` under pure-local is correct — "I want this cloud agent" + "no cloud egress" is a contradiction; the operator sets `all-available` to delegate.)

### 3.3 PII membrane (§5.3 equivalent) — BEFORE any agent spawn/start/prompt
`fae_pii_membrane::should_block_remote_egress(prompt)` — called directly (the same authority the conductor uses; `RealPiiMembrane` already exists, no new membrane code). If it blocks → fail closed with `privacy_blocked` carrying `{ level, labels }` (structured, NEVER the matched text — same discipline as `RouteFailure::PrivacyBlocked`). The scan MUST happen before `fae_acp::run_one_shot` / `AcpSession::start` / `session.prompt`. **For `agent.session_start` there is no prompt** — this gate is skipped (mode + provisioning still apply); the per-turn membrane fires on each subsequent `agent.prompt`.

### 3.4 Provisioning / approval (§5.5 equivalent)
The agent's credential constitutes the standing grant (owner ruling 2026-06-23). The gate asserts the resolved worker is a known `CloudBackedAcp` worker AND `workers.is_provisioned(worker_id)` (startup env-var check — review-confirmed this is the right signal; `fae_acp::resolve_agent` does NOT itself check credentials, the spawned process does its own auth). Unprovisioned → `not_provisioned` (fail closed). For `pi`/`opencode` today this means `not_provisioned` until §3.1 Q1 is resolved.

### 3.5 Budget — SKIPPED (owner decision 2026-06-23)
Cost gating is non-authoritative; provider-side caps own spend (parent spec §5.4 decision note). Review-confirmed safe for agent commands specifically: an `agent.run` is a single atomic delegation; provider caps are per-call; no cumulative conductor-side tracking is needed for the agent path. (Accepted gap, same as parent spec: provider caps don't aggregate conductor-chain spend.)

### 3.6 Egress
Only after 3.2–3.4 pass (and 3.3 for prompt-bearing calls) does the command proceed to `fae_acp::run_one_shot` / `AcpSession::start` / `session.prompt`.

## 4. Fail-closed behavior

Every gate failure produces:
- **Zero `fae_acp` process spawns / session starts / prompt submissions.** The agent is never launched; the session is never started; the prompt is never submitted.
- **A structured wire error** the UI maps to a friendly message (reuse `classify_agent_error`'s pattern): `mode_blocked` / `privacy_blocked` / `not_provisioned` / `unknown_agent`.
- **No prompt text in telemetry.** The error response carries only the gate name + (for privacy) structured `{level, labels}`, never the matched secret or the raw prompt.
- **No fallback to local (review-confirmed, Q4).** Unlike `inject_text` (which degrades conductor-cloud failures to direct-local), agent commands are *explicit delegation* requests — "run THIS cloud agent." A silent local fallback would return a result from a different system, semantically wrong. A gate failure is a hard refusal. (Runtime provider failures post-gate — `auth_error`/`network_error` — are a different class, already mapped by `classify_agent_error`, and are surfaced to the user, not degraded.)

## 5. Required tests (Stage 3 prerequisite acceptance)

The `fae_acp` spawn/start/submit boundary MUST be a separable, spy-able seam (§6) so these tests can count invocations — mirroring Stage 1's `CloudRequestBuilder`/`CloudProvider` spy pattern.

1. **Default `pure-local` blocks ALL agent-command egress.** Fresh process, `FAE_MODEL_MODE` unset: `agent.run`, `agent.prompt`, AND `agent.session_start` to a known provisioned agent produce ZERO `fae_acp` spawns/starts/submits and return `mode_blocked`.
2. **Credential prompt blocked before spawn/start/submit (load-bearing).** Under `all-available` + provisioned, a prompt containing a credential (`sk-…`) is blocked at the membrane for both `agent.run` and `agent.prompt`: ZERO spawns/submits, error carries `privacy_blocked` + structured labels, never the credential. (For `session_start` N/A — no prompt.)
3. **All-available + provisioned path still works.** Under `all-available` with the agent provisioned and a clean prompt, `agent.run` proceeds and returns the agent's output; `agent.session_start` + `agent.prompt` proceed end-to-end. (Mock agent.)
4. **Unprovisioned agent blocked.** A known agent id with no credential → `not_provisioned`, zero spawns/starts.
5. **Unknown agent blocked.** An agent string with no worker mapping → `unknown_agent`, zero spawns.
6. **No raw prompt in any error/telemetry path.** Grep error responses + conductor telemetry on the failure paths — structured fields only.
7. **(MINOR-1 fix) `agent.session_start` under pure-local → zero session starts.** Distinct from test #1's bundle: asserts the session-creation surface specifically (not just prompt egress) is mode-gated, so the "no cloud egress under pure-local" claim holds for process creation too.

## 6. Implementation surface (MAJOR-2 fix: spawn seam)

- **New `AcpAgentRunner` trait (THIN test double — NOT a full ACP provider abstraction).** The `fae_acp` boundary is currently concrete functions (`run_one_shot`, `AcpSession::start`, `session.prompt`) with no trait, so tests #1/#2 cannot count invocations as specified. Introduce a minimal trait injected through `SessionBackends` (or a local dependency):
  ```rust
  pub trait AcpAgentRunner: Send + Sync {
      async fn run_one_shot(&self, agent: &str, cwd: &Path, prompt: &str, policy: ApprovalPolicy)
          -> Result<AcpOutcome, AcpError>;
      async fn start_session(&self, agent: &str, cwd: &Path, policy: ApprovalPolicy)
          -> Result<AcpSession, AcpError>;
      async fn prompt_session(&self, session: &AcpSession, prompt: &str)
          -> Result<_, AcpError>; // return type matches fae_acp's streaming API
  }
  ```
  Production: `RealAcpAgentRunner` delegates to the real `fae_acp` functions. Test: `CountingAcpAgentRunner` (`Arc<AtomicUsize>` per method). **`prompt_session` is on the trait (v2.1, re-review v2-Q2 resolved)** so test #2 can count per-turn submits on the credential-blocked `agent.prompt` path — not just spawns/starts. The membrane gate fires at the entry of `agent_prompt_inner` BEFORE `prompt_session` is called, so the spy count is zero on the blocked path. The `agent_prompt_inner` event loop (`session.prompt` → `AcpUpdate`/`AcpServerRequest` iteration) routes through `runner.prompt_session` so the submit is the spy-able boundary.
  **Scope guard (v2.1 strengthened per re-review NOTE-2):** this is a testability seam, NOT Approach B unification. It MUST NOT model ACP agents as conductor workers; MUST NOT include routing/policy methods; MUST NOT change command semantics. It is purely delegation + counting. If a later stage extends this trait, it must not slide toward a full ACP-provider abstraction — that is Approach B, which is separately gated future work (§7).
- **`agent_run` gains a `&SessionBackends` param** (currently takes only `cmd`); the dispatch table (~line 358) passes `backends`.
- **Shared gate:** `assert_agent_egress_gates(backends, agent, prompt: Option<&str>) -> Result<ResolvedAgent, AgentGateFailure>` called at the entry of all three functions before any `fae_acp` call. `prompt: None` for `session_start` (skips §3.3).
- **Gate reads** `model_mode` + `WorkerRegistry` from the conductor runtime (already threaded via `SessionBackends.conductor`) and calls `fae_pii_membrane::should_block_remote_egress` directly.
- **`AgentGateFailure`** maps to the §4 wire errors.
- **`eprintln!` → `tracing::warn!`** in `agent_run`/`agent_session_start`/`agent_prompt_inner` (MINOR-2; carried M2 §9 obligation).

## 7. Out of scope / future

- **Approach B (unify `fae_acp` as a `CloudProvider` adapter)** — recorded as future work; not required for Stage 3.
- **Per-role membrane for chained ACP** — `agent.run` is single-turn; chain topology is dormant + triple-gated. If/when ACP chains land, each role-call's prompt is membrane-scanned.
- **Budget/cost gating** — permanently sidelined per owner decision (§3.5).
- **`KNOWN_AGENTS` / `agent.list` reconciliation with `pi`/`opencode`** — follow-up product decision (§3.1 Q1); not blocking the egress gate (fail-closed default is safe).

## 8. Open questions for the reviewer (v2)

v1's Q1–Q5 are resolved by the review (run `a9341fe5`) with primary-source evidence:
- **v1-Q1 (resolution table):** RESOLVED — no canonical table existed; §3.1 now defines it. **Carries forward as v2-Q1** (the `pi`/`opencode` credential-model sub-question): what env var (if any) provisions `pi`/`opencode`? Needs `fae_acp` investigation. Until resolved, both fail `is_provisioned` → `not_provisioned` (safe default).
- **v1-Q2 (provisioning discovery):** RESOLVED — `WorkerRegistry::is_provisioned` (startup env-var check) is the right signal; `fae_acp::resolve_agent` does not check credentials itself. §3.4 confirmed.
- **v1-Q3 (spawn seam):** RESOLVED — no seam exists; §6 now requires `AcpAgentRunner`. Confirm the trait sketch is minimal/correct and the scope guard holds.
- **v1-Q4 (refusal vs degradation):** RESOLVED — refusal is correct (explicit delegation). §4 confirmed.
- **v1-Q5 (per-turn membrane):** RESOLVED — per-turn is required; each `session.prompt()` is a separate egress and conversation context accumulates. Gate fires at the start of `agent_prompt_inner`, not `session_start`. §3.3 confirmed.

**v2 open questions — RESOLVED by re-review (run `b32b86c2`):**
- **v2-Q1 (pi/opencode credential model):** RESOLVED — fail-closed `not_provisioned` is the correct landing default; do NOT resolve in this milestone. `npx`-based tools use their own auth flow (npm token / tool config), no conductor env var maps to them. Making the existing silent gap explicit + fail-closed improves safety. Follow-on product decision when/if pi/opencode support is desired.
- **v2-Q2 (AcpAgentRunner trait shape):** RESOLVED — adopt the reviewer recommendation: add `prompt_session` to the trait (§6 updated in v2.1). The membrane gate fires before the submit, so the spy count is zero on the blocked path; `prompt_session` on the trait lets test #2 assert "zero submits" structurally, not just "zero starts."
- **v2-Q3 (session_start caller impact):** RESOLVED — no breakage. The only caller of `agent.session_start` is the dispatch table on the explicit `"agent.session_start"` command; no automatic warmup/startup path exists. Blocking under pure-local regresses nothing.

**v2.1 status:** re-review returned zero BLOCKER / zero MAJOR — spec is **CLEAR to implement**. Three residual MINORs/NOTEs folded into v2.1 (claude-code alias footnote; strengthened scope guard; prompt_session trait method).
