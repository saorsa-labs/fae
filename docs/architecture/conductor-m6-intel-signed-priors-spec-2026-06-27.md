# Fae Conductor — M6-Intel: Shared Intelligence as Signed Candidate Priors (Local/Dormant v1)

> Status: **Spec (2026-06-27)** · Owner: David Irvine · Layer: headless Rust core
> Predecessors: M2-live (`7e63d567`), M3 (`7df3552c`), M4 (`32029825`), M5 (`68c12caf`)
> Authority: ADR-012 (trust gradient), ADR-011 (headless Rust core), [`conductor-m4-ownerfleet-x0x-sync-spec-2026-06-27.md`](./conductor-m4-ownerfleet-x0x-sync-spec-2026-06-27.md) (the port/boundary/dormancy pattern this mirrors)
> Scoping: oracle-reviewed across two rounds (`55fb2573` scope, `9a130e14` reconcile) — see §2.3.

## 1. Goal

Ship the **M6-Intel** sub-system of the M6 milestone: a local, dormant, **export-only + import-rejects-all** surface for *shared intelligence* — learned routing telemetry exported as a signed, scoped, TTL'd candidate prior, and an import gate that reuses the Phase-0-reviewed `fae-envelope-gate` primitive but fails closed on every signature until real ML-DSA-65 verification exists.

**What this is NOT:** not the async own-fleet sub-system (that is M6-Async, a separate later slice), not network transport, not live routing influence, not cross-owner/group sharing, not raw memory sharing. All of those remain ADR-gated or deferred.

### The invariant (the one sentence this milestone exists to enforce)

> Untrusted/shared signals may enter the conductor **only** as a signed, schema-versioned, closed-`kind`, scoped, TTL'd, audited candidate prior — never as raw memory, never as live routing authority, and (for v1) never actually *accepted* at all, because the production verifier rejects every signature.

### Why ship something that rejects everything?

The same reason M4 shipped `UnavailableMeshDelegationPort`: a dormant plumbing layer with **proven, structurally-enforced guards** has value. M6-Intel establishes the ingress *shape* (envelope kind, payload allowlist, TTL, audit, isolated sink) and the *boundary* (x0x-symphony-core forbidden in the daemon core) **before** any real crypto or transport exists. The day ML-DSA-65 verification and same-owner transport arrive, they inherit a reviewed gate — they do not invent one under pressure.

## 2. Decisions

### 2.1 Scope split (oracle `55fb2573`)

M6 is two sub-systems. This spec covers **only M6-Intel**:
- **M6-Intel (THIS SPEC):** shared-intelligence local surface — export sanitizer + dormant import gate. Ship first.
- **M6-Async (LATER):** async own-fleet orchestration (x0x-symphony `Tracker`/`Runner`). Deferred until M6-Intel's trust boundary is proven; touches scheduler/workspaces/tools and risks becoming load-bearing before the gate is real.

### 2.2 Reuse-vs-rebuild: **Hybrid (Option C)** (oracle `9a130e14`)

`fae-envelope-gate` (a crate `fae-daemon` *already* depends on, red-team/oracle-reviewed in Phase 0) **is** the signed-ingress primitive this milestone needs. Rebuilding would create a *second* signed-ingress path and bypass the reviewed audit gate. But the gate is shaped for the G5 cross-Fae protocol (`DirectMessage`, `ConsentReceipt`, `MemoryShareOffer`, …), not conductor priors.

**Resolution:** reuse the gate *primitive* (`gate_and_audit`, `SignatureVerifier` trait, `PeerEnvelope`, audit-on-both-paths), and layer M6's own closed `kind` + payload allowlist + TTL + scope on top. Do **not** overload `MemoryShareOffer` (the dangerous raw-memory tier) — add a dedicated `ConductorGateReceiptPrior` kind.

### 2.3 Signing posture: **export-only + import-rejects-all**

Cross-node import requires real asymmetric verification: **ML-DSA-65** (the project's identity algorithm; `PeerId` = SHA-256 of the ML-DSA-65 pubkey). It does **not** exist in `fae-daemon` today (`InstallKey` is a `[u8; 32]` symmetric HMAC secret used only for `mesh_request_id` fingerprinting — sharing it would leak a per-install correlation key).

- **v1 import:** the daemon owns `UnavailableM6PriorVerifier: SignatureVerifier` whose `verify()` returns `false`. `gate_and_audit` is called (so the attempt is *audited*), the signature is rejected, and **nothing is stored**. This is the honest dormant form.
- **v1 export:** sanitize conductor telemetry (`RouteReceipt`) into an envelope-shaped artifact and write it to a local file. The export is an **unsigned preview / local diagnostic** — its `signature` carries `algorithm: "ml-dsa-65"` with a `signature_b64` of `"export-preview-unsigned"` and a clear `public_key_id: "<none>"`. It is explicitly **not importable** by the v1 import path (it will be rejected + audited). This lets a human inspect "what *would* be shared" without any cross-node trust claim.
- **Lowest-weight unsigned acceptance is forbidden.** The oracle was explicit: "lowest weight is still influence." Accepting an unsigned prior would violate the §1 invariant. There is no "unverified but low-weight" tier.

### 2.4 Economics (unchanged from prior milestones)

Deferred per owner directive (2026-06-26): no pricing, no cost caps. The prior payload may *carry* a latency bucket (governance signal), but carries **no cost** and the import gate enforces no budget. This is consistent with M4.

### 2.5 Boundary: **x0x / x0x-compute / x0x-symphony-core stay out of the daemon core**

The Phase-2 draft (`conductor-phase2-async-orchestration-2026-06-05.md`) proposed a `fae-conductor-orchestrator` crate depending on x0x + x0x-symphony. That **predates and conflicts** with the M4 boundary pattern. Treating `x0x-symphony-core` as "safe because types-only" is too loose: its types carry prompts, sessions, workspaces, and handoffs, and it is unstable (`v0.0.0`, no tags). M6-Intel needs **none** of it. The boundary guard is extended to forbid it structurally (§5).

## 3. The Tier-2 prior payload contract (F-item: the payload allowlist)

The research (`sakana-fugu-vs-fae-conductor-2026-06-22.md`) ranks shared-intelligence content by safety. v1 implements **only Tier 2 — eval outcomes / gate receipts**: aggregate, already-collected telemetry, no raw prompts. (Tier 1 learned-routing-heuristics and Tier 4 topology-hints are future; Tier 5 memory-seeds remains ADR-gated and dangerous.)

### 3.1 Source: `RouteReceipt` (telemetry.rs:123-152) — total projection

The export sanitizer reads a `RouteReceipt` and projects it onto a closed allowlist. **Every field of the source struct is accounted for** (total projection — no field is silently carried through). Verified against the actual struct definition (2026-06-27).

**Denylist (never exported):**

| Source field | Why excluded |
|---|---|
| `request_fingerprint` | F-4 per-install correlation token; would link turns across nodes |
| `worker_id` | stable identity; could fingerprint a fleet peer |
| `roles` | ordered role list; reveals internal topology execution detail |
| `fallback_reason` | free-form string; oracle-flagged leak vector |
| `payload_hash` | SHA-256 of outbound payload; oracle-flagged (correlable) |
| `cost_micros` | economics deferred (owner directive 2026-06-26) |
| `latency_ms` (raw) | raw ms is too fine-grained for cross-node correlation; **bucketed** instead (see allowlist) |
| `timestamp_ms` | absolute wall clock; not needed for a prior (the envelope carries `created_at_ms`); dropped to avoid cross-node clock correlation |
| `user_signal` | enum-like token per M2 invariant, but not Tier-2 material; deferred |
| any prompt text | never collected (F-4); the sanitizer cannot synthesize it |

**Allowlist (exported, all aggregate/closed-enum/bounded):**

| Payload field | Sourced from | Type / bound | Note |
|---|---|---|---|
| `topology` | `receipt.topology` | `ConductorTopology` (closed enum) | Direct, Chain |
| `privacy_lane` | `receipt.privacy_lane` | `PrivacyLane` (closed enum) | the lane that ran |
| `target_kind` | `receipt.target_kind` | `TargetKind` (closed enum) | model/runner class |
| `recipe_id` | `receipt.recipe_id` | `String`, **bounded ≤ 64 chars, token-validated** (`^[a-zA-Z0-9_.:-]+$`) | recipe/model version; bounded so it cannot carry free text (fix #5) |
| `success` | `receipt.success` | `bool` | did the turn succeed |
| `fallback` | `receipt.fallback` | `bool` | did it fall back to direct-local (field renamed to match source — no `fallback_used`) |
| `eval_delta` | `receipt.eval_delta` | `Option<String>`, **bounded ≤ 32 chars, token-validated** (`^[a-z_]+:[+-]?[0-9.]+$`, e.g. `routing_acc:+0.08`) | aggregate score only; bounded so it cannot carry query content (fix #5) |
| `latency_bucket_ms` | `receipt.latency_ms` | `LatencyBucket` (closed enum: `Under100`, `Under1000`, `Over1000`, `Unknown`) | **bucketed**, never raw ms |

**Latency bucket function** (deterministic, total over `Option<u64>`):
- `None` → `Unknown`
- `ms < 100` → `Under100`
- `100 ≤ ms < 1000` → `Under1000`
- `ms ≥ 1000` → `Over1000`

> Note: `RouteReceipt` has **no `task_class` field** (that lives on `ConductorRouteEvent`, the per-event sibling). The v1 prior sources only from the receipt; a future Tier that wants `task_class` would join event+receipt — out of scope here.

### 3.2 Envelope shape

The export emits a `PeerEnvelope`-shaped JSON (so the *same* gate code reads it on import), with:
- `schema_version: 1` (`SUPPORTED_SCHEMA_VERSION`)
- `kind: "conductor_gate_receipt_prior"` (the new closed kind)
- `envelope_id`: fresh per export (`"prior:<uuid>"`)
- `sender_id`: `"<self>"` (v1; a real peer id comes with real identity)
- `created_at_ms`: wall clock
- `payload`: the §3.1 allowlist object, `#[serde(deny_unknown_fields)]`
- `signature`: `{ algorithm: "ml-dsa-65", public_key_id: "<none>", signature_b64: "export-preview-unsigned" }` (the v1 unsigned-preview marker)

## 4. F-2 (egress membrane) interaction

M6-Intel does **not** add a new egress surface. The export is a **local file write** to the conductor store dir (alongside the existing JSONL telemetry) — never the network. The authority is the **sanitizer**, not the egress membrane: the sanitizer *cannot* emit a denylisted field because the projection is structural (it reads only the allowlist fields from `RouteReceipt`, and bounds + token-validates the exported `String` fields so they cannot carry free text — §3.1). The F-2 invariant (no credential/prompt egress) is preserved because (a) the source `RouteReceipt` already contains no prompt text (F-4), (b) the sanitizer drops every correlable identifier, and (c) the output is a local aggregate artifact, not a remote-bound prompt. The `ConductorEgressMembrane` (M4/F-2) governs *prompt-shaped* outbound text to a *remote* lane; it is not the authority for a local redacted-aggregate file write.

## 5. F-13 boundary guard extension (the gate-first slice)

`scripts/ci/guard-mesh-boundary.sh` (M4-C) forbids `x0x`/`x0x-compute` deps + imports in the conductor core. M6 extends it to also forbid **`x0x-symphony-core`** / `x0x_symphony`:

- **Cargo check:** `x0x`, `x0x-compute`, `x0x_compute`, `x0x-symphony`, `x0x_symphony`, `x0x-symphony-core`, `x0x_symphony_core` in any fae `Cargo.toml` (workspace root + members).
- **Import check:** `use x0x_symphony`, `x0x_symphony::`, `x0x-symphony::`, `x0x_symphony_core::`, `x0x-symphony-core::` in `crates/fae-daemon/src/conductor/**`.

Prose comments mentioning x0x-symphony as architecture context remain ALLOWED (matching the M4 precedent). The guard is renamed conceptually to cover the "conductor ↔ external-mesh" boundary (x0x family), but the filename `guard-mesh-boundary.sh` is kept for git-history continuity; its docstring is updated.

This lands **first** (M6-A), before any payload code — the gate-first principle from M4.

## 6. Design

### 6.1 New module: `crates/fae-daemon/src/conductor/intel.rs`

```
intel.rs
├── GateReceiptPriorPayload   // §3.1 allowlist; #[serde(deny_unknown_fields)]
├── sanitize_receipt(RouteReceipt) -> GateReceiptPriorPayload
├── export_preview(store, out_path) -> write unsigned envelope JSON
├── UnavailableM6PriorVerifier  // impl SignatureVerifier; verify()->false
├── import_prior(raw, verifier, store) -> Result<AcceptedEnvelope, GateError>
└── tests
```

### 6.2 `fae-envelope-gate` narrow extension (dependency-correct)

`PeerEnvelope`/`SignatureProof` fields are private; `AcceptedEnvelope` exposes only `envelope_id`/`sender_id`/`kind`/`peer_text_for_policy_review`. M6 needs (a) the envelope timestamp for TTL and (b) read-only access to the carrier payload. Add **exactly two accessors** to `AcceptedEnvelope` (no other field exposure):

- `pub fn created_at_ms(&self) -> u64` — for the TTL gate.
- `pub fn prior_payload(&self) -> Option<&serde_json::Value>` — returns the inner `payload` **as a read-only `serde_json::Value` reference**, regardless of kind. The conductor (`fae-daemon::conductor::intel`) owns deserialization into its own `GateReceiptPriorPayload` with `deny_unknown_fields` + a size cap on its side.

**Dependency direction is preserved:** `fae-envelope-gate` stays schema-agnostic and must **not** depend on `fae-daemon` (it does not today). The gate remains a dumb, schema-versioned, signature-checked carrier; the conductor owns interpretation. This mirrors how M4 kept DTOs in the conductor and the port dumb. (The earlier draft of this spec sketched a typed `prior_payload() -> Option<GateReceiptPriorPayload>` accessor — that is **invalid**: it would reverse the dependency and is removed.)

### 6.3 New `EnvelopeKind` variant

Add `ConductorGateReceiptPrior` to `EnvelopeKind` in `fae-envelope-gate`. This is a backwards-compatible enum extension (existing `deny_unknown_fields` on `PeerEnvelope` is unaffected; old nodes that don't know the kind reject it as `InvalidJson` — exactly the desired fail-closed behavior for a forward-rolling fleet).

### 6.4 The TTL gate (future-first, saturating)

v1 enforces a **7-day hard max** (`MAX_PRIOR_TTL_MS = 7 * 86_400_000`) and a clock-skew tolerance (`CLOCK_SKEW_MS = 60_000`). The payload carries no `expires_at` of its own; TTL is computed from the envelope's `created_at_ms` (part of the signed envelope, so not forgeable once signatures are real). **Check order is fixed to avoid `u64` underflow (fix #3):**

1. **Future-date check FIRST** (uses checked arithmetic): if `created_at_ms > now.saturating_add(CLOCK_SKEW_MS)` → reject `PriorRejected::FutureDated`. (No subtraction occurs, so no underflow.)
2. **Age check SECOND** (subtraction is now provably safe): `age = now.checked_sub(created_at_ms)`; if `age > Some(MAX_PRIOR_TTL_MS)` → reject `PriorRejected::Expired`.

No quorum: a single valid prior may be stored; multiple signatures raise confidence later but are never *required*. (Fix #6: removed the stray "(future)" — future-dated priors are rejected, not stored.)

**Post-gate prior-policy audit (fix #3).** `gate_and_audit` audits only envelope schema/signature (it is schema-agnostic). TTL/future-date/wrong-kind/unknown-payload-field rejections happen **after** gate acceptance, in the conductor's `import_prior`. These rejections append their **own** prior-policy audit row (`conductor_prior_policy.jsonl`: `event_type: prior_policy`, `envelope_id`, `sender_id`, `decision: Rejected`, `reason: expired`/`future_dated`/`wrong_kind`/`unknown_payload_field`). So §10's "reject + audit" holds for *both* the gate (envelope-level) and the policy (prior-level) layers.

### 6.5 The sink: `ConductorStore` (not `fae.db`)

Accepted (test-verifier-only in v1) priors append to a new JSONL file `conductor_priors.jsonl` via a new `ConductorStore::append_prior()`. **Never** `fae.db` / `MemoryOrchestrator`. The store's existing isolation discipline (telemetry-only, separate dir) is inherited unchanged. No router read path exists in v1 — the priors are written but never read by routing (that is M6-Async or later, and an explicit owner decision).

## 7. Slices

| Slice | Content | Gate-first? |
|---|---|---|
| **M6-A** | This spec + boundary-guard extension (§5) + the `ConductorGateReceiptPrior` kind in `fae-envelope-gate` + `created_at_ms`/`prior_payload` accessors. **No fae-daemon logic yet.** | ✅ invariant before code |
| **M6-B** | `intel.rs`: `GateReceiptPriorPayload` (allowlist, `deny_unknown_fields`) + `sanitize_receipt()` + export-preview writer. Unit tests: denylist fields absent, allowlist correct, latency bucketed, exported `String` fields bounded/token-validated. | |
| **M6-C** | `UnavailableM6PriorVerifier` + `import_prior()` calling `gate_and_audit` + TTL/scope checks + audit. Tests: unsigned-preview rejected+audited, expired rejected, future-dated rejected, unknown-field rejected, oversized rejected pre-parse, valid-shape-but-rejected-by-verifier audited. **Nothing stored in production.** | |
| **M6-D** | `ConductorStore::append_prior` + `conductor_priors.jsonl` + accepted-prior sink **only behind test-verifier**. Integration test: full export→import round-trip with `AcceptAll` stores exactly one prior; production `UnavailableM6PriorVerifier` stores zero + audits one rejection. | |
| **M6-F** | Observability/no-leak proof: sentinel in a source receipt's allowlisted-but-innocuous field (e.g. recipe_id) is absent from the exported envelope; `fae.db` never created; no route change. (Naming mirrors M4-F.) | |

M6-E (real ML-DSA-65 verifier + real same-owner transport) is a **future milestone**, not an M6-Intel slice — blocked on identity plumbing that doesn't exist yet.

## 8. Scope boundaries (explicitly deferred / ADR-gated)

- ❌ Real ML-DSA-65 signature verification (M6-E; needs identity plumbing).
- ❌ Network transport of priors (needs x0x transport; dormant like M4).
- ❌ Live routing influence from imported priors (owner-gated; "lowest weight is still influence").
- ❌ Async own-fleet orchestration (M6-Async, separate slice).
- ❌ Cross-owner / group sharing, MLS, TrustedPeer lane (ADR-gated).
- ❌ Tier 1 (routing heuristics), Tier 4 (topology hints), Tier 5 (memory seeds) priors.
- ❌ Raw memory egress, ever.
- ❌ `x0x-symphony-core` as a daemon dependency.

## 9. Test plan

**M6-B (export sanitizer):**
- `sanitize_receipt_drops_request_fingerprint` — F-4 token absent.
- `sanitize_receipt_drops_worker_id_and_fallback_reason` — identity + free-text absent.
- `sanitize_receipt_buckets_latency` — raw ms → bucket enum.
- `sanitize_receipt_drops_cost` — economics deferred.
- `export_preview_writes_unsigned_envelope` — kind/sender/signature marker correct.

**M6-C (import gate):**
- `import_rejects_unsigned_preview_and_audits` — the v1 export's own artifact is rejected by the production verifier + an audit row is written.
- `import_rejects_expired_prior` — `created_at_ms` older than 7d.
- `import_rejects_future_dated_prior` — clock-skew guard.
- `import_rejects_unknown_payload_field` — `deny_unknown_fields` on the payload.
- `import_rejects_oversized_before_parse` — 64KiB cap, serde never allocates.
- `import_rejects_wrong_kind` — not `ConductorGateReceiptPrior`.

**M6-D (sink):**
- `round_trip_with_test_verifier_stores_one_prior` — `AcceptAll` → `conductor_priors.jsonl` has 1 row, schema correct.
- `production_verifier_stores_zero_and_audits_rejection` — `UnavailableM6PriorVerifier` → 0 rows, 1 audit rejection.

**M6-F (no-leak):**
- `denylisted_fields_absent_from_export` — synthesize a `RouteReceipt` with sentinels in `fallback_reason`, `worker_id`, `payload_hash`, `request_fingerprint` (and `roles`, `user_signal`, `timestamp_ms`, `cost_micros`); assert **none** appear in the exported envelope JSON. (Fix #4: denylisted fields, not allowlisted `recipe_id`.)
- `allowlisted_strings_are_bounded` — a `recipe_id`/`eval_delta` exceeding the length bound or failing the token regex is rejected by the sanitizer (the export errors rather than emitting over-long/non-token content).
- `no_fae_db_created` — conductor store dir has no `fae.db`.
- `no_router_read_path` — routing decision unchanged by an imported prior (assert `StaticDirectPolicy::decide` output identical before/after a stored prior).

**Boundary guard (M6-A):**
- Mutation tests: adding `x0x-symphony-core` to a Cargo.toml → guard fails; adding `use x0x_symphony_core::` in conductor → guard fails; prose comment `// x0x-symphony is the async runner` → guard passes.

## 10. Acceptance

M6-Intel is done when:
1. The boundary guard forbids `x0x-symphony-core` (mutation-tested).
2. Export produces an unsigned-preview envelope with the §3.1 allowlist, **no denylisted field** (verified against the actual `RouteReceipt` field set), latency bucketed, and **all exported `String` fields bounded + token-validated** so they cannot carry free text (narrowed from "no prompt text" — fix #5: the sanitizer cannot prove arbitrary string content isn't a prompt, so it constrains the shape instead).
3. Import calls `gate_and_audit`, and the production `UnavailableM6PriorVerifier` rejects + audits **every** prior, storing nothing.
4. Behind a test verifier, a round-trip stores exactly one prior in `conductor_priors.jsonl` (isolated from `fae.db`).
5. TTL (7d max), future-date, unknown-field, oversized, wrong-kind all reject + audit.
6. No live routing path reads imported priors.
7. `cargo fmt`/clippy-strict/`cargo check --workspace --all-targets`/full test suite green; metaopt + mesh + release-validation guards green.

## 11. Risks

- **Export-only feels thin.** Acknowledged. The alternative (accepting unsigned priors) is worse — it violates the §1 invariant. The value is the proven gate + boundary, not a feature.
- **Future ML-DSA-65 work** needs canonical signing bytes + a trusted public-key registry. The `prior_payload()` accessor + `created_at_ms` are designed so a future verifier can read the signed envelope without re-plumbing the gate.
- **Exposing `prior_payload()` as `&Value`** must stay read-only and size-capped; the conductor deserializes with `deny_unknown_fields` on its side. A raw peer blob never reaches LLM/memory/tools (the gate's existing discipline holds).
- **`fae-envelope-gate` API extension** is a cross-crate change to a reviewed crate. Kept to two accessors + one enum variant; the crate's existing tests must stay green, and the `deny_unknown_fields` discipline is preserved.
- **"Covert live routing" risk:** if a future slice lets routing read priors, an accepted prior (even low-weight) becomes influence. v1 forbids the read path entirely; any future read path is an explicit owner decision with its own spec.
