# ADR-012: Fae as Local-First Coordinator of External AIs ("Head Butler")

**Status:** Accepted
**Date:** 2026-06-24
**Owner:** David Irvine

## Decision

Fae is a **local-first coordinator** — a "head butler" — not an oracle that must
know everything itself. A small, personable, on-device model (Gemma-4 E4B via the
Rust daemon, ADR-011) owns the relationship: the conversation, memory, identity,
routing, and learning. For anything heavy or specialist, the butler **dispatches the
work to other AIs** and brings back the result. Fae is not the smartest agent in the
room; she is the one who runs the room.

**Fae holds the whole; collaborators see only parts.** The comprehensive, integrated
view — everything Fae knows about the user, woven across every model she has ever
consulted and across time, plus the durable memory — lives **only on-device, under
Fae's control**. Each external model receives only the task-scoped **slice** a given
subtask requires; none holds the durable memory, none sees the others' slices, and
**only Fae integrates**. Even a provider that accumulates many slices over time never
reconstructs the whole — it lacks the durable store, the entity graph, and the
cross-model/cross-session integration that only Fae performs. This compartmentalization
*is* the security/intelligence balance: best-in-class access to powerful external
intelligence **when needed**, without ever surrendering the comprehensive view, which
is the actually-sensitive asset.

The executors Fae coordinates form a **trust gradient** — more external ⇒ less
trusted ⇒ stronger gating, with the PII membrane as the constant egress floor:

| Executor | Lane (`PrivacyLane`) | Examples | Egress gate |
|---|---|---|---|
| On-device model | `LocalOnly` | Gemma-4 (mistral.rs / llama.cpp) | none — zero egress |
| Cloud-backed agent / API | `CloudBacked` | Codex, Claude, Gemini, Copilot, remote APIs | **PII membrane + budget** |
| Own fleet (x0x-symphony) | `OwnerFleet` | same-owner peers running heavier models | PII + budget + peer trust |
| Trusted peer | `TrustedPeer` | granted external peers | PII + per-turn approval |
| Remote provider | `RemoteAllowed` | arbitrary remote API | PII + per-turn approval |

### Three load-bearing principles

1. **The PII membrane is the security model.** Fae works *for her user's security*.
   Every cloud-bound prompt — ACP agent, cloud API, or mesh peer — passes through
   `fae-pii-membrane` (`should_block_remote_egress`) **before** it leaves the device;
   secret-shaped content is blocked or redacted. This is how external-AI use is made
   safe. It replaces voice identity (retired in S18; ADR-006 superseded) as Fae's
   security posture, alongside `DamageControlPolicy` (ADR-005) for catastrophic local
   operations.

   *Scope, stated honestly:* the membrane is a **credential/secret filter**, not a
   general-PII filter — it blocks keys, passwords, seed phrases, private keys, not
   ordinary personal content. What bounds the *non-secret* exposure is principle 3:
   any single egress carries only a task-scoped **slice**, never the integrated whole.
   The default *availability mode* and any change to it are governed accordingly (see
   `egress-scope-and-stage3-hold-2026-06-23.md`).

2. **Provisioning is capability and standing consent.** Users extend Fae's reach by
   **adding an API key or installing an agent** — and that provisioning *is* the
   standing grant for that provider/agent (owner ruling 2026-06-23). Fae then uses the
   capability **autonomously when she needs it**, bounded by the D2 budget caps
   (cost / wall-clock / per-day) and floored by the membrane. The user picks a model
   *availability mode* — pure-local / local + symphony / all-available — and within it
   Fae routes without a per-turn popup. There is no separate "approve this cloud call"
   ceremony for a provisioned, in-budget, PII-passing route.

3. **Compartmentalization — Fae is the sole integrator.** Two complementary mechanisms
   protect the user at different layers. The **membrane** filters *per call* (principle
   1: no secret-shaped content egresses on any single request). **Compartmentalization**
   protects *across calls*: the durable, integrated memory never leaves the device, and
   each external model receives only the minimal slice its subtask needs. No external
   party reconstructs Fae's whole — they lack the durable store, the entity graph, and
   the cross-model/cross-session integration only Fae performs.

   *Enforcement note (honest):* durable-memory locality is a **hard guarantee today** —
   the memory store (`fae.db`, entity graph) never egresses; only Fae reads it. Per-call
   **context minimization** — ensuring a delegated prompt carries only the task-scoped
   slice rather than full recalled context — is a **conductor egress responsibility and
   enforcement point**, partly emergent today and to be made explicit as the egress path
   matures. So "collaborators see only parts" is already true of the integrated *whole*;
   tightening each individual *slice* is named, ongoing work, not yet a coded guarantee
   like the membrane.

## Context

The original stance (ADR-003, Feb 2026) was **local-only**: "all intelligence runs on
the user's Mac… no API keys… no data leaves the device." Two things changed:

- **Agent harnesses are commoditising** (Codex, Claude Code, Hermes, Copilot). The
  durable, unsolved problem is **coordination** plus a personal, private, voice-first
  interface that grows with you — not being the single biggest brain. Fae owns that.
- **Cloud and external models are a first-class, sanctioned capability**, not a
  privacy hole to seal. The protection is the PII membrane, not prohibition — "local
  process ≠ local data," and local-data-protection is the membrane's job.

This decision records, as a top-level ADR, the "head butler" repositioning previously
captured only in design docs (`conductor-positioning-and-scope-2026-06-05.md` and the
conductor doc set), and reconciles it with what is now built (the conductor, M0–M2).

## Consequences

- **Supersedes the "local-only" framing of ADR-003.** Fae is **local-first**, not
  local-only: the on-device model is the default and the coordinator; cloud/external
  is opt-in-by-provisioning and PII-gated. ADR-003 is reframed accordingly.
- **Security rests on the PII membrane + `DamageControlPolicy` (ADR-005)** — not voice
  identity (ADR-006, superseded).
- **Implemented by the learned conductor** (`crates/fae-daemon/src/conductor/`): static
  routing (M1), egress gating = membrane + budget + provisioning + locality (M2), the
  reward/shadow signal (M2 §7/§8), and recipe mutation under a protected kernel
  (ADR-008a, M3). The `CloudBacked` lane is the ACP/cloud rung of the gradient.
- **The default availability mode flip to "all-available" for end users remains
  gated** on the release-validation contract and the membrane-scope acknowledgement
  above (Stage 3; `egress-scope-and-stage3-hold-2026-06-23.md`). Default ships
  local-first until then.
- **`OwnerFleet` / x0x-symphony and `TrustedPeer`** are the deferred (M4+) rungs;
  they integrate as further executors on the same gradient, under the same membrane.

## References

- ADR-003 (reframed: local-first, not local-only) · ADR-005 (self-modification safety /
  protected kernel) · ADR-008a (ConductorRecipe MetaOpt surface) · ADR-011 (headless
  Rust core runtime).
- `docs/architecture/conductor-positioning-and-scope-2026-06-05.md` (head-butler design)
- `docs/research/fae-learned-conductor-m2-decisions-2026-06-22.md` (trust gradient, D-M2-1)
- `docs/architecture/egress-scope-and-stage3-hold-2026-06-23.md` (membrane scope, Stage 3)
- `crates/fae-pii-membrane/` (the egress authority)
