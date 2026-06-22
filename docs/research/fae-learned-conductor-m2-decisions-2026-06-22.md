# M2 Decisions — pre G-M2-spec agenda

- **Status:** DRAFT agenda for the G-M2-spec review gate. These are *decisions*, not implementation details — each must be resolved (plan-reviewer; privacy-sensitive ones arguably oracle) before any M2 code is written.
- **Date:** 2026-06-22
- **Context:** M1 shipped static-direct (on-device only, byte-identical). Carried-forward review findings + the chain release-validation gaps land here before M2 opens.

---

## Owner directive (David, 2026-06-22) — cloud models are intended, not an exception

> "We can make use of cloud external models and will via Fae. Our coordinator will be local, but we will allow external models and we will use our PII model to protect users' data."

This sets the frame for everything below:

- **The conductor (coordinator) is local** — routing decisions, policy, telemetry, memory stay on-device. (Consistent with ADR-011 and M1.) Gemma-class local models are the secure default.
- **Cloud-backed external models are a first-class, sanctioned capability** — Codex / Claude / Gemini / Copilot / remote APIs are intended to be routable. We use them for their power until local models catch up. They are NOT a gap to close off or a "privacy bug to contain."
- **The PII model is the egress membrane** that makes cloud routing safe. It already exists: `native/macos/Fae/Sources/Fae/Core/SensitiveContentPolicy.swift` (`shouldBlockRemoteEgress(text)`, keyed off `likelyCredential` and up). M2's job is to route cloud-backed work *through* it, not to prohibit cloud.
- **The F-7 tiering (budget + approval) layers ON TOP OF the PII membrane** — it governs cost + consent + autonomy, not "is egress allowed at all." Egress is governed by PII; tiering governs whether a given route needs a standing grant or per-turn approval.

### The trust gradient (the organizing principle)

The existing `WorkerLocality` / `PrivacyLane` enums *already encode* the trust gradient — more external ⇒ less trusted ⇒ stronger approval + tighter budget, with the PII membrane as the constant egress gate underneath. The gradient (most→least trusted):

| Locality | Lane (target) | Tier | Examples | Egress gate |
|---|---|---|---|---|
| `LocalModel` | `LocalOnly` | **A** (`None`) | Gemma (mistral.rs / llama.cpp) | none — zero egress |
| `LocalAcp` | ~~`LocalOnly`~~ → **`CloudBacked`** (D-M2-1) | **B** (`StandingGrant`) | Codex / Claude / Gemini / Copilot | PII membrane + budget |
| `OwnerFleet` | `OwnerFleet` | **B/C** | x0x same-owner nodes running external models (**Symphony**) | PII + budget + peer trust |
| `TrustedPeer` | `TrustedPeer` | **C** (`PerTurn`) | ADR-gated external peers | PII + per-turn approval |
| `RemoteProvider` | `RemoteAllowed` | **C** (`PerTurn`) | arbitrary remote API | PII + per-turn approval |

The single defect in M1 is the **`LocalAcp → LocalOnly`** mis-mapping (highlighted). Every other rung is already correctly encoded. Fixing that one mapping + wiring the PII membrane as the egress authority makes the conductor a correct implementation of the directive: *local coordinator, PII-protected, cloud-capable, trust-scaled.* We start on-device (Tier A) and reach outward for power — never abandoning the egress membrane, scaling approval with distance from the device.

This is the long-running F-2 egress-membrane work-package (`PrivacyFilterBridge` / `ConductorEgressMembrane`) landing in Rust.

---

## D-M2-1 — Cloud-backed model routing through the PII membrane (BLOCKER for M2)

**The false premise I corrected in code (commit pending):** the M1 F-7 doc claimed *"Tier A — Autonomous (`None`): local models + local ACP agents; zero egress"* and `locality_to_lane(LocalAcp) → PrivacyLane::LocalOnly`. That was wrong: ACP agents (Codex/Claude/Pi/Gemini/Copilot) are cloud-backed — the prompt egresses to OpenAI/Anthropic/Google. **Per the owner directive above, that is *fine and intended* — the protection is the PII model, not prohibition.** "Local process ≠ local data," but local-data-protection is the PII membrane's job, which makes cloud routing safe.

**Decision to make in G-M2-spec (before D2 budget-governance / D7 eval land):**

1. **PII membrane as the egress gate.** Every cloud-bound prompt (ACP, remote API, x0x peer) MUST pass through `SensitiveContentPolicy` (port to Rust, or call the Swift impl via the control plane). `shouldBlockRemoteEgress` blocks at `likelyCredential` and up. This is the F-2 egress membrane landing point. Decide: Rust-native port vs. bridge — same shape as the MetaOpt port question (D-M3).
2. **`WorkerLocality::LocalAcp` lane mapping.** Not `LocalOnly`. Options: a new `PrivacyLane::CloudBacked` (clear, recommended) vs. fold into `RemoteAllowed`. Decide in G-M2-spec. Either way, the PII membrane — not the lane label — is the actual egress authority; the lane drives budget-tier routing.
3. **Tiering on top of PII.** Cloud-backed ACP requires **Tier B or Tier C** (`ApprovalClass::StandingGrant` / `PerTurn`), never Tier A. Tier B needs the D2 budget cap to be meaningful (a standing grant is meaningless without a spend ceiling). The PII membrane runs *before* the tier check, so a blocked-by-PII route never reaches the approval surface at all.
4. **Per-provider granularity.** Does each provider (OpenAI / Anthropic / Google / x0x peer) get its own grant + budget bucket, or one "cloud-backed" class? OpenAI vs Anthropic have different data-retention policies; this may warrant per-provider lanes. Decide in G-M2-spec.
5. **`WorkerLocality::LocalAcp` rename.** The name caused the confusion. Candidates: `CloudBackedAcp`, `HostedAcpAgent`. Schema migration is cheap now (nothing persists recipes yet in M1); gets expensive later. Decide in G-M2-spec.
6. **genuinely-local ACP** (if it ever exists — e.g. a local-LLM ACP runner) stays `LocalModel`-equivalent. The discriminator is *data egress*, not process locality.

**Why this is a privacy-model decision:** getting the tiering + PII-membrane integration right on paper *before* D2/D7 land means the budget/approval/eval WPs build against the correct model. Building Tier B approval as if it owns egress gating (when the PII membrane does) would duplicate authority and create a bypass.

**Review surface:** `plan-reviewer` (mandatory) + `oracle` (recommended — inherited privacy state).

---

## D-M2-2 — Chain release-validation blockers (MUST fix before `FAE_CONDUCTOR_CHAIN` flips on)

Chain topology is implemented but **triple-gated dormant** in M1 (`FAE_CONDUCTOR_CHAIN` env flag + a vetted chain recipe must be loaded + `chain_enabled`). Before the flag is ever enabled for real users, four issues must be resolved (tracked in `docs/checklists/app-release-validation.md`):

1. **No `assistant.generating` event pair.** `run_chain` calls `run_turn` directly, not `inject_text_core` — the orb host's generating indicator is never published. Enabling chain changes user-visible event behavior. *(Fix: route chain role-calls through the generating-event publish + NaN-retry, or extract a shared turn-runner.)*
2. **No NaN-logits retry.** Same root cause — the retry loop lives in `inject_text_core`.
3. **Verifier FAIL-branch leaks the verdict.** `executor.rs` surfaces the full verifier body (`FAIL\n<reason>\n<corrected answer>`) rather than the stripped corrected answer.
4. **Hardcoded `max_tokens: 1024`** per chain role-call — should be recipe/budget-governed.

Plus: once chain can target cloud-backed workers (D-M2-1), **every chain role-call that egresses must pass the PII membrane** — not just the outer prompt. A Thinker→Worker→Verifier chain to a cloud model egresses three times.

These are NOT M2 blockers (chain stays off) but ARE release-validation blockers. M2's shadow-routing is the natural place to fix #1–#4 + the per-role PII check.

---

## D-M2-3 — Corrupt-key persistence (DONE in this cleanup; recorded for context)

`InstallKey::load_or_create` now **regenerates AND re-persists** a corrupt/truncated key (was: regenerate-only → different key every restart → repeatedly-discontinuous telemetry). M2's reward aggregator reads this telemetry; silently-discontinuous fingerprints would have corrupted the eval signal. Test `corrupt_key_is_regenerated_and_repersisted` proves stability across loads.

---

## M2 sequencing (per advisor)

D2 (budget-governance) and D7 (eval-corpus) are **hard prerequisites** for M2's reward aggregator + Tier B approval. Do NOT start M2 implementation unilaterally. Independently doable now:
- ✅ D-M2-3 (corrupt-key fix) — landed.
- ⏳ D-M2-1 (cloud routing through PII membrane) — resolve in G-M2-spec; the Rust-side PII membrane port/bridge decision is the first concrete ask.
