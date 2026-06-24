# M3 — MetaOpt ConductorRecipe Mutation (spec v2)

- **Status:** Proposed (spec v3) — awaits G-M3-spec re-review (`oracle` + `reviewer`).
- **Date:** 2026-06-24 (v3 2026-06-24)
- **Owner:** David Irvine
- **Authorizes:** ADR-008a (Accepted, `ec856463`) — the four enforceable constraints.
- **Prereqs:** G-M2 impl PASSED (reward/shadow review-complete, `03d82169`). MetaOpt primitive ported + dormant (`750a4a4a`). Conductor recipe store versioned (`recipes/<id>.v<ver>.json`).
- **Scope:** Add `ConductorRecipe` as the 5th MetaOptimization surface, with mutation operators, validation, rollback, and SOUL-drift gate. **Dormant/offline/CLI-only in M3** — no background scheduler, no live auto-deploy.

> **v2 changelog (folds G-M3-spec v1 review run `3e771c6e` — 1 BLOCKER, 7 MAJOR):**
> - **BLOCKER-1 fixed (§3.1):** `is_protected_config_key()` denylist at the top of the existing ConfigAdjustment arm (before `write_config`), covering canonical keys + aliases. **CONFIRMED-CLOSED in re-review (`81dafa80`).**
> - **MAJOR-1, 4, 5, 6, 7 CONFIRMED-CLOSED in re-review.**
> - MAJOR-2, MAJOR-3 required v3 refinement (see v3 changelog).
>
> **v3 changelog (folds G-M3-spec v2 re-review run `81dafa80` — 5 CONFIRMED-CLOSED, 2 STILL-OPEN, 1 NEW-MAJOR):**
> - **MAJOR-2 closed (§2.3): direct→chain role-slot construction.** A direct recipe has only a Worker slot; `AdjustVerifier` adds only a Verifier; `SwitchTopology` carried no slot plan — so direct→chain could not construct the required Thinker→Worker→Verifier slots. v3 adds `SetRoleSlotPlan { plan: Vec<RoleSlotSpec> }` as a sixth data-only batch element: it lets a batch define the full target role-slot plan atomically. It is **not a new mutation operator in the ADR-008a sense** — it is the *construction surface* that makes `SwitchTopology` + `AdjustVerifier` composable; the post-state still must pass `validate_for(V1Safe)` and all four constraints. (Clarified as a batch-construction element, not a capability expansion.)
> - **MAJOR-3 closed (§2.1): fanout formula field corrections.** Fixed the factual error: the field is `StopPolicy.max_correction_loops` (NOT `max_verifier_loops`). Added explicit comparison against `BudgetPolicy.max_cost_micros` and `max_role_calls`, the real cap fields.
> - **NEW-MAJOR-1 closed (§2.2): atomic-batch invariants.** `validate_batch` rejects mixed `recipe_id`s; `apply_change` captures `prior_version` before `apply_batch` so the rollback closure is unambiguous. Tests: `batch_rejects_mixed_recipe_ids`, `apply_change_conductor_recipe_captures_prior_version_for_rollback`.
> - **NEW-MINOR-1 closed (§1.1):** `deny_unknown_fields` on the patch enum + each variant.
> - **NEW-MINOR-2 closed (§3.1):** protected-key matching canonicalizes separators (`-`/`_`/`.`/camelCase → single canonical form) before comparison, closing `model-mode`/`availability.mode` variants without alias-list growth.

---

## 0. Design posture (non-negotiable)

M3 is the **protected-kernel surface**: autonomous mutation of the egress-affecting routing recipe. Three principles govern the entire milestone:

1. **Dormant/offline/CLI-only.** M3 lands the surface, operators, validation, rollback, and gates as **offline / CLI-triggered** code. There is **no background scheduler task**, **no live auto-deploy**, **no default route mutation** in M3. A human runs `fae conductor metaopt-run --recipe <id>`; the run proposes patches; validation + the F-12/F-16 benchmark gates decide; the human approves promotion. The live autonomous loop is a **later gated step** (post-M3), not M3.
2. **The recipe is data, not code.** A `ConductorRecipePatch` is a **data value** (an enum of allowed mutations). The daemon's adapter **interprets** it against `FaeConductorRecipe`. Candidate policies under shadow evaluation remain **data-only interpreted recipes** — never arbitrary executable policy code. This is the shadow router's no-egress-seam guarantee extended into M3 (see `shadow.rs` module docs, honesty note).
3. **Two-layer enforcement (ADR-008a).** Layer 1 = proposal-structural (the validator rejects constraint-violating patches *before* they are proposed). Layer 2 = runtime-authoritative (the M2 §5 gate pipeline re-asserts mode/membrane/budget/approval every turn regardless of recipe content). **A mutation changes preference; the runtime gates own permission.** Both layers must be test-enforced.

---

## 1. Decoupling + MetaOptimizer integration

### 1.1 In `fae-metaopt` — the data patch type + port trait

```rust
// crates/fae-metaopt/src/conductor_recipe.rs (NEW)

/// A mutation a MetaOpt run may propose on a conductor recipe.
/// DATA ONLY — the daemon adapter interprets this against FaeConductorRecipe.
/// Maps to ADR-008a's five allowed operators + one batch-construction element (v3).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum ConductorRecipePatch {
    /// (ADR-008a op 1) Swap the worker in ONE role slot. `to_worker` must be
    /// same-or-lower trust tier AND provisioned. Names the role slot explicitly.
    SwapWorker {
        recipe_id: String,
        role: ConductorRoleDto,
        to_worker: String,
    },
    /// (ADR-008a op 2) Switch topology direct ↔ chain. **For direct→chain, pair
    /// with `SetRoleSlotPlan` in the same batch** to construct the required
    /// Thinker→Worker→Verifier slots (a direct recipe has only a Worker slot).
    SwitchTopology { recipe_id: String, to: ConductorTopologyDto },
    /// (ADR-008a op 3) Add or remove a Verifier role (chain only). Adding
    /// requires the worker + prompt + schema the new slot will use.
    AdjustVerifier {
        recipe_id: String,
        action: VerifierAction,
        worker: Option<String>,
        prompt_template_id: Option<String>,
        output_schema: Option<String>,
    },
    /// (ADR-008a op 4) Mutate a role-conditioned prompt. Lint-gated (§5).
    MutateRolePrompt {
        recipe_id: String,
        role: ConductorRoleDto,
        new_prompt: String,
    },
    /// (ADR-008a op 5) Adjust budget. Downward always; upward within cap (§2.1).
    AdjustBudget { recipe_id: String, delta_micros_per_day: i64 },
    /// (v3, NEW-MAJOR-1 fix) **Batch-construction element, not a new operator.**
    /// Sets the full target role-slot plan atomically. Required for direct→chain
    /// (a direct recipe's single Worker slot cannot become Thinker→Worker→Verifier
    /// via `AdjustVerifier` alone, which only adds a Verifier). The post-state
    /// MUST still pass `validate_for(V1Safe)` and all four constraints — this
    /// element constructs slots; it does not widen capability. All workers named
    /// in the plan must be provisioned + same-or-lower tier.
    SetRoleSlotPlan { recipe_id: String, plan: Vec<RoleSlotSpec> },
}

/// A data-only spec for a role slot (used by `SetRoleSlotPlan`). Mirrors the
/// daemon's `RoleSlot` minus the mutation internals. All fields explicit — no
/// implicit defaults — so a batch is fully auditable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoleSlotSpec {
    pub role: ConductorRoleDto,
    pub worker: String,
    pub prompt_template_id: String,
    /// The prompt body is set separately via `MutateRolePrompt`; here it is the
    /// initial/template body for a newly-constructed slot.
    pub prompt_template: String,
    pub output_schema: Option<String>,
    pub required: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VerifierAction { Add, Remove }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum ConductorTopologyDto { Direct, Chain }
// star / debate are ABSENT — unnameable. serde deny_unknown_fields ⇒ fail-closed.

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum ConductorRoleDto { Thinker, Worker, Verifier }
```

```rust
/// The port the daemon implements. fae-metaopt calls it; fae-metaopt does NOT
/// import FaeConductorRecipe.
#[async_trait]
pub trait ConductorRecipePort: Send + Sync {
    /// Validate a patch (or batch) against the four ADR-008a constraints WITHOUT
    /// applying. Returns the projected post-state summary or a Rejection.
    async fn validate_patch(
        &self,
        patch: &ConductorRecipePatch,
    ) -> Result<RecipeSummary, PatchRejection>;

    /// Validate a BATCH atomically — the post-state after ALL patches applied.
    /// Used when a mutation needs multiple operators to stay valid (§2.2).
    async fn validate_batch(
        &self,
        patches: &[ConductorRecipePatch],
    ) -> Result<RecipeSummary, PatchRejection>;

    /// Apply a validated batch as ONE new recipe version (atomic). The impl MUST
    /// call validate_batch first (defense-in-depth). Returns the new version.
    async fn apply_batch(
        &self,
        patches: &[ConductorRecipePatch],
    ) -> Result<u32, RecipePortError>;

    /// Roll back to a prior recipe version. Revalidates against CURRENT registry/
    /// caps/profile before re-activation (MAJOR-5).
    async fn rollback(&self, recipe_id: &str, to_version: u32) -> Result<(), RecipePortError>;

    async fn current_recipe_summary(
        &self, recipe_id: &str,
    ) -> Result<RecipeSummary, RecipePortError>;
}
```

### 1.2 In `fae-daemon` — the adapter (Layer 1 enforcement + persistence)

`DaemonConductorRecipePort` implements `ConductorRecipePort`. It resolves `recipe_id` → `FaeConductorRecipe`, validates the patch/batch against the four constraints (§3), applies by constructing a new version, persists via `ConductorStore::store_recipe` (atomic write + versioned), records a `RecipeMutationEvent`, and rolls back by revalidating + re-activating a prior version. **No `fae-metaopt` → `fae-daemon` dependency.**

### 1.3 MetaOptimizer integration (MAJOR-1)

The patch surface plugs into the **existing** optimizer flow, not alongside it:

- `MetaOptSurface` gains `ConductorRecipe` (remove the ADR-gating doc comment in `types.rs`).
- `MetaOptChange` gains a variant: `ConductorRecipePatch { patches: Vec<ConductorRecipePatch> }` — a batch is one `MetaOptChange` (atomic, one version).
- `MetaOptimizer` gains an `Option<Arc<dyn ConductorRecipePort>>` field + setter, parallel to the existing ports.
- `MetaOptimizer::apply_change` gains a `MetaOptChange::ConductorRecipePatch { patches }` arm that calls `recipe_port.validate_batch(&patches)` then `apply_batch(&patches)`, and returns a `MetaOptRollback` closure that calls `recipe_port.rollback(recipe_id, prior_version)`. **This closes the batch into the existing keep/rollback discipline** — a rejected benchmark rolls the whole batch back.
- The hypothesis source may propose `ConductorRecipePatch` hypotheses; the optimizer's benchmark gate (F-12 + F-16) decides keep vs rollback exactly as for the other four surfaces.

---

## 2. The five allowed operators (ADR-008a) — role-slot-aware

| # | Operator | Patch | Constraint |
|---|---|---|---|
| 1 | Swap worker | `SwapWorker { role, to_worker }` | `to_worker` **same-or-lower trust tier** AND **provisioned** (registry + valid creds). Unprovisioned/higher ⇒ reject. |
| 2 | Switch topology | `SwitchTopology { to }` | `direct ↔ chain` only. `star`/`debate` absent from DTO (unnameable). |
| 3 | Add/remove Verifier | `AdjustVerifier { action, worker?, prompt?, schema? }` | `chain` only; `Verifier` role only. Add requires explicit worker+prompt+schema. |
| 4 | Mutate role prompt | `MutateRolePrompt { role, new_prompt }` | Lint-gated (§5). |
| 5 | Adjust budget | `AdjustBudget { delta_micros_per_day }` | `delta < 0` always; `delta > 0` only if `current_cap + delta ≤ provisioned_cap(worker)`. |

### 2.1 Egress-multiplication budget re-check (MAJOR-3 — exact formula, v3 field-corrected)

When a patch (or batch) changes the post-state's role-slot count, the validator recomputes the worst-case per-turn cost and re-checks the budget against the **real** `BudgetPolicy` + `StopPolicy` fields:

- **Post-state role count** `n = post.role_slots.len()` (direct ⇒ 1; chain ⇒ up to 3).
- **`BudgetPolicy.max_role_calls >= n`** — the recipe's own cap must accommodate the fanout. Violation ⇒ `PatchRejection::FanoutExceedsRoleCallCap`.
- **Worst-case per-turn cost** = `Σ over role_slots of estimate_cost(slot.worker, prompt, max_output_tokens)`.
  - **Verifier-loop multiplier (v3 correction):** the Verifier slot's cost is multiplied by `StopPolicy.max_correction_loops + 1` (the actual field name in `recipe.rs`; v2's `max_verifier_loops` was wrong). So worst-case Verifier contribution = `estimate_cost(verifier_worker, ...) * (post.stop.max_correction_loops + 1)`.
  - **Uncostable-worker fail-closed:** if any slot's worker has no pricing row, the check **fails closed** (`PatchRejection::UncostableWorkerInChain`) — an uncostable worker in a multiplied-fanout chain cannot be budget-gated, so it is rejected.
- **Cap comparisons (v3 — against the real fields):**
  - `worst_case_cost <= BudgetPolicy.max_cost_micros.unwrap_or(u64::MAX)` — if exceeded ⇒ `PatchRejection::BudgetExceedsCostCap`.
  - Per-worker daily buckets (D2): each distinct worker's projected daily spend under the multiplied fanout must fit its provisioned per-worker bucket.
  - `BudgetPolicy.max_tokens` (if `Some`) must accommodate `Σ max_output_tokens * (verifier_multiplier where applicable)`.
- **Interaction with `AggregationPolicy`:** does not change fanout (aggregation synthesizes the Verifier-approved answer); no extra cost term. `StopPolicy.stop_after_verifier` / `stop_on_budget_exhaustion` are respected by the executor at runtime (Layer 2), not re-checked here.

**Tests:** `direct_to_chain_rechecks_budget_fanout`, `add_verifier_rechecks_budget`, `multi_worker_chain_per_bucket_check`, `uncostable_worker_in_chain_rejected`, `verifier_loops_multiplied_in_worst_case` (uses `max_correction_loops`), `cost_cap_exceeded_rejected` (against `max_cost_micros`).

### 2.2 Atomic patch batches (MAJOR-2 + §11 Q4 + v3 NEW-MAJOR-1)

A single mutation often needs multiple operators to keep the recipe valid: `direct → chain` requires `SwitchTopology` **plus** `SetRoleSlotPlan` (Thinker/Worker/Verifier) **plus** possibly `AdjustBudget`. Applying these as separate versions would pass through an **invalid intermediate state** (chain with a single Worker slot fails `validate_for(V1Safe)`).

- A batch is `Vec<ConductorRecipePatch>` applied **atomically as one new version**.
- **Same-recipe invariant (v3 NEW-MAJOR-1):** every patch in a batch MUST target the **same `recipe_id`**. `validate_batch` rejects mixed recipe IDs ⇒ `PatchRejection::MixedRecipeIds`. (A batch is one recipe's mutation; multi-recipe coordination is not in M3.)
- The validator runs `validate_batch` on the **projected post-state after ALL patches** — not per-patch. Intermediate states are never persisted.
- Every batch's post-state MUST pass `FaeConductorRecipe::validate_for(RecipeProfile::V1Safe)`. Invalid post-state ⇒ `PatchRejection::InvalidPostState`.
- **Prior-version capture (v3 NEW-MAJOR-1):** `MetaOptimizer::apply_change`'s `ConductorRecipePatch` arm captures `prior_version = recipe_port.current_recipe_summary(recipe_id).version` **before** calling `apply_batch`, so the returned rollback closure calls `recipe_port.rollback(recipe_id, prior_version)` unambiguously. (No reliance on `new_version - 1`, which would be wrong if another writer bumped the version concurrently.)
- Rollback is whole-version (§4) — undoing a batch = rolling back one version.

**Tests:** `batch_applied_as_one_version`, `invalid_post_state_rejected` (chain with a single Worker slot), `batch_rollback_is_whole_version`, `batch_rejects_mixed_recipe_ids`, `apply_change_conductor_recipe_captures_prior_version_for_rollback`.

---

## 3. The four enforceable constraints (Layer 1 validation)

The validator rejects any patch/batch whose projected post-state would:

| # | Constraint | Reject if | Test |
|---|---|---|---|
| 1 | **Widen a privacy lane** | post-state `privacy_lane` is wider than current. Order: `LocalOnly ⊂ CloudBacked ⊂ OwnerFleet ⊂ TrustedPeer ⊂ RemoteAllowed`. Keep-or-narrow only. | `reject_lane_widening` |
| 2 | **Raise budget above provisioned cap** | post-state budget exceeds the worker's provisioned D2 ceiling (accounting for §2.1 fanout). | `reject_budget_above_provisioned_cap` |
| 3 | **Introduce gated locality/topology** | patch names `TrustedPeer`/`RemoteAllowed`/`star`/`debate`. **Structurally impossible** — absent from DTOs + `deny_unknown_fields` ⇒ serde fail-closed. | `serde_rejects_forbidden_variants` |
| 4 | **Override `ModelMode`** | (a) no `ConductorRecipePatch` variant names it; (b) **see §3.1** — the denylist closes the ConfigKnob path. | `reject_model_mode_via_config_knob` + alias tests |

### 3.1 BLOCKER-1 fix: the protected-config-key denylist

The existing `MetaOptimizer::apply_change` ConfigAdjustment path writes **unbounded** keys verbatim (`optimizer.rs`: the `if let Some(bound)` check only bounds known keys; `FAE_MODEL_MODE` skips it and reaches `write_config`). This is a pre-existing latent hole that ADR-008a constraint #4 requires closed. **Closed in M3:**

- New `is_protected_config_key(key: &str) -> bool` in `fae-metaopt/src/conductor_recipe.rs`, called at the **top** of the ConfigAdjustment arm in `apply_change`, before any `write_config`. A protected key ⇒ `MetaOptError::ProtectedConfigKey(key)` (hard reject, no write).
- **Canonicalization before matching (v3 NEW-MINOR-2):** the key is normalized to a canonical form before comparison: Unicode NFKC + lowercase + **separator canonicalization** (all of `-`, `_`, `.`, camelCase boundaries → a single separator e.g. `_`). This closes `model-mode` / `availability.mode` / `modelMode` variants without alias-list growth. The alias list is then the fallback for genuinely different spellings.
- **Alias list** (post-canonicalization): `fae_model_mode`, `model_mode`, `conductor_model_mode`, `availability_mode`.
- **Tests:** one test per alias, the property test (substring `model_mode` / `availability_mode` post-canormalization rejected), **and** separator-variant tests (`model-mode`, `availability.mode`, `modelMode` all rejected).
- **Scope note:** this denylist is general — it protects *any* config key that controls egress/safety posture, not only model mode. Extensible to future protected keys (e.g. `piilocy_lane_default`) without changing the `apply_change` call site.

**Layer 2 (runtime, authoritative — already built in M2):** the §5 gate pipeline re-asserts mode/membrane/budget/approval every turn regardless of recipe/config content. Even a config write that slipped Layer 1 cannot bypass egress: the mode is loaded from `ConductorEgress` at runtime, and the mode cap rejects unpermitted lanes. **Cross-ADR dependency:** the argument holds while the M2 §5.6 invariant (membrane-before-construction) holds — that test is a standing precondition (ADR-008a Risks).

---

## 4. Rollback (whole-recipe-version, revalidating — MAJOR-5)

- The recipe store is versioned: `recipes/<recipe_id>.v<version>.json`.
- **`rollback(recipe_id, to_version)` revalidates the prior version against the CURRENT registry/caps/profile before re-activation** — not just deserialization. A recipe valid when written may be unsafe now (worker de-provisioned, cap lowered, lane policy tightened). Revalidation failure ⇒ `RecipePortError::RollbackTargetInvalid(reason)`; the recipe stays at its current version.
- **Revalidation = the full Layer 1 check** (§3) + F-15 on deserialize (rejects star/debate on the way back in) + `validate_for(V1Safe)`.
- **Per-operator partial rollback is NOT supported.** ADR-008a specifies "Restore previous recipe version" — one atomic unit. "Undo last change" = `rollback(recipe_id, current_version - 1)`.
- **Tests:** `rollback_restores_prior_version`, `rollback_rejects_star_debate_on_deserialize` (F-15 on the way back in), `rollback_rejects_unprovisioned_worker` (MAJOR-5), `rollback_rejects_above_current_cap`.

---

## 5. Prompt-mutation lint (op 4 gate) — expanded (MAJOR-4, MINOR-2)

`MutateRolePrompt` patches are lint-gated. The lint is **deterministic** and runs on the **canonicalized** prompt (§5.1). Model judgment is never invoked at this layer.

### 5.1 Canonicalization (before any lint rule)

1. Unicode NFKC normalization.
2. Lowercase.
3. Strip zero-width characters (`\u{200b}`, `\u{200c}`, `\u{200d}`, `\u{feff}`, combining marks that render nothing).
4. Decode obvious encodings-in-prose (base64-looking blobs ≥32 chars, hex blobs ≥32 chars, rot13) and re-scan the decoded form. (Conservative: if decode is ambiguous, treat as suspicious.)

### 5.2 Lint rules

| Lint rule | Rejects | Rationale |
|---|---|---|
| `no_secret_exfiltration` | instructions to emit/encode/base64/hex secrets, keys, tokens, creds | egress-safety |
| `no_full_memory_export` | instructions to dump/recall/export the full memory store or entity graph | compartmentalization (ADR-012 principle 3) |
| `no_gate_bypass` | instructions to ignore/bypass the membrane/budget/approval gates or "route around" them | protected-kernel integrity |
| `no_tool_authority_expansion` (**MAJOR-4**) | instructions granting/requesting **new tools, network, filesystem, or post-spawn autonomous behavior**. Role prompts may adjust decomposition/style/output constraints only. Tool permission stays executor/ACP-policy-owned. | capability boundary |
| `no_router_jargon` | conductor internals jargon (`PrivacyLane`, `BudgetGovernor`, `MetaOpt`, route/recipe/worker ids) | narrator copy (SOUL) |
| `preserves_soul_framing` | drops head-butler/SOUL identity framing | F-16 personality preservation |

**Tests:** one per rule, plus bypass tests (`base64_secret_exfil_rejected`, `unicode_obfuscation_rejected`, `homoglyph_spacing_rejected`). Conservative-reject is the M3 posture (§11 Q2): no automated lint override; false positives are fixed by editing the patch or improving the lint, never by bypassing the gate.

---

## 6. F-16: SOUL-drift proxy metric (local-only/deterministic — MAJOR-6)

Two deterministic layers; model judgment **advisory only**.

### 6.1 Layer A — held-out SOUL eval corpus (local-only, deterministic)

A **separate versioned corpus** (`soul_drift_corpus_v1.json`) distinct from the routing corpus (D7). Each entry: `(prompt, expected_persona_markers)` with deterministic checks (companion first-person voice; SOUL identity tokens; no router jargon; tone/length bounds).

**MAJOR-6 — no-egress guarantee:** F-16 eval runs **local-only**. Either (a) scored against **fixed fixture responses** baked into the corpus (no generation at all — the mutated prompt is lint-checked, not executed), or (b) generated via the **on-device local model under a fixed seed** with `ModelMode::PureLocal` forced for the eval turn. **Never** cloud/ACP. **Test: `soul_drift_eval_never_egresses`** — the eval path holds no `CloudProvider`/`AcpAgentRunner` seam (same structural discipline as the shadow router).

A **drift regression** = any entry where persona-marker pass rate drops below baseline by more than `SOUL_DRIFT_THRESHOLD` (default 0% — zero tolerance for persona regression).

### 6.2 Layer B — prompt-structure lint (§5)

The §5 lint runs on every `MutateRolePrompt`. Per-patch gate; Layer A is per-run.

### 6.3 Model self-judgment — advisory only (F-10 discipline)

A model's "does this still sound like Fae" assessment may be recorded as **advisory** input to a human reviewer, but **may never be the sole positive evidence** a mutation is drift-free. A deterministic Layer A/B failure cannot be overridden by model judgment.

### 6.4 Review trigger

A drift regression (Layer A or B) **blocks promotion entirely** and flags the mutation for **human review**. Fires per-mutation (M3 is offline/CLI).

---

## 7. Promotion gate (F-12 + F-16 combined)

A proposed batch is **promoted** (new version activated) only if **all** pass:

1. **Layer 1 validation** (§3) — no constraint violation.
2. **Prompt lint** (§5) — no lint failure.
3. **F-12 routing improvement** — `is_improvement` on the **routing** corpus (D7): same `corpus_version` AND McNemar-significant AND ≥5% relative AND no per-dimension regression.
4. **F-16 SOUL-drift** — zero persona regression (Layer A) AND all lint passes (Layer B).
5. **Human review** (M3) — a human approves the promotion-candidate flag. **M3 does not auto-promote.**

Failure ⇒ mutation not applied; `RecipeMutationRejected` logged with the reason. Recipe stays at current version.

---

## 8. Dormant wiring (what M3 ships, what it doesn't) — MAJOR-7

**M3 ships (dormant / CLI-only):**
- `ConductorRecipePatch` + DTOs + `ConductorRecipePort` in `fae-metaopt`.
- The §3.1 protected-config-key denylist (BLOCKER-1 fix).
- `MetaOptChange::ConductorRecipePatch` + `MetaOptimizer` integration (MAJOR-1).
- `DaemonConductorRecipePort` adapter (validator + applier + rollback) in `fae-daemon`.
- Five operators + Layer 1 validation + prompt lint + SOUL-drift corpus + gates.
- A **CLI command** `fae conductor metaopt-run --recipe <id>` that runs the offline loop once: propose → validate → benchmark → gate → flag for human review.
- Full test coverage (§9).

**M3 does NOT ship:**
- **No scheduler task.** No `metaopt_recipe_mutation` periodic task. **Test/assertion: `no_default_scheduled_metaopt_mutation_task`** — the scheduler's default task set does not include a MetaOpt mutation task. (A scheduler task may be added post-M3 behind its own gate.)
- No live auto-deploy (promotion is human-act in M3).
- No mutation of `ModelMode`, lanes above `CloudBacked`, or `star`/`debate` (ever — ADR-gated).
- No cross-owner/mesh integration (M4+).

Scoped `#[allow(dead_code)]` with `TODO(post-M3)` until the live loop lands.

---

## 9. Acceptance / test matrix

**BLOCKER-1 (protected config keys):** `reject_model_mode_via_config_knob` + one per alias + property test (substring `model_mode`/`availability_mode` post-normalization).

**Layer 1 (§3):** `reject_lane_widening`, `reject_budget_above_provisioned_cap`, `serde_rejects_forbidden_variants` (star/debate/trustedPeer/remoteAllowed), `reject_model_mode_mutation` (no variant names it), `reject_unprovisioned_worker_swap`, `reject_higher_tier_worker_swap`.

**Fanout (§2.1):** `direct_to_chain_rechecks_budget_fanout`, `add_verifier_rechecks_budget`, `multi_worker_chain_per_bucket_check`, `uncostable_worker_in_chain_rejected`, `verifier_loops_multiplied_in_worst_case` (uses `max_correction_loops`), `cost_cap_exceeded_rejected` (against `max_cost_micros`).

**Atomic batches (§2.2):** `batch_applied_as_one_version`, `invalid_post_state_rejected` (chain with a single Worker slot), `batch_rollback_is_whole_version`, `batch_rejects_mixed_recipe_ids`, `apply_change_conductor_recipe_captures_prior_version_for_rollback`.

**Role-slot construction (§2.3):** `set_role_slot_plan_constructs_chain_slots` (direct→chain via `SwitchTopology`+`SetRoleSlotPlan` batch yields valid Thinker→Worker→Verifier), `set_role_slot_plan_rejects_unprovisioned_worker`.

**Prompt lint (§5):** one per rule + `base64_secret_exfil_rejected`, `unicode_obfuscation_rejected`, `homoglyph_spacing_rejected`, `no_tool_authority_expansion_rejected`.

**F-16 (§6):** `persona_regression_blocks_promotion`, `model_self_judgment_cannot_override_deterministic_drift`, `soul_drift_eval_never_egresses`.

**Rollback (§4):** `rollback_restores_prior_version`, `rollback_rejects_star_debate_on_deserialize`, `rollback_rejects_unprovisioned_worker`, `rollback_rejects_above_current_cap`.

**F-12 / no-auto-promote:** `promotion_requires_is_improvement`, `no_auto_promotion_in_m3` (CLI flags for human review; no `apply_batch` without the approval step).

**Dormant (§8):** `no_default_scheduled_metaopt_mutation_task`.

**DTO (MINOR-1):** `deny_unknown_fields_rejects_unknown`, daemon↔DTO conversion round-trip.

**Gates:** `cargo fmt --all`, `cargo clippy -p fae-daemon -p fae-metaopt --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used`, `cargo check --workspace --all-targets`, full test run.

---

## 10. Files touched (post-spec-approval)

**`crates/fae-metaopt/`:**
- `src/conductor_recipe.rs` — NEW: patches, DTOs, `ConductorRecipePort`, `is_protected_config_key` + alias list, `PatchRejection`, `RecipePortError`, `RecipeSummary`.
- `src/types.rs` — `MetaOptSurface::ConductorRecipe` (remove ADR-gating doc comment); `MetaOptChange::ConductorRecipePatch { patches }`.
- `src/optimizer.rs` — `recipe_port` field + setter; `apply_change` ConductorRecipePatch arm (validate_batch → apply_batch → rollback closure); **protected-key denylist call at the top of the ConfigAdjustment arm** (BLOCKER-1).
- `src/lib.rs` — `pub mod conductor_recipe;`

**`crates/fae-daemon/src/conductor/`:**
- `recipe_mutation.rs` — NEW: `DaemonConductorRecipePort`.
- `prompt_lint.rs` — NEW: §5 lint + canonicalization.
- `soul_drift.rs` — NEW: F-16 Layer A (local-only).
- `store.rs` — `append_recipe_mutation_event`.
- `mod.rs` — declare modules + scoped dead-code allows.

**Data:** `crates/fae-daemon/data/soul_drift_corpus_v1.json` (seed entries).

**Docs:** tracker M3 items; `docs/checklists/app-release-validation.md` — MetaOpt/recipe-mutation validation task.

---

## 11. Resolved open questions (from v1)

1. **SOUL corpus:** David is annotator (single-annotator, like D7). Target **30 entries** (10 is only a smoke test). Cover companion tone, refusal/safety, memory humility, tool delegation, head-butler framing.
2. **Lint false positives:** conservative-reject is correct for M3. No automated override. Fix the patch or improve the lint; never bypass the gate.
3. **Manual trigger UX:** **CLI-only** for M3. No scheduler task (MAJOR-7).
4. **Inter-patch ordering:** **atomic patch batch as one candidate version** when needed for recipe validity (§2.2). Rollback stays whole-version.

## 12. Deferred (NOTE-1 — non-blocking, later cleanup)

ADR-012 has residual membrane-overclaim wording ("The protection is the PII membrane", "Security rests on the PII membrane + DamageControlPolicy") beyond the header already fixed (`e51b6a6b`). The M3 spec uses the corrected framing; the ADR cleanup is a separate docs pass, not an M3 prerequisite.
