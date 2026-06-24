# M3 — MetaOpt ConductorRecipe Mutation (spec v1)

- **Status:** Proposed (spec) — awaits G-M3-spec review (`oracle` + `reviewer`).
- **Date:** 2026-06-24
- **Owner:** David Irvine
- **Authorizes:** ADR-008a (Accepted, `ec856463`) — the four enforceable constraints.
- **Prereqs:** G-M2 impl PASSED (reward/shadow review-complete, `03d82169`). MetaOpt primitive ported + dormant (`750a4a4a`). Conductor recipe store versioned (`recipes/<id>.v<ver>.json`).
- **Scope:** Add `ConductorRecipe` as the 5th MetaOptimization surface, with mutation operators, validation, rollback, and SOUL-drift gate. **Dormant/offline/manual-triggered in M3** — no background autonomous daemon, no live auto-deploy.

---

## 0. Design posture (non-negotiable)

M3 is the **protected-kernel surface**: autonomous mutation of the egress-affecting routing recipe. Three principles govern the entire milestone:

1. **Dormant/offline-first.** M3 lands the surface, operators, validation, rollback, and gates as **offline / manually-triggered** code. There is **no background scheduler**, **no live auto-deploy**, **no default route mutation** in M3. The shadow router's promotion candidates (M2 §8) are the input; a human reviews them and triggers a MetaOpt run; the run proposes patches; validation + the F-12/F-16 benchmark gates decide. The live autonomous loop is a **later gated step** (post-M3), not M3.
2. **The recipe is data, not code.** A `ConductorRecipePatch` is a **data value** (an enum of allowed mutations). The daemon's adapter **interprets** it against `FaeConductorRecipe`. Candidate policies under shadow evaluation remain **data-only interpreted recipes** — never arbitrary executable policy code. This is the shadow router's no-egress-seam guarantee extended into M3 (see `shadow.rs` module docs, honesty note).
3. **Two-layer enforcement (ADR-008a).** Layer 1 = proposal-structural (the validator rejects constraint-violating patches *before* they are proposed). Layer 2 = runtime-authoritative (the M2 §5 gate pipeline re-asserts mode/membrane/budget/approval every turn regardless of recipe content). **A mutation changes preference; the runtime gates own permission.** Both layers must be test-enforced.

---

## 1. Decoupling: `ConductorRecipePort` + `ConductorRecipePatch`

To avoid `fae-metaopt` depending on `fae-daemon` internals (awkward binary/library coupling), the surface is split:

### 1.1 In `fae-metaopt` (the proposal layer, Layer 1)

A **data** patch type + a port trait. The MetaOpt crate produces patches and validates them structurally; it does **not** import `FaeConductorRecipe`.

```rust
// crates/fae-metaopt/src/conductor_recipe.rs (NEW)

/// A mutation a MetaOpt run may propose on a conductor recipe.
/// DATA ONLY — the daemon adapter interprets this against FaeConductorRecipe.
/// Maps 1:1 to ADR-008a's five allowed operators.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ConductorRecipePatch {
    /// (ADR-008a op 1) Swap the selected worker. `to_worker` must be same-or-lower
    /// trust tier. Validated by the adapter against the provisioned registry.
    SwapWorker { recipe_id: String, to_worker: String },
    /// (ADR-008a op 2) Switch topology direct ↔ chain.
    SwitchTopology { recipe_id: String, to: ConductorTopologyDto },
    /// (ADR-008a op 3) Add or remove a Verifier role (chain topology only).
    AdjustVerifier { recipe_id: String, action: VerifierAction },
    /// (ADR-008a op 4) Mutate a role-conditioned prompt. Lint-gated (§5).
    MutateRolePrompt { recipe_id: String, role: ConductorRoleDto, new_prompt: String },
    /// (ADR-008a op 5) Adjust budget. Downward always allowed; upward only within
    /// the provisioned cap. Validated by the adapter.
    AdjustBudget { recipe_id: String, delta_micros_per_day: i64 },
}

/// The port the daemon implements. fae-metaopt calls it; fae-metaopt does NOT
/// import FaeConductorRecipe.
#[async_trait]
pub trait ConductorRecipePort: Send + Sync {
    /// Validate a patch against the four ADR-008a constraints WITHOUT applying.
    /// Returns Ok(()) or a structured Rejection (which constraint, why).
    async fn validate_patch(&self, patch: &ConductorRecipePatch) -> Result<(), PatchRejection>;

    /// Apply a validated patch. The implementation MUST call validate_patch first
    /// (defense-in-depth) and persist the new version to the recipe store.
    /// Returns the new version number (for rollback).
    async fn apply_patch(&self, patch: &ConductorRecipePatch) -> Result<u32, RecipePortError>;

    /// Roll back to a prior recipe version (whole-recipe-version rollback).
    async fn rollback(&self, recipe_id: &str, to_version: u32) -> Result<(), RecipePortError>;

    /// Snapshot the current recipe for benchmark-before scoring.
    async fn current_recipe_summary(&self, recipe_id: &str)
        -> Result<RecipeSummary, RecipePortError>;
}
```

**DTO types** (`ConductorTopologyDto`, `ConductorRoleDto`) are `fae-metaopt`-local enums that mirror the daemon's. The adapter converts at the boundary. `star`/`debate` are **absent** from `ConductorTopologyDto` (F-15 enforced at the data layer too — a patch can't even name them).

### 1.2 In `fae-daemon` (the adapter, Layer 1 enforcement + persistence)

A `DaemonConductorRecipePort` implementing `ConductorRecipePort`. It:
- Resolves `recipe_id` → `FaeConductorRecipe` from the loaded `RecipeSet`.
- **Validates** the patch against the four constraints (§3).
- **Applies** by constructing a new `FaeConductorRecipe` version, persisting via `ConductorStore::store_recipe` (already atomic-write + versioned), and recording a `RecipeMutationEvent` to the isolated store.
- **Rolls back** by loading + re-activating a prior `.v<ver>` version (whole-version, not per-operator partial — ADR-008a "Restore previous recipe version").

**No `fae-metaopt` → `fae-daemon` dependency.** The daemon depends on metaopt (implements the trait); metaopt depends only on its own types + `async-trait` + `serde`.

---

## 2. The five allowed operators (ADR-008a §Allowed operators)

| # | Operator | Patch variant | Constraint |
|---|---|---|---|
| 1 | Swap worker | `SwapWorker` | `to_worker` must be **same-or-lower trust tier** (never higher) AND **provisioned** (in `WorkerRegistry` with valid credentials). Unprovisioned ⇒ reject. |
| 2 | Switch topology | `SwitchTopology` | `direct ↔ chain` only. `star`/`debate` are absent from the DTO enum — unnameable. |
| 3 | Add/remove Verifier | `AdjustVerifier` | `chain` topology only; `Verifier` role only. |
| 4 | Mutate role prompt | `MutateRolePrompt` | Lint-gated (§5): no secret-exfil, no memory-export, no gate-bypass, no router jargon, preserve SOUL/head-butler framing. |
| 5 | Adjust budget | `AdjustBudget` | `delta < 0` always allowed. `delta > 0` allowed only if `current_cap + delta ≤ provisioned_cap(worker)`. Above provisioned ⇒ reject. |

**Egress multiplication (advisor point 5):** when a patch switches `direct → chain` or adds a Verifier, the recipe's per-turn egress count increases (3 role-calls vs 1). The validator must **re-check the budget against the multiplied fanout** — a budget that was in-cap for 1 call may exceed the cap for 3. The `AdjustBudget` + `SwitchTopology`/`AdjustVerifier` operators interact; the validator computes the post-patch worst-case call count and re-runs the budget check. **Test:** `chain_switch_rechecks_budget_against_fanout`.

---

## 3. The four enforceable constraints (Layer 1 validation)

The validator (`validate_patch`) rejects any patch that would:

| # | Constraint | Reject if | Test |
|---|---|---|---|
| 1 | **Widen a privacy lane** | patch would move `privacy_lane` to a wider lane (e.g. `LocalOnly → CloudBacked`). Lane order: `LocalOnly ⊂ CloudBacked ⊂ OwnerFleet ⊂ TrustedPeer ⊂ RemoteAllowed`. Keep-or-narrow only. | `reject_lane_widening` |
| 2 | **Raise budget above provisioned cap** | `AdjustBudget` with positive delta exceeding the worker's provisioned D2 ceiling. (No provisioning gate is reachable via recipe mutation.) | `reject_budget_above_provisioned_cap` |
| 3 | **Introduce gated locality/topology** | patch names `TrustedPeer`/`RemoteAllowed` lane or `star`/`debate` topology. **Structurally impossible** — these are absent from the DTO enums; serde rejects unknown variants fail-closed. | `reject_forbidden_lane_topology` (serde-level) |
| 4 | **Override `ModelMode`** | any patch that attempts to mutate `ModelMode`. **Structurally impossible** — `ModelMode` lives on `ConductorEgress`, not `FaeConductorRecipe`, and is **not a `ConductorRecipePatch` variant**. Additionally: a `ConfigKnob` patch with key `"FAE_MODEL_MODE"` (or any model-mode-aliased key) is **rejected** at the `ConfigPort` boundary. | `reject_model_mode_mutation` + `reject_model_mode_via_config_knob` |

**Each rejection returns a `PatchRejection`** (structured: which constraint, the offending value). Rejections are logged to the isolated store for audit. **No patch violating a constraint is ever proposed to `apply_patch`.**

### Layer 2 (runtime, authoritative — already built in M2)

The M2 §5 gate pipeline re-asserts `mode-cap → membrane → budget → approval` on every turn regardless of recipe content. Even a patch that slipped Layer 1 cannot bypass egress: the mode cap rejects unpermitted lanes, the membrane blocks secrets, the budget governor caps spend, the approval gate demands a grant. **Cross-ADR dependency:** this argument holds only while the M2 §5.6 invariant (membrane-before-construction) holds — that test is a standing precondition (ADR-008a Risks).

---

## 4. Rollback (whole-recipe-version)

- The recipe store is already versioned: `recipes/<recipe_id>.v<version>.json` (M0b).
- **Rollback = restore + re-activate a prior version.** `ConductorRecipePort::rollback(recipe_id, to_version)` loads `recipes/<id>.v<to_version>.json`, validates it deserializes (F-15: rejects star/debate on the way in), and makes it the active version.
- **Per-operator partial rollback is NOT supported.** ADR-008a specifies "Restore previous recipe version" — a single atomic unit. This is simpler, auditable, and avoids half-applied states. If a run proposes multiple patches, each is a separate version; undo = step back one version at a time.
- **"Undo last change" works:** the conductor surfaces `rollback(recipe_id, current_version - 1)` as the undo affordance (M3 acceptance item).

---

## 5. Prompt-mutation lint (op 4 gate)

`MutateRolePrompt` patches are lint-gated before validation passes. The lint is **deterministic** (no model judgment at this layer):

| Lint rule | Rejects | Rationale |
|---|---|---|
| `no_secret_exfiltration` | prompt instructs emitting/encoding/base64-ing secrets, keys, tokens, credentials | egress-safety |
| `no_full_memory_export` | prompt instructs dumping/recalling/exporting the full memory store or entity graph | compartmentalization (ADR-012 principle 3) |
| `no_gate_bypass` | prompt instructs ignoring the membrane/budget/approval gates or "routing around" them | protected-kernel integrity |
| `no_router_jargon` | prompt contains conductor internals jargon (`PrivacyLane`, `BudgetGovernor`, `MetaOpt`, route/recipe/worker ids) | narrator copy (F-16/SOUL): Fae speaks as a companion, not a router |
| `preserves_soul_framing` | prompt drops the head-butler/SOUL identity framing | F-16 personality preservation |

The lint is a **regex/keyword + structural check** over the new prompt string. It is conservative (false-positive-over-false-negative). A lint rejection is a `PatchRejection::PromptLintFailed { rule }`.

---

## 6. F-16: SOUL-drift proxy metric

F-16 requires a metric that triggers periodic review if a mutation drifts Fae's personality. The proxy is **two-layer**, both deterministic; model judgment is **advisory only** (same F-10 discipline):

### 6.1 Layer A — held-out SOUL eval corpus (deterministic)

A **separate, versioned eval corpus** (`soul_drift_corpus_v1.json`) distinct from the routing corpus (D7). Each entry is a `(prompt, expected_persona_markers)` pair where `expected_persona_markers` is a set of deterministic checks:
- Does the response use first-person companion voice (not third-person assistant)?
- Does it preserve the SOUL identity tokens (name, role, framing)?
- Does it avoid router/machine jargon?
- Tone/length bounds (within a character-window).

A mutated recipe's prompts are scored against this corpus. A **drift regression** = any entry where the persona-marker pass rate drops below the baseline by more than `SOUL_DRIFT_THRESHOLD` (default: 0%). Zero tolerance for persona regression — a mutation that makes Fae sound less like Fae is rejected even if routing accuracy improves.

### 6.2 Layer B — prompt-structure lint (deterministic, §5)

The §5 lint (`preserves_soul_framing`, `no_router_jargon`) runs on every `MutateRolePrompt`. This is the per-patch gate; Layer A is the per-run gate.

### 6.3 Model self-judgment — advisory only

A model's assessment of "does this still sound like Fae" may be recorded as **advisory input** to a human reviewer, but **may never be the sole positive evidence** that a mutation is drift-free (same F-10 discipline as the reward aggregator). Drift regression = Layer A or B fails; model judgment cannot override a deterministic failure.

### 6.4 Review trigger

A drift regression (Layer A or B) **blocks auto-promotion entirely** and flags the mutation for **human review**. The reviewer sees the drift delta, the offending prompt, and the lint rule. This is the F-16 "periodic review trigger" — it fires per-mutation, not on a timer (M3 is offline/manual).

---

## 7. Promotion gate (the F-12 + F-16 combined decision)

A proposed mutation is **promoted** (new version activated) only if **all** pass:

1. **Layer 1 validation** (§3) — no constraint violation.
2. **Prompt lint** (§5) — no lint failure.
3. **F-12 routing improvement** — `is_improvement(baseline_corpus_score, candidate_corpus_score)` on the **routing** corpus (D7): same `corpus_version` AND statistically significant (McNemar exact) AND ≥5% relative AND no per-dimension regression.
4. **F-16 SOUL-drift** — zero persona regression on the held-out SOUL corpus (Layer A) AND all lint passes (Layer B).
5. **Human review** (M3) — a human reviews the promotion-candidate flag (from the shadow router, M2 §8) + the drift report + the benchmark delta, and **approves**. **M3 does not auto-promote.** Auto-promotion is post-M3, gated.

Failure of any gate ⇒ the mutation is **not applied**; a `RecipeMutationRejected` event is logged with the reason. The recipe stays at its current version.

---

## 8. Dormant wiring (what M3 ships, what it doesn't)

**M3 ships (dormant / manually-triggered):**
- `ConductorRecipePatch` + `ConductorRecipePort` in `fae-metaopt`.
- `DaemonConductorRecipePort` adapter in `fae-daemon` (validator + applier + rollback).
- The five operators + Layer 1 validation + prompt lint + SOUL-drift corpus + gates.
- A **manual trigger** (CLI command `fae conductor metaopt-run --recipe <id>` or a scheduler task `metaopt_recipe_mutation`) that runs the offline loop once: shadow candidates → propose patches → validate → benchmark → gate → flag for human review.
- Full test coverage (§9).

**M3 does NOT ship:**
- No background autonomous scheduler running mutation loops on a timer.
- No live auto-deploy (promotion is human-act in M3).
- No mutation of `ModelMode`, lanes above `CloudBacked`, or `star`/`debate` topologies (ever — ADR-gated).
- No cross-owner / mesh integration (M4+).

**The dormant code carries scoped `#[allow(dead_code)]` with `TODO(post-M3)` comments** until the live loop lands (the discipline from M0b/M2).

---

## 9. Acceptance / test matrix

**Layer 1 validation (every constraint):**
- `reject_lane_widening` — `LocalOnly → CloudBacked` patch rejected.
- `reject_budget_above_provisioned_cap` — positive delta beyond ceiling rejected.
- `reject_forbidden_lane_topology` — serde rejects `star`/`debate`/`trustedPeer` (absent from DTO).
- `reject_model_mode_mutation` — no patch variant can name `ModelMode`.
- `reject_model_mode_via_config_knob` — `ConfigKnob` patch with key `FAE_MODEL_MODE` rejected at ConfigPort.
- `reject_unprovisioned_worker_swap` — swap to a worker not in the registry / without credentials.
- `reject_higher_tier_worker_swap` — swap to a higher trust tier.
- `chain_switch_rechecks_budget_against_fanout` — direct→chain with budget that was in-cap for 1 call but exceeds 3-call fanout.

**Prompt lint:**
- `reject_secret_exfiltration_prompt` / `reject_full_memory_export_prompt` / `reject_gate_bypass_prompt` / `reject_router_jargon_prompt` / `reject_soul_framing_drop`.

**F-16 SOUL-drift:**
- `persona_regression_blocks_promotion` — a mutation that improves routing but drops persona-marker pass rate is rejected.
- `model_self_judgment_cannot_override_deterministic_drift_failure` — advisory-only enforcement.

**Rollback:**
- `rollback_restores_prior_version` — undo last change works; recipe active version decrements.
- `rollback_rejects_star_debate_on_deserialize` — F-15 on the way back in.

**F-12 gate:**
- `promotion_requires_is_improvement` — non-improving mutation rejected.
- `no_auto_promotion_in_m3` — the manual trigger flags for human review; no `apply_patch` without the human-approval step.

**Clippy + fmt + workspace check** clean (AGENTS.md gate discipline).

---

## 10. Files touched (post-spec-approval)

**`crates/fae-metaopt/`:**
- `src/conductor_recipe.rs` — NEW: `ConductorRecipePatch`, DTO types, `ConductorRecipePort` trait, `PatchRejection`, `RecipePortError`, `RecipeSummary`.
- `src/types.rs` — add `MetaOptSurface::ConductorRecipe` (remove the ADR-gating doc comment).
- `src/lib.rs` — `pub mod conductor_recipe;`

**`crates/fae-daemon/src/conductor/`:**
- `recipe_mutation.rs` — NEW: `DaemonConductorRecipePort` adapter (validator + applier + rollback).
- `prompt_lint.rs` — NEW: the §5 deterministic lint.
- `soul_drift.rs` — NEW: F-16 Layer A corpus scoring.
- `store.rs` — add `append_recipe_mutation_event` (audit).
- `mod.rs` — declare new modules + scoped dead-code allows.

**Data:**
- `crates/fae-daemon/data/soul_drift_corpus_v1.json` — the held-out SOUL corpus (seed entries; extensible).

**Docs:**
- Tracker: M3 items checked off.
- `docs/checklists/app-release-validation.md` — add a MetaOpt/recipe-mutation validation task (release gate).

---

## 11. Open questions for G-M3-spec review

1. **SOUL corpus seeding:** the held-out corpus needs seed entries. Is David the annotator (single-annotator, like D7)? How many entries for a meaningful drift signal (10? 30?)?
2. **Prompt lint precision/recall:** deterministic lint will have false positives (a legitimate prompt that mentions "key" in a non-secret context). Is conservative-reject acceptable, or do we need a reviewer-override path for lint false-positives?
3. **Manual trigger UX:** CLI command vs. scheduler task vs. both? The scheduler path (`metaopt_recipe_mutation` task, like the existing `memory_reflect`) fits the existing proactive-behavior policy.
4. **Inter-patch ordering:** if a run proposes multiple patches for one recipe, are they applied as separate versions (current design) or batched? Separate is simpler + auditable; batched is fewer versions. Recommendation: separate.
