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

1. **PII membrane as the egress gate.** Every cloud-bound prompt (ACP, remote API, x0x peer) MUST pass through the PII membrane (`SensitiveContentPolicy`'s `shouldBlockRemoteEgress`, blocking at `likelyCredential` and up). This is the F-2 egress membrane landing point. **Port-vs-bridge: RESOLVED in D-M2-4 below → PORT to Rust, no bridge.** The ingress counterpart (`fae-envelope-gate`, `peer_envelope_ingress`) is already Rust; the egress membrane is its missing mirror and must be Rust too.
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

## D-M2-4 — Port-vs-bridge principle (RESOLVED recommendation; ratify at G-M2-spec)

**Resolves:** D-M2-1 item 1 (PII membrane) **and** the D-M3 MetaOpt port-vs-bridge question — *once, together*, as the advisor flagged. Not a blanket "port everything": it's a principle that splits the two by what actually matters.

### The principle

Port a Swift capability to Rust **unconditionally** when **any** of:
- it is **egress- or ingress-critical** (privacy/security gate on the trust boundary);
- it is **per-turn hot-path** (runs on every routed turn — latency + availability couple to it);
- it **must outlive the Swift app** (the Swift app is being retired per ADR-011; a dependency on it is a dependency on a dying surface);
- it is **small enough** that bridging isn't worth the coupling.

Bridge a Swift capability **transiently** (then port, time-boxed) when **all** of:
- it is a **large existing subsystem** (porting is real work);
- it is **not egress/ingress-critical**;
- it is **cold-path** (scheduled / batched, not per-turn).

### Application — the asymmetry the advisor asked to resolve once

| Capability | Verdict | Why |
|---|---|---|
| **PII membrane** (`SensitiveContentPolicy`) | **PORT — no bridge, ever** | Egress-critical ✓ + per-turn hot-path ✓ (every cloud-bound turn) + must outlive Swift ✓ + small (106 lines, 12 regex rules, all portable to Rust `regex` — no lookbehind/backrefs) ✓. Plus two decisive structural points below. |
| **MetaOpt** (`Scheduler/MetaOpt*.swift`) | **bridge-now → port-later (lean); decide at G-M2-spec** | Large existing subsystem ✓, non-critical ✓, cold-path ✓ (scheduler-cycle, not per-turn). ADR-011 itself offers both ("ported (or bridged)"). Bridge unblocks M3; port retires it. Time-box the bridge with an explicit retirement date. |

### Why the membrane is PORT (not a close call once ADR-011 is read carefully)

1. **ADR-011's direction is intelligence *out of* Swift, into Rust.** Bridging the *most* security-critical, never-retiring decision *into* Swift is migrating the wrong way — the opposite of the ADR's whole point.
2. **The daemon must run headless.** ADR-011: "the headless Rust daemon is the brain." A Swift bridge means the daemon cannot make an egress decision without the Swift app process present — it breaks the moment the daemon runs standalone (the target state). Today the daemon is embedded in the Swift app, but building new egress logic as a bridge bakes in a dependency the ADR is migrating *away* from.
3. **Dependency direction.** The Swift app is a *client* of the daemon (control-plane client), not a server the daemon calls into. A daemon→Swift bridge for a security decision inverts that: the server would depend on a client. Architecturally wrong under ADR-002 v2 / ADR-011.
4. **Symmetry with the already-Rust ingress gate.** `fae-envelope-gate` (`peer_envelope_ingress`, signature-checked, audited, already a `fae-daemon` dep) is the **ingress** membrane — untrusted peer→Fae input is gated before use. The PII membrane is its **egress** mirror — Fae→cloud output is gated before egress. Having ingress validation in Rust and egress in Swift is an inconsistent split of one trust boundary; both belong in the canonical core.

### Concrete asks for G-M2-spec (ratify or override)

1. **Ratify PORT for the PII membrane** (expected non-controversial given the four points above).
2. **Home for the Rust membrane.** Lean: a small new crate `crates/fae-pii-membrane/` — egress counterpart to `fae-envelope-gate`, independently testable, reusable by `fae-acp` if a worker needs a pre-flight check. Alternative: a `fae-daemon/src/pii/` module (less ceremony, less reuse). Decide at the gate.
3. **Rule-source.** Port the 12 regex rules as Rust constants first (fastest); promote to a shared data file (TOML/JSON) later *only if* drift between the Swift legacy impl and the Rust canonical impl becomes a maintenance risk. Don't pre-build the shared-file abstraction — it's a YAML/regex config layer with no current second consumer.
4. **MetaOpt: bridge-now-port-later vs port-now.** Lean bridge-now-port-later (pragmatic, unblocks M3 on a cold path). Decide at G-M2-spec with a porting-effort estimate + an explicit bridge-retirement date (e.g. "bridge retired by M4").
5. **Membrane wiring point.** The conductor executor calls the membrane *before* constructing any cloud-bound `ChatRequest` (per-role-call for chain, not just the outer prompt — see D-M2-2). A `shouldBlockRemoteEgress` block returns `RouteFailure::PrivacyBlocked` (new variant?) → fail-closed-to-direct. Decide the exact failure shape at the gate.

### Why this is front-loaded (independent of D2/D7)

The port-vs-bridge *decision* needs nothing from the team's budget-governance (D2) or eval-corpus (D7) WPs — it's an ADR-011 + architecture question. The membrane *port itself* (the Rust code) is similarly independent: it's a privacy primitive, not routing logic, and M1's on-device-only conductor doesn't need it yet but M2's first cloud route does. So the decision + the port can both land before D2/D7, exactly like the corrupt-key fix did. (Implementation of the port stays gated behind G-M2-spec ratification — this doc is the *decision*, not authorization to write the crate yet.)

---

## M2 sequencing (per advisor)

D2 (budget-governance) and D7 (eval-corpus) are **hard prerequisites** for M2's reward aggregator + Tier B approval. Do NOT start M2 implementation unilaterally. Independently doable now:
- ✅ D-M2-3 (corrupt-key fix) — landed.
- ⏳ D-M2-1 (cloud routing through PII membrane) — resolve in G-M2-spec; the Rust-side PII membrane port/bridge decision is the first concrete ask.
