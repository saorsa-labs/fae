# ADR-014: Cloud / Multi-Model Lane (OpenRouter via the Conductor Egress Boundary)

- **Status:** Proposed
- **Date:** 2026-07-04
- **Decision owners:** David Irvine
- **Reviewers:** TBD
- **Supersedes:** none
- **Superseded by:** none
- **Related:** ADR-010 (llama.cpp sidecar), ADR-011 (headless Rust core runtime),
  ADR-012 (local-first coordinator of external AIs), ADR-013 (fluers agent-harness
  substrate), `docs/plans/cross-platform-completion-roadmap-2026-06-18.md` Phase D

## Context

Fae's secure default is a fully local model — prompts never leave the device. The
conductor already contains a complete, dormant cloud egress boundary: a PII membrane,
a pricing table, a `BudgetGovernor` daily cap, a request builder, and a
`CloudProvider::call` surface. A monotone privacy-lane lattice is defined
(`LocalOnly ⊂ CloudBacked ⊂ OwnerFleet ⊂ TrustedPeer ⊂ RemoteAllowed`) and a
`WorkerLocality::RemoteProvider` variant is present, explicitly marked
"ADR-gated." The V1 safe profile rejects `RemoteProvider`; the only
`CloudProvider` implementation is a mock; no cloud workers register.

Owners want optional access to stronger or cheaper external models (OpenRouter) for
hard turns, without surrendering the local-first guarantee. The conductor egress
boundary must be the one audited path through which any cloud-bound prompt exits the
device.

## Decision Drivers

- Preserve the local-first guarantee: no prompt leaves the device without explicit
  owner opt-in.
- Reuse the existing, already-audited conductor egress boundary rather than creating a
  second one.
- Keep the default (`LocalOnly`) safe for non-technical users who never configure cloud
  access.
- Budget-cap cloud spend fail-closed: a missing pricing entry or exhausted budget must
  fall back to the local model, loudly.
- API keys must not transit the NDJSON socket, `CloudRequest` bodies, conductor store
  entries, or log lines.

## Considered Options

1. **Accepted: unlock `RemoteAllowed` + `OpenRouterAdapter` in `fae-engine`, wired
   exclusively through the conductor egress boundary.** Minimal protocol churn; single
   audited gate; local default preserved. Described in full under Decision below.

2. **Rejected: session-level `GatedRemoteAdapter` in `fae-daemon`.** A new adapter
   wrapping the cloud call with its own copy of PII membrane + budget logic creates
   two security boundaries for the same surface. Any divergence silently degrades one
   of them. Rejected: one boundary is simpler and safer.

3. **Rejected: bespoke OpenRouter client inside `fae-daemon` (not the `fae-engine`
   adapter path).** The `ProviderAdapter` trait already gives the daemon a
   backend-agnostic inference surface; adding a parallel cloud path outside that trait
   duplicates request-building and SSE-parsing and makes the daemon's turn loop aware
   of which backend is remote. Rejected: the adapter path keeps routing transparent to
   the daemon.

## Decision

1. **Unlock the `RemoteAllowed` lane and the `RemoteProvider` worker locality**
   behind an explicit, off-by-default, owner-selected three-state privacy selector:
   `local` (default) / `fleet` / `all`. Only `all` permits `RemoteProvider`; neither
   state change is reachable without the owner's mode cap being satisfied.

2. **Implement OpenRouter as a single streaming `ProviderAdapter`
   (`OpenRouterAdapter`) in `fae-engine`**, using OpenRouter's OpenAI-compatible
   SSE `/chat/completions` endpoint. The adapter reuses the SSE-parsing helpers from
   the existing `LlamaServerAdapter` (same `events_from_chunk_with_pending_tools`
   path). A `ProviderBackedCloudProvider` replaces `MockCloudProvider` in the
   conductor's production wiring once the lane is enabled.

3. **All cloud-bound prompts leave the device ONLY through the existing conductor
   egress boundary.** The PII membrane, pricing table (fail-closed on missing entry),
   and `BudgetGovernor` (daily cap) are enforced before any bytes egress. Budget
   exhaustion, membrane block, or missing pricing entry → fail closed to the local
   model, surfaced loudly.

4. **The V1 safe profile continues to reject `RemoteProvider`.** A separate V2 profile
   permits it, and is reachable only when the owner's mode cap AND the recipe
   both permit. Existing deployments are unaffected; no configuration migration is
   required.

5. **API keys live in macOS Keychain (0600 file or env on Linux).** Keys reach the
   daemon only via startup environment, never transit the NDJSON socket, `CloudRequest`
   bodies, conductor store, or any log line. `OpenRouterAdapter` implements `Debug`
   manually, excluding the key field.

## Consequences

### Positive

- Owner-controlled access to stronger or cheaper models (GPT-4.1, Claude, Gemini) for
  hard turns — without changing the local-first default.
- Single audited egress boundary: the conductor's existing PII membrane + budget
  enforcement applies; no new security surface is introduced.
- Budget-capped fail-closed spend: no surprise bills; degraded but safe fallback.
- Minimal protocol churn: the daemon's turn loop sees an `OpenRouterAdapter` the same
  way it sees `LlamaServerAdapter` — opaque `ProviderAdapter`.
- SSE-parsing code reuse: `OpenRouterAdapter` shares the existing
  `events_from_chunk_with_pending_tools` / `finish_pending_tool_calls` helpers.

### Negative / Trade-offs

- **Model/lane changes require a daemon restart in v1.** The adapter is constructed at
  startup from the key in the environment; a live key rotation or model switch needs a
  restart. A hot-swap mechanism is a follow-up.
- **Sync-collect defers first audio until generation completes.** The two-pass audio
  path (S18) sends a WAV clip to the remote model, which must complete transcription
  before the reasoning pass can start. Streaming is faster but is a follow-up.
- **Opted-in prompts are exfiltration-risk-reduced (PII membrane) but not
  eliminated.** The membrane strips recognized credentials and PII categories; novel
  or structured data not matching membrane rules may still egress. Owner opt-in is the
  primary consent mechanism.

### Neutral / Operational

- The `OpenRouterAdapter` is committed unreferenced in `fae-engine`. No turn can reach
  it until the conductor wiring (V2 safe profile, `ProviderBackedCloudProvider`,
  three-state privacy selector) lands in a subsequent commit.
- Per-session cloud context management (conversation continuity across the remote
  model's stateless API) is deferred to the conductor wiring phase.
- OpenRouter's model versioning (model IDs may be aliased to updated snapshots) is
  accepted; pinning a specific checkpoint is a follow-up if benchmark regressions
  surface.

## Validation

- **Gate before conductor wiring:** `env -u RUSTFLAGS just check` (crates workspace) —
  fmt / clippy `-D warnings` / nextest — must be green with the adapter unreferenced.
- **Gate before `RemoteAllowed` unlock:** `OpenRouterAdapter` integration test against
  a live OpenRouter key in a sandboxed environment, verifying PII membrane strips a
  recognisable test secret, budget exhaustion falls back to local, and the Authorization
  header value never appears in any log or error.
- **V2 profile gate:** a turn routed through `RemoteProvider` with V1 profile must
  return a `policy_rejected` audit entry, not a cloud call.
- **Review trigger:** revisit if a future model adds audio-native support that bypasses
  the two-pass STT contract, or if OpenRouter changes its API in a way that breaks
  the OpenAI-compat SSE path.

## Notes for AI-assisted work

This ADR is **Proposed** — owner sign-off and a passing integration gate are required
before the conductor wiring commits. Until Accepted:

- Do NOT wire `OpenRouterAdapter` into the conductor, `session.rs`, or any turn path.
- Do NOT add `RemoteProvider` workers to the conductor's worker registry.
- Do NOT enable the V2 safe profile.
- The `OpenRouterAdapter` committed in the same branch is exported from `fae-engine`
  and is safe to test in isolation (unit tests + mock HTTP server); it is unreferenced
  in `fae-daemon`.

To supersede: write a new ADR; do not edit this one after it is Accepted.
