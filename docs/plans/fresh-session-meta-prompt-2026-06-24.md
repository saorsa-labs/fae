# Fae Conductor — Fresh Session Meta-Prompt (2026-06-24)

> Paste everything below this line into a new session.

---

You are continuing work on **Fae** — a Scottish Fae voice assistant being transformed into a learned multi-model orchestrator (Sakana Fugu "Conductor" style) that coordinates many models/agents. Project root: `/Users/davidirvine/Desktop/Devel/projects/fae`.

## Step 1 — Orient (read these first, in order, before any work)

1. `docs/plans/fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md` — the execution plan. **Read the "Sequencing" subsection under M3 first** — it states the active decision.
2. `docs/architecture/egress-scope-and-stage3-hold-2026-06-23.md` — the keystone security/privacy doc. §0 = security model.
3. `docs/adr/012-local-first-coordinator-of-external-ais.md` — "Head Butler" ADR. **Authoritative** security model.
4. `docs/adr/011-headless-rust-core-runtime.md` — headless Rust daemon is canonical; Swift = migration/legacy.
5. `docs/adr/008a-conductor-recipe-surface-amendment.md` — M3's four enforceable constraints.
6. `AGENTS.md` (project root + `~/AGENTS.md`) — engineering guardrails: panic-free Rust, audit trails, mandatory pre-submit gates (`cargo fmt` → `cargo clippy --all-features --all-targets -- -D warnings` → `cargo check --workspace --all-targets`), justfile-first, dotfile backup rule.

## Step 2 — Where we are (current state, verified)

**Done & reviewed (M0 → M2):**
- M0 scaffolding, M1 static recipes (byte-identical `direct` route), M2 reward/shadow (§7/§8) + eval corpus (D7) + budget governance (D2) + egress gate pipeline (§5) + agent-command egress gating (NOTE-2).
- **M3 spec v5 PASSED** (`f3a1ed70`; oracle run `d89f3738`) — 5 adversarial review rounds, implementation-ready, dormant/offline/CLI-only by design.
- Workspace: **163 tests pass**, clippy clean on ALL crates, `cargo check --workspace --all-targets` clean.
- Main HEAD: check `git log --oneline -5`. Recent: `cde63375` (overclaim correction), `f3a1ed70` (M3 spec v5). Local commits NOT pushed (left for David).

**The active decision (this session's output):**
- **M3 implementation is HELD** — not because the spec is done, but because of **sequencing**. M3 = self-mutation that optimizes against a *reward signal*; reward/shadow are dormant (no live call sites — verified: `grep -rn "aggregate_reward\|ShadowRouter" crates/fae-daemon/src/` shows only `mod.rs` re-exports + `#[allow(dead_code)] TODO(M2)` store seams). Building M3 now = optimizing against nothing.

## Step 3 — The next task (scoped, lower-risk, prerequisite)

**Wire M2 reward/shadow signal collection into the live *local* loop.** This is the prerequisite for M3, not a detour.

**Scope constraints (hard):**
- **Local turns only** — routing accuracy + user signals. Do NOT do the Stage-3 cloud-egress cutover (that stays gated; pure-local is the confirmed default per `egress-scope` §0).
- The M2 §5 gate pipeline must keep authority — reward collection is *observation*, not a new egress surface.
- reward/shadow live in `crates/fae-daemon/src/conductor/reward.rs` and `shadow.rs`. The store seam (`append_feedback`/`read_feedback`/`append_shadow_record`) is in `store.rs`.
- The turn loop is in `crates/fae-daemon/src/conductor/executor.rs` and `session.rs`.
- **Process:** write a spec → review gate (oracle) → implement → review gate (oracle + reviewer). Do NOT skip the staged gates.

**Suggested first action:** draft a spec for "M2 reward/shadow live wiring" — what gets recorded per turn, where it's written (isolated store, never `fae.db` directly except via `MemoryOrchestrator` with supersession lineage), how shadow runs (decision-only, no egress seam), how it's verified. Then dispatch the spec-review oracle.

## Step 4 — Critical corrections to carry forward (do NOT re-introduce these errors)

1. **BLOCKER-1 honest framing (advisor-corrected this session):** G-M3-spec found a *real* config-write hole in `fae-metaopt::optimizer.rs:309-323` (unlisted config keys bypass `ConfigBound` validation, written unconditionally at `write_config`). But it is **NOT reachable today** — `fae-metaopt` is dormant/unwired (zero refs from `fae-daemon`, not in its Cargo.toml). It is **NOT yet fixed** — no denylist exists; the M3 spec *mandates* `is_protected_config_key()`, code ships with M3 impl. **Hard rule:** `fae-metaopt` MUST NOT be wired into the daemon until the denylist exists. (Recorded in release-validation checklist with a `grep` gate.) If you find yourself writing "reachable" or "fixed," verify against the code first.

2. **Membrane = credential/secret filter, NOT PII filter.** The crate is misnamed `fae-pii-membrane` but its 12 rules all catch secret-shaped strings (API keys, tokens, private keys, seed phrases, passwords, SSH keys, OTPs). It does NOT catch health/address/location/family/finances/SSN/email. The "PII" name is an acknowledged error (rename is a follow-up). The security model is **Fae-as-local-coordinator + compartmentalization** (ADR-012); the membrane is the constant credential/secret egress floor (defense-in-depth), NOT the trust boundary.

3. **Cloud models are INTENDED.** Coordinator stays local (Gemma-class); cloud external models + Symphony are first-class. Trust gradient: `LocalModel`(Tier A) → `CloudBackedAcp`(B) → `OwnerFleet`(B/C) → `TrustedPeer`(C) → `RemoteProvider`(C). Stage 3 (all-available default flip) is DECIDED NOT PROCEEDING — cloud egress stays opt-in via `FAE_MODEL_MODE`.

4. **Overclaims on safety boundaries are themselves risks.** Prior overclaims corrected this session: ADR-012 line 41 ("PII membrane is the security model" → "Fae-as-coordinator is; membrane is the egress floor"); shadow.rs ("physically incapable of egress" → "no conductor egress seam in scope" — Rust can't prove arbitrary `decide()` is pure; M3 candidates must stay data-only). If you assert a safety property, state exactly what's proven and what isn't.

## Step 5 — Process discipline (how to work here)

- **Verify claims against primary source before propagating them.** This session's main lesson. The advisor caught a framing error by reading `optimizer.rs`. When in doubt, `grep`/`read` the code.
- **Staged reviews:** spec → review → impl → review, every milestone. Use the `oracle` subagent for security/architecture review and `reviewer` for implementation. Run gates with `set -euo pipefail`; never pipe-mask (`… | tail -1 && echo clean`). Commit `Cargo.lock`.
- **Parallel dispatch protocol:** `acceptance: "none"` (string) for implementation children; durability = branch + commit-before-report. Note: `worktree: true` does NOT isolate in this env (confirmed environmental) — hold filesystem ops until a builder reports, or use `.git/info/exclude` for co-existing untracked artifacts.
- **Reviewer "failed" status** is often an acceptance-report parsing quirk — the review *content* in the artifact file is the value. Read `/Users/davidirvine/.pi/agent/sessions/--Users-davidirvine-Desktop-Devel-projects-fae--/subagent-artifacts/<run>_<agent>_0_output.md`.
- **Mutation-testing discipline:** for every load-bearing security assertion, temporarily disable the guard, confirm the test fails, restore.
- **Commit discipline:** Conventional Commits; never commit another session's `agent/todos/*.md` artifacts; don't rewrite history — corrective commits supersede stale framing in the live state.
- **SOUL.md identity:** Fae is a "head butler," not a visible model router. Progressive disclosure (L0–L4). Never Fugu-style opacity.
- CoWork is REMOVED (Great Cleanup 2026-06-11) — must not be resurrected.

## Step 6 — Team coordination

- Intercom team channel: `subagent-chat-019e83db` (may be stale — check `intercom list`).
- Remote: `origin` → `git@github.com:sapirus-labs/fae.git`. **Do not push** — local commits are left for David.
- Key subagents available: `oracle` (security/architecture review), `reviewer` (implementation review), `builder` (implementation).

## How to begin

1. Confirm the working tree: `git log --oneline -5`, `git status`.
2. Re-read the 6 orientation docs (Step 1) — don't skim.
3. Confirm the dormant state yourself: `grep -rn "fae-metaopt" crates/fae-daemon/` (empty) and `grep -rn "aggregate_reward\|ShadowRouter" crates/fae-daemon/src/` (only re-exports + dead-code seams).
4. Then: draft the "M2 reward/shadow live wiring" spec and dispatch the spec-review oracle. Don't implement before the spec passes review.

**What I (David) want from you first:** a short orientation confirmation + the proposed scope of the reward/shadow wiring spec (3–5 bullets) before you write the full spec. I'll greenlight the scope before you invest in the full spec + review cycle.
