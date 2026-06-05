# Fae Conductor — Capability Advertisement (`fae.capabilities/v1`)

> Status: **Design draft** (2026-06-05) · Owner: David Irvine · Layer: headless Rust core
> Shared sub-spec for [`conductor-tier1-own-fleet-2026-06-05.md`](./conductor-tier1-own-fleet-2026-06-05.md) §13.1
> and [`conductor-capability-grants-2026-06-05.md`](./conductor-capability-grants-2026-06-05.md) §13.1.
> Governance parent: `x0x-metadata-threat-model.md` (W4) — capability adverts are sensitive metadata.

## 1. Purpose

The conductor routes by capability ("this needs vision → find an agent with a VLM"). For that it must **know what each reachable agent can do**. This spec defines how an agent advertises its capabilities and how the conductor indexes them — for two audiences:

- **Own fleet** (Tier 1, same `UserId`): "my Mac has a dense 14B and a code runner; my phone has only E2B."
- **Granted peers** (Tier 2, cross-owner): "Alice granted me `RunRunner{claude_code}`; what exactly can it do?"

The hard constraint, from W4: **a capability advert is a "who-can-do-what" metadata leak.** Broadcasting "I have a code runner" on a public topic is precisely the correlation exposure the metadata threat model forbids. So advertisement defaults to **non-broadcast**, scoped to fleet or to an existing grant/group relationship.

## 2. What x0x already gives us (and what it doesn't)

**Source-verified (2026-06-05):** x0x ships a capability-advertisement system — `CapabilityAdvert` (`src/dm_capability.rs:51`) published to gossip topic **`x0x/caps/v1`**, signed, cached with a 900 s TTL (`dm_capability_service.rs`). **But its payload is transport-only:**

```rust
struct DmCapabilities {                 // src/dm.rs:55 — NOT extensible for app capabilities
    max_protocol_version: u16,
    gossip_inbox: bool,
    kem_algorithm: String,
    max_envelope_bytes: usize,
    kem_public_key: Vec<u8>,
}
```

Neither `CapabilityAdvert`, `IdentityAnnouncement` (`src/lib.rs:590`), nor `PresenceEvent` (`src/presence.rs:376`) has an extensible field for "I have a 14B / VLM / code runner." `DiscoveredAgent` carries identity/addresses/reachability — **no capabilities, no display name.**

**Conclusion:** Fae capability advertisement rides as a **separate app-protocol layer** that *mirrors* x0x's proven `CapabilityAdvert` design (signed descriptor, TTL cache) but is **not** published on the public `x0x/caps/v1` topic. We reuse the *pattern*, not the channel.

## 3. The descriptor

```rust
/// Signed statement of what an agent can do. App-level; never on x0x/caps/v1.
struct CapabilityDescriptor {
    v:            u8,                    // = 1
    agent_id:     AgentId,
    machine_id:   MachineId,
    user_id:      Option<UserId>,       // present for fleet trust shortcut (§5.1)
    capabilities: Vec<Capability>,
    issued_at_ms: u64,
    ttl_ms:       u32,                  // freshness; mirror x0x's 900s default
    signature:    Vec<u8>,             // ML-DSA-65 over canonical bytes (agent key)
}

struct Capability {
    kind:        CapabilityKind,        // closed taxonomy, §4
    id:          String,                // e.g. "qwen3-14b", "smolvlm2-500m", "claude_code"
    params:      CapabilityParams,      // context window, modality, cost hint
    available:   Availability,          // Ready | Busy | OnDemand(load_ms hint)
}

enum CapabilityKind {
    Reasoning,        // an LLM tier (params: effective_params, context, tool_calling)
    Vision,           // VLM (params: fast/deep, max_resolution)
    Asr,              // dedicated speech model
    Research,         // web-search + verify agent
    Runner(RunnerKind), // x0x-symphony runner (shell/codex/claude_code/custom)
    Tool(String),     // a specific named Fae tool
    Skill(String),    // a specific named skill
}
```

The taxonomy is **deliberately aligned with `CapabilityScope`** in the grants doc (§4) so an advert ("I have a `claude_code` runner") maps 1:1 onto a grantable scope (`RunRunner{[claude_code]}`). One vocabulary, two uses: advertise, then grant.

## 4. Distribution — non-broadcast, tier-scoped

| Audience | Channel | Why |
|----------|---------|-----|
| **Own fleet** (same `UserId`) | direct-message handshake on connect: requester sends `fae.capabilities/req`, peer replies `fae.capabilities/v1` descriptor. Cached per `AgentId`, TTL-bounded. | Small N (your machines), point-to-point, zero gossip noise, zero public leak. |
| **Granted peer** (1:1, Tier 2) | descriptor delivered **inline with / alongside the `CapabilityGrant`** over the existing grant direct-message channel. The grantor advertises *only the capabilities they granted*. | The advert is already inside a consented relationship; reveals nothing the grant didn't already authorise. |
| **"the Fae" group** (Tier 2, gated) | descriptor published into the **MLS-encrypted group state** (post-TreeKEM), or pulled on-demand member→member by direct message. | Encrypted to members only; satisfies W4 (no public discoverability of who-can-do-what). |

**Never** on a public gossip topic. If a topic is ever used for group adverts, it MUST be the W4 HMAC-derived group topic (`fae.<purpose>.<HMAC(group_secret, ctx)>`), never x0x's clear `x0x/caps/v1`. Default presence stays `off` (W4); capability advertisement does not change that.

### 4.1 Fleet enumeration
The conductor builds its fleet view from `find_agents_by_user(self.user_id) -> Vec<DiscoveredAgent>` (`src/lib.rs:6132`, confirmed), filters to `is_agent_machine_verified` (`src/lib.rs:5826`, confirmed) + online via `subscribe_presence` (`AgentOnline{agent_id, addresses, reachable}`), then handshakes each for its descriptor.

## 5. Consumption — the `CapabilityIndex`

The router holds a `CapabilityIndex`: `AgentId -> (CapabilityDescriptor, fetched_at, trust, grant_id?)`.

- **Freshness:** entries expire at `issued_at + ttl`; re-handshake lazily on routing miss or presence change. Stale entry → treat as unavailable, fall back (Tier-1 §8 ladder).
- **Presence-gated:** route only to agents currently `AgentOnline`. Offline-but-cached capability ≠ routable.
- **The router asks the index**, not the network, at routing time — routing stays a fast local judgment (Tier-1 §8). Index refresh is async/background.

### 5.1 Trust gating (capability claims are untrusted input)
A descriptor is a **claim**, not proof. Indexing rules:

1. **Fleet** (`user_id` matches self, `is_agent_machine_verified`): trusted shortcut — index directly. It's you.
2. **Cross-owner:** index a peer's descriptor only if (a) contact `TrustLevel` ≥ `Known` and `TrustDecision` ∈ {`Accept`, `AcceptWithFlag`} (`src/trust.rs:41`), **and** (b) a matching `CapabilityGrant` exists. A capability advertised without a backing grant is **ignored** — you can't route to it anyway.
3. **The claim is never trusted blindly:** advertised capability only *suggests* a route; **the grant is the authority**, re-verified at invocation by `GrantEnforcer` (grants doc §6.4). A lying advert ("I have a code runner") fails closed at invocation if no grant covers it — it cannot escalate.

This is the W3 posture: a peer's *self-description* is untrusted input that informs routing but never authorises action.

## 6. Lifecycle & staleness

- **Refresh:** lazy on miss + on `AgentOnline`/`AgentOffline` transitions; honour TTL.
- **Revocation coupling:** when a `CapabilityGrant` is revoked (epoch bump, grants doc §6.8), drop the associated index entries immediately — a revoked grant's advertised capabilities vanish from routing the same tick.
- **Offline:** presence `AgentOffline` → mark unroutable, keep cached descriptor for fast re-add on return.

## 7. Build surface (net-new)

1. `CapabilityDescriptor` + closed `CapabilityKind`/`CapabilityParams` types (taxonomy shared with grants `CapabilityScope`).
2. `fae.capabilities/req` + `fae.capabilities/v1` direct-message app protocol (mirror `DmAckWaiter` correlation, Tier-1 §6).
3. `CapabilityIndex` consulted by the router; lazy refresh; presence + TTL + trust/grant gating.
4. (Phase 2, gated) group-scoped advert in MLS state.

Everything rides existing transport (`send_direct`/`recv_direct`), discovery (`find_agents_by_user`), presence (`subscribe_presence`), and trust (`TrustEvaluator`). No x0x change required; no new gossip topic.

## 8. Acceptance criteria

- [ ] Fleet handshake: phone enumerates fleet via `find_agents_by_user(self)`, fetches each verified+online machine's descriptor, indexes it.
- [ ] Router routes by `CapabilityKind` against the `CapabilityIndex`, presence-gated, TTL-fresh.
- [ ] Cross-owner descriptor indexed **only** with `TrustLevel ≥ Known` **and** a backing grant; ungranted/over-claimed capabilities ignored.
- [ ] Advertised-but-ungranted capability cannot be invoked (fails closed at `GrantEnforcer`).
- [ ] No capability advert ever published on `x0x/caps/v1` or any clear public topic; group adverts (when enabled) use HMAC-derived topics or MLS state.
- [ ] Grant revocation drops associated index entries within one refresh tick.
- [ ] Works Apple + Linux (v1); Windows deferred (S11).

## 9. Open questions

1. **Descriptor size & batching** — a rich fleet machine may list many tools/skills. Cap the descriptor; advertise *coarse* kinds (Reasoning/Vision/Runner) eagerly, enumerate fine tools/skills on demand.
2. **Cost/latency hints for routing** — `CapabilityParams` could carry a tok/s + load-ms hint so the router prefers the cheaper adequate agent. Worth it once multiple agents offer the same kind.
3. **Push vs pull on change** — when a machine loads a new model mid-session, push an updated descriptor to fleet peers, or let TTL expiry handle it? Lean pull/TTL for simplicity; push only on grant changes.
4. **Unify with x0x upstream?** — worth proposing an *app-extensible* field to x0x's `CapabilityAdvert` so this rides x0x's cache machinery? Only if it can stay non-public; otherwise keep app-layer.

## 10. References
- `conductor-tier1-own-fleet-2026-06-05.md` §6 (DmAckWaiter pattern), §8 (routing), §13.1.
- `conductor-capability-grants-2026-06-05.md` §4 (`CapabilityScope` — shared taxonomy), §6.8 (revocation), §13.1.
- `x0x-metadata-threat-model.md` (W4) — presence off, topic HMAC, no public who-can-do-what.
- x0x source: `src/dm_capability.rs:51` (`CapabilityAdvert`, the mirrored pattern), `src/dm.rs:55` (`DmCapabilities`, transport-only), `src/lib.rs:6132` (`find_agents_by_user`), `:5826` (`is_agent_machine_verified`), `src/presence.rs:376` (`PresenceEvent`), `src/trust.rs:41` (`TrustDecision`).
