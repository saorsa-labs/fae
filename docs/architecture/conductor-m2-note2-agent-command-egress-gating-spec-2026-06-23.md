# M2 NOTE-2: Agent-command egress gating

- **Status:** DRAFT v1 — for G-M2-NOTE2-spec review (fresh-context `reviewer`). Not implementation-authorized until the review passes.
- **Date:** 2026-06-23
- **Scope:** Close the egress-coverage gap surfaced by the Stage 1 red-team (NOTE-2): `agent.run` and `agent.prompt` reach cloud-backed coding agents via `fae_acp` WITHOUT passing through the conductor §5 gate pipeline.
- **Parent spec:** `docs/architecture/conductor-m2-reward-eval-shadow-routing-spec-2026-06-23.md` (§5 gate pipeline; §15 Stage 3 prerequisites).

## 1. Problem

The M2 Stage 1 egress pipeline (`crates/fae-daemon/src/conductor/executor.rs`, `execute_cloud_role_call`) gates cloud egress from the conductor with a four-stage pipeline:

```
§5.2 mode cap (pure-local never egresses)
§5.3 PII membrane (fae_pii_membrane::should_block_remote_egress) — before construction
§5.4 budget (cost — now OPTIONAL/non-authoritative per owner decision 2026-06-23)
§5.5 approval (provisioning constitutes the grant)
§5.6 construction + provider call
```

But this pipeline ONLY covers `conversation.inject_text` (which routes through the conductor when `SessionBackends.conductor` is `Some`). Two other daemon commands reach cloud providers via a **completely different egress surface** (`fae_acp` subprocess + ACP protocol) and bypass every gate:

- **`agent.run`** (`session.rs` ~433): `fae_acp::run_one_shot(agent, cwd, prompt, policy)` — one-shot delegation to an external coding agent. The raw `prompt` flows unscanned to a cloud-backed agent (Codex/Claude/Gemini/Copilot).
- **`agent.prompt`** (`session.rs` ~572 / `agent_prompt_inner` ~584): submits a prompt to a live `fae_acp::AcpSession`. Same raw-prompt egress.

**The data-leak scenario:** a user prompt containing credentials/PII (`"review this sk-…"`) flows directly to a cloud coding agent with no membrane scan. Worse, under `pure-local` mode these commands are still fully functional — the mode cap does not apply to them. The conductor's safety story claims "no cloud egress under pure-local"; these two commands break that claim.

## 2. Approach: gate-at-entry (NOT unification)

Two architectures could close this gap:

- **Approach A — gate-at-entry (THIS spec):** run the same gate sequence (mode cap → PII membrane → provisioning/approval) at the entry of `agent_run` / `agent_prompt_inner`, BEFORE any `fae_acp` call. On any gate failure, fail closed (refuse with a structured error; do NOT spawn the agent). `fae_acp` remains the egress mechanism; the conductor gates are applied as a shim around it.
- **Approach B — unify `fae_acp` as a `CloudProvider` adapter:** model each ACP agent as a conductor cloud worker so the ONLY path to an ACP agent is a conductor route decision through the full §5 pipeline. This is the "single egress point" end-state but is a large refactor: it changes command semantics (`agent.run` becomes a conductor-routed turn), requires `fae_acp` to fit the `CloudRequestBuilder`/`CloudProvider` shape, and entangles the ACP streaming/session model with the conductor's request/response model.

**This spec adopts Approach A.** Rationale: the Stage 3 prerequisite is a *safety* gate (close the data-leak + mode gap before the all-available flip), not an architectural unification. Approach A applies the exact same gates as §5, is independently reviewable, and is far less invasive. Approach B is recorded as future work (§7) — it may land later if true single-egress-point unification is wanted, but it is NOT required for the Stage 3 default cutover.

## 3. The gate sequence

Applied identically at the entry of `agent_run` and `agent_prompt_inner`, operating on the resolved `(agent, prompt)`:

### 3.1 Resolve agent → worker
Map the payload `agent` string (e.g. `"codex"`, `"claude"`) to the conductor worker id (`"acp:codex"`, `"acp:claude"` — the `WorkerRegistry` convention from `workers.rs`). An unknown/unvetted agent → fail closed with `unknown_agent`. (See Q1 — the exact resolution table.)

### 3.2 Mode cap (§5.2 equivalent)
`mode_permits_lane(model_mode, PrivacyLane::CloudBacked)`. Under `pure-local` (the landing default), this FAILS → the command is refused. Under `all-available`/`local-symphony`, it passes. This is the load-bearing fix for the mode-gap: under the default, `agent.run`/`agent.prompt` become unavailable, matching the conductor's "pure-local = no cloud egress" claim.

### 3.3 PII membrane (§5.3 equivalent) — BEFORE any agent spawn
`fae_pii_membrane::should_block_remote_egress(prompt)`. If it blocks → fail closed with a `privacy_blocked` error carrying `{ level, labels }` (structured, NEVER the matched text — same discipline as `RouteFailure::PrivacyBlocked`). The scan MUST happen before `fae_acp::run_one_shot` / `AcpSession::start` is called.

### 3.4 Provisioning / approval (§5.5 equivalent)
The agent's credential constitutes the standing grant (owner ruling 2026-06-23). The gate asserts the resolved worker is a known `CloudBackedAcp` worker AND provisioned (credential present). Unprovisioned → fail closed with `not_provisioned`. (See Q2 — how provisioning is discovered for ACP subprocess agents.)

### 3.5 Budget — SKIPPED (owner decision 2026-06-23)
Cost gating is non-authoritative; provider-side caps own spend (parent spec §5.4 decision note). No cost estimate or budget check is applied to agent-command egress.

### 3.6 Egress
Only after 3.2–3.4 pass does the command proceed to `fae_acp::run_one_shot` / `AcpSession::start`.

## 4. Fail-closed behavior

Every gate failure produces:
- **Zero `fae_acp` process spawns / ACP session starts.** The agent is never launched.
- **A structured wire error** the UI maps to a friendly message (reuse `classify_agent_error`'s pattern): `mode_blocked` / `privacy_blocked` / `not_provisioned` / `unknown_agent`.
- **No prompt text in telemetry.** The error response carries only the gate name + (for privacy) structured `{level, labels}`, never the matched secret or the raw prompt.
- **No fallback to local.** Unlike `inject_text` (which degrades conductor-cloud failures to direct-local), `agent.run`/`agent.prompt` are *delegation* commands — there is no local equivalent of "run the Codex agent locally." A gate failure is a hard refusal, returned to the caller. (Rationale: a silent local fallback for an explicit delegation request would be surprising and wrong; the caller asked for a specific cloud agent.)

## 5. Required tests (Stage 3 prerequisite acceptance)

1. **Default `pure-local` blocks all agent-command egress.** A fresh process with `FAE_MODEL_MODE` unset: `agent.run` and `agent.prompt` to a known provisioned agent produce ZERO `fae_acp` spawns/session-starts and return `mode_blocked`. (Spy/mock the `fae_acp` boundary the same way the Stage 1 test spies `CloudRequestBuilder` — the spawn boundary must be a separable, countable seam.)
2. **Credential prompt blocked before spawn.** Under `all-available` + provisioned, a prompt containing a credential (`sk-…`) is blocked at the membrane: ZERO `fae_acp` spawns, error carries `privacy_blocked` + structured labels, never the credential.
3. **All-available + provisioned path still works.** Under `all-available` with the agent provisioned and a clean prompt, the call proceeds normally and returns the agent's output (end-to-end with a mock agent).
4. **Unprovisioned agent blocked.** A known agent id with no credential → `not_provisioned`, zero spawns.
5. **Unknown agent blocked.** An agent string with no worker mapping → `unknown_agent`, zero spawns.
6. **No raw prompt in any error/telemetry path.** Grep the error responses + any conductor telemetry written on the failure paths — only structured fields.

## 6. Implementation surface

- `session.rs`: `agent_run` gains a `&SessionBackends` param (it currently takes only `cmd`); both `agent_run` and `agent_prompt_inner` call a new shared `assert_agent_egress_gates(backends, agent, prompt) -> Result<ResolvedAgent, AgentGateFailure>` before any `fae_acp` call. The dispatch table (~line 358/361) passes `backends`.
- The gate reads `model_mode` + the `WorkerRegistry` from the conductor runtime (already threaded through `SessionBackends.conductor`), and calls `fae_pii_membrane::should_block_remote_egress` directly.
- `AgentGateFailure` maps to the wire errors in §4.
- The `fae_acp` spawn boundary (`run_one_shot` / `AcpSession::start`) becomes a seam the tests can spy/count (mirroring `CloudRequestBuilder`). Exact shape: Q3 for the reviewer.

## 7. Out of scope / future

- **Approach B (unify `fae_acp` as a `CloudProvider` adapter)** — recorded as future work; not required for Stage 3.
- **Per-role membrane for chained ACP** — `agent.run` is single-turn in Stage 1; chain topology is dormant and triple-gated. If/when ACP chains land, each role-call's prompt is membrane-scanned (same principle as the conductor chain test).
- **Budget/cost gating** — permanently sidelined per owner decision (§3.5).

## 8. Open questions for the reviewer

- **Q1 (agent→worker resolution):** is there a canonical `agent`-name → `acp:<name>` table, or must one be defined? Are the vetted agent names exactly `{codex, claude, gemini, copilot}`, matching `workers.rs`'s cloud worker ids? What does an unrecognized name do today (does `fae_acp::run_one_shot` reject it, or attempt a generic launch)?
- **Q2 (provisioning discovery):** how does the gate know an ACP subprocess agent is provisioned? The conductor's `WorkerRegistry::from_cloud_credentials` checks env vars at startup — is that the right signal for ACP agents (which are subprocesses with their own auth), or must provisioning be discovered differently (e.g. the CLI being installed + logged in)? This determines whether §3.4 is a startup registry lookup or a runtime probe.
- **Q3 (spawn seam shape):** what is the minimal spy-able boundary for `fae_acp::run_one_shot` / `AcpSession::start`? A trait + counting impl (mirroring `CloudRequestBuilder`/`CloudProvider`), or a test-only injection point? The Stage 1 `CloudRequestBuilder` pattern is the reference.
- **Q4 (degradation vs refusal):** §4 chooses hard refusal (no local fallback) for agent-command gate failures. Confirm this is correct vs. a degrade-to-`inject_text` fallback — I lean refusal (delegation is explicit), but the reviewer should weigh in.
- **Q5 (scope of `agent.prompt` live session):** `agent_prompt_inner` keeps a LIVE session across multiple turns. Is the membrane gate applied per-turn (each submitted prompt scanned) or only at session start? Per-turn matches the conductor's per-role-call discipline and is the safe choice; confirm.
