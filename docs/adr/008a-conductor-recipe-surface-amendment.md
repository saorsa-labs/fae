# ADR-008a: ConductorRecipe MetaOpt Surface Amendment

**Status:** Proposed (Amendment)
**Date:** 2026-06-23
**Owner:** David Irvine
**Amends:** [ADR-008 — Autonomous Self-Improvement (Meta-Optimization)](008-autonomous-self-improvement.md) (§Decision, "Four optimization surfaces")
**Scope:** ADR-008's surface set; `crates/fae-metaopt/src/types.rs` (`MetaOptSurface` enum); the conductor recipe surface in `crates/fae-daemon/src/conductor/recipe.rs` (`FaeConductorRecipe`, `PrivacyLane`, `ConductorTopology`); the M2 per-role-call executor gate pipeline (`crates/fae-daemon/src/conductor/executor.rs`)

> David accepts ADRs. This amendment is **Proposed**, not Accepted, until David's review.

## Context

ADR-008 authorized a hill-climbing optimization loop over **four** runtime-mutable surfaces — Directive, ConfigKnob, Skill, MemorySeed. Three properties hold for all four: each change is **reversible** (rollback), each is **tested before deployment** (no blind application), and **none routes user data off-device**. The [ADR README](README.md) explicitly anticipates this amendment: *"Its autonomous-mutation scope will need an amendment before it covers a Rust-side `conductorRecipe` surface."*

That surface now exists. ADR-011 makes the headless **Rust core** the canonical runtime; the learned conductor (M1 static recipes, M2 reward/eval/shadow routing) is built Rust-side under `crates/`. The conductor's routing unit is a **recipe** (`FaeConductorRecipe`): it binds a topology, a worker, a privacy lane, a budget, and role-conditioned prompts into a single decision (`OwnedRouteDecision`). The `MetaOptSurface` enum in `crates/fae-metaopt/src/types.rs` deliberately **omits** a conductor-recipe variant — its doc comment reads: *"There is deliberately no conductor-recipe surface here; that is gated on the ADR-008 amendment for M3."* This amendment authorizes adding it.

Recipe mutation is **uniquely dangerous** relative to the other four surfaces. The other four change Fae's own local behavior; a recipe, by contrast, can:

- **route to cloud providers** — a privacy/egress concern (prompt leaves the device),
- **spend money** — a budget concern (cloud calls cost real money),
- **delegate to peers** — a trust concern (cross-owner egress).

For that reason, authorization here is **conditional on hard, enforceable runtime constraints** — not unconditional. ADR-008's "test before deployment" principle and its hill-climbing invariant ("no change persists without measured improvement") carry forward unchanged and are reinforced below.

## Decision

### Add `ConductorRecipe` as a 5th MetaOptimization surface — conditionally

Add `MetaOptSurface::ConductorRecipe` to the `MetaOptSurface` enum, extending ADR-008's four-surface table:

| Surface | Change Type | Rollback | Egress? |
|---------|------------|----------|---------|
| **Directive** (Layer 4) | Append instruction text | Restore previous text | No |
| **ConfigKnob** | Adjust temperature, maxRecallResults | Restore old value | No |
| **Skill** | Create instruction-only `auto-*` skills | Deactivate + delete | No |
| **MemorySeed** | Insert `meta_opt_seed` tagged facts | Delete record | No |
| **ConductorRecipe** *(this amendment)* | Mutate routing recipe (operators below) | Restore previous recipe version | **Possibly** — but gated (see below) |

Like the other four, ConductorRecipe changes are **reversible** (the recipe store is versioned: `recipes/<id>.v<ver>.json`) and **tested before deployment** (F-12 `is_improvement()` gate). Unlike the other four, a recipe can route off-device — so this authorization is gated by the two-layer enforcement model below.

### Allowed mutation operators

MetaOpt may propose, on the `ConductorRecipe` surface, **only** these mutation operators (to be implemented in the `fae-metaopt` crate's ConductorRecipe mutation operator during M3):

1. **Swap the selected worker** — within the same-or-lower trust tier only (never to a higher tier).
2. **Switch topology** — `direct` ↔ `chain`.
3. **Add or remove a Verifier role** — within the `chain` topology.
4. **Mutate a role-conditioned prompt** — e.g. adjust the Thinker/Worker/Verifier system prompts.
5. **Adjust the recipe's budget** — **downward only**, or **upward only within the operator's already-provisioned cap** (the D2 ceiling on the worker). Never above the provisioned ceiling.

### Enforceable constraints (what MetaOpt-proposed mutations MUST NOT be able to do)

These are the hard limits. A MetaOpt-proposed recipe mutation **must not** be able to:

1. **Widen a privacy lane.** The lanes form a monotone widening order `LocalOnly` ⊂ `CloudBacked` ⊂ `OwnerFleet` ⊂ `TrustedPeer` ⊂ `RemoteAllowed`. A mutation may only **keep-or-narrow** the lane (e.g. `CloudBacked` → `LocalOnly` is allowed; `LocalOnly` → `CloudBacked` is **not**). Mutations that widen are rejected.

2. **Override a budget cap without the provisioning/approval gate.** A mutation cannot raise a cap **above the operator's provisioned ceiling** for that worker. Upward adjustment is permitted only within the already-provisioned cap; exceeding it requires the credential-provisioning / approval gate, which is not reachable via recipe mutation.

3. **Introduce `trustedPeer` / `remoteProvider` lanes, or `star` / `debate` topologies.** These remain **ADR-gated / M4+**. They are not reachable via recipe mutation:
   - `TrustedPeer` and `RemoteAllowed` lanes require cross-owner grants — a separate ADR decision.
   - `Star` and `Debate` topologies are **intentionally absent** from the `ConductorTopology` enum (compile-time unreachable, F-15; serde-rejected fail-closed on deserialization). Enabling them is a deliberate M3+ code change requiring eval evidence + owner approval.

### How the constraints are enforced — defense-in-depth (the load-bearing argument)

The constraints are enforced at **two independent layers**. This is the argument that makes the surface safe to mutate: **a mutation changes *preference*; the runtime gates own *permission*.**

**Layer 1 — Proposal layer (structural, in `fae-metaopt`).** MetaOpt's mutation operators are structurally limited to the allowed set above. A mutation that would violate a constraint — widen a lane, raise a cap above the provisioned ceiling, or name a forbidden lane/topology — is **rejected before it is ever proposed**. To be built in the `fae-metaopt` crate's ConductorRecipe mutation operator during M3.

**Layer 2 — Runtime layer (authoritative, in the conductor executor).** This is the layer that actually owns permission. The M2 executor's **§5 gate pipeline re-asserts `mode-cap → PII-membrane → budget → approval` on every turn, regardless of recipe content.** The recipe is **advisory**; the runtime gates are **authoritative**. So even a maliciously or erroneously mutated recipe **cannot bypass egress protection**, because the gates run in a load-bearing order:

- The **PII membrane runs before any cloud-bound request is constructed** (M2 §5.3 runs before §5.6).
- The **budget check runs before the call** (§5.4).
- The **approval gate runs before egress** (§5.5).
- §5.6 **constructs the provider request *after* gates 5.2–5.5 pass.**

A mutated recipe that *claims* a widened lane or an *overridden* cap is still gated by the runtime — the mode cap rejects a lane the operator hasn't permitted, the membrane still strips/blocks egress, the budget governor still caps spend at the provisioned ceiling, and the approval assertion still demands a valid grant. Any gate failure degrades the turn to **direct-local** (the M1 zero-egress path) with zero cloud calls. **Recipe mutation changes which route is *preferred*; the runtime gates decide whether it is *permitted*.**

This two-layer design means a single bug in one layer does not break egress safety: a proposal-layer bug is caught by the runtime gates; a hypothetical runtime-gate regression would still be bounded by the proposal layer's structural limits. Neither layer alone is a single point of failure.

### Tie-ins

- **ADR-005 (Self-modification safety).** MetaOpt operates within the SAL (self-authored layer). The runtime-gates-as-authority pattern is consistent with ADR-005's model: the protected kernel (PK) — the executor and its gate pipeline — owns the non-self-modifiable safety spine, while the SAL-owned recipe expresses only preference. The recipe is SAL (mutable); the gates are PK (authoritative). This matches ADR-005's recovery invariant that the safety policy remains PK-owned.
- **ADR-011 (Headless Rust core).** Both the mutation operators (Layer 1) and the runtime gates (Layer 2) are **Rust-side and canonical**. There is **no Swift bridge** for either. This amendment does not add any Swift surface.
- **M2 eval gate (F-12).** Recipe-mutation promotion uses `RoutingScorer::is_improvement()` on the **versioned, human-labeled corpus**: a mutation only lands if it is a *measured* improvement (same `corpus_version` **and** statistically significant via the real McNemar exact test **and** ≥5% relative **and** no per-dimension regression). No blind application — consistent with ADR-008's "test before deployment" principle and the hill-climbing invariant.

## Alternatives considered

1. **No `ConductorRecipe` surface ever** — keep recipes human-authored only, leaving routing out of the optimization loop. **Rejected.** Routing is the **highest-leverage optimization axis** of the conductor (which worker/topology/role decomposition serves a request best). Excluding it permanently leaves the central learned-routing capability unlearned, and is inconsistent with ADR-008's thesis that runtime-mutable surfaces should be measured-and-optimized. The conditional authorization below captures the safety requirement without forgoing the leverage.

2. **Authorize without runtime constraints** — add the surface, trusting the proposal-layer mutation operators alone to guarantee egress safety. **Rejected.** A mutation-operator bug would then be a **single point of failure** for egress, budget, and trust safety — exactly the dimensions that make the surface dangerous. The runtime gates (Layer 2) provide defense-in-depth: a proposal-layer defect is caught at the executor before any egress occurs.

3. **Authorize but defer the runtime-gate argument** — land the surface now, prove safety later. **Rejected.** The surface is **only safe *because*** the runtime gates own permission. The precondition is the two-layer enforcement model, not a future TODO. Stating it as a precondition (not a deferral) is what makes the authorization honest: a reviewer can see the load-bearing property today, not be asked to trust it.

## Consequences

### Positive

- **Routing itself becomes a measured, reversible optimization surface**, consistent with the other four — completing the conductor's learned-routing thesis (the conductor learns *which route works*, not just *whether to route*).
- The optimization loop can now improve the dimension that matters most for cost/quality trade-offs (worker + topology selection), subject to the same hill-climbing discipline (measured improvement, zero regression, reversible).
- Consistent with ADR-008's surface model and ADR-005's SAL/PK split.

### Negative

- Recipe mutation adds a **proposer of cloud-egress-affecting configuration**. Unlike the other four surfaces, a kept mutation can change which lane/topology/worker a future turn prefers — increasing the blast radius of a misjudged promotion.
- Mitigated by the two-layer enforcement above (proposal-layer structural limits + runtime gates authoritative), the F-12 measured-improvement gate, and the versioned recipe store (rollback to a prior `.v<ver>` recipe).

### Risks

- **The load-bearing property depends on the M2 gate ordering.** The defense-in-depth argument rests on §5.6's invariant: the provider request is **constructed after** gates 5.2–5.5 pass (membrane-before-construction). A future M2-wiring regression that moved a gate **after** request construction would break the argument that a mutated recipe cannot bypass egress.
  - **Mitigation / cross-ADR dependency:** the membrane-before-construction ordering is **test-enforced** in the M2 wiring (a blocked prompt must produce zero provider calls). This amendment treats that test as a **standing precondition** — it must not be removed or weakened. This is recorded as a cross-ADR dependency: this amendment's safety argument is only valid while the M2 §5.6 invariant holds.
- **Topological regression in the proposal layer.** If the M3 mutation operator is implemented with a bug that allows a widening or cap-exceeding mutation to slip past Layer 1, Layer 2 still gates it — but the proposal layer should be treated as a defense, not a permission, and its unit tests (reject-widening, reject-cap-exceed, reject-forbidden-lane/topology) must be maintained.

## Status transition

On David's acceptance, this amendment's status becomes **Accepted (Amendment)**, the `MetaOptSurface::ConductorRecipe` variant may be added to `crates/fae-metaopt/src/types.rs` (removing the doc comment that gates it), and the M3 ConductorRecipe mutation operator may be implemented per the allowed-operator/constraint specification above. The ADR-008 README row and its "amendment needed" note are updated in the same change.

## References

- [ADR-008](008-autonomous-self-improvement.md) — the ADR being amended (four-surface table, hill-climbing loop)
- [ADR-005](005-self-modification-safety.md) — Self-modification safety model (SAL/PK layers; MetaOpt within SAL; runtime-gates-as-authority pattern)
- [ADR-011](011-headless-rust-core-runtime.md) — headless Rust core canonical (recipe surface + gates are Rust-side; no Swift bridge)
- `docs/architecture/conductor-m1-static-recipes-spec-2026-06-22.md` — `FaeConductorRecipe`, `OwnedRouteDecision`, `ConductorTopology` (Direct/Chain only, F-15)
- `docs/architecture/conductor-m2-reward-eval-shadow-routing-spec-2026-06-23.md` §5 — the per-role-call executor gate pipeline (mode-cap → PII-membrane → budget → approval → worker → record → telemetry); §5.6 "constructs the provider request after gates 5.2–5.5 pass" (the load-bearing invariant)
- `docs/plans/fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md` (M3 section) — F-5 (this amendment), the enforceable constraints, F-15 (topology asserts), F-16 (SOUL-drift metric)
- `crates/fae-metaopt/src/types.rs` — the `MetaOptSurface` enum (4 variants today; `ConductorRecipe` deliberately absent, gated on this amendment)
- `crates/fae-daemon/src/conductor/recipe.rs` — `PrivacyLane` (monotone widening), `ConductorTopology` (Direct/Chain only), `FaeConductorRecipe`
