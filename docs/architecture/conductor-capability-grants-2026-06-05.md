# Fae Conductor — Tier 2: Cross-Owner Capability Grants

> Status: **Design draft** (2026-06-05) · Owner: David Irvine · Layer: headless Rust core + governance
> Scope: **Tier 2** — one human's Fae safely invoking *another human's* agents/tools/runners, and sharing
> capability across human-owned agent teams ("the Fae").
> Companion: [`conductor-tier1-own-fleet-2026-06-05.md`](./conductor-tier1-own-fleet-2026-06-05.md) (own-fleet, ships first).
> Governance parents: `fae-to-fae-governance.md` (G5), `directive-and-soul-migration.md` (W3),
> `x0x-metadata-threat-model.md` (W4), `memory-migration-plan.md` (G4).

## 1. Why this doc exists

Across the whole headless design, every peer concern is already settled **except one**:

| Concern | State |
|---------|-------|
| Peer **memory** disclosure | Designed — S12 + provenance/`data_class` + inbound write gate. |
| Group **crypto** | Gated — TreeKEM wiring (imminent). |
| Peer **metadata** | Designed — W4 threat model, presence default off, topic HMAC. |
| Prompt-injection isolation | Designed — W3 6-layer precedence, G5 closed-kind envelope. |
| Peer **tool / work authorization** | **TBD — "peer-tool design gate blocks features." No plan.** |

This document fills that gap. It is the **keystone of the agent-teams vision**: *"can Alice's Fae ask my agent to run a tool or claim a work issue — under what scoped, revocable, audited grant?"* It does not invent crypto or transport — x0x provides the primitives. It defines the **Fae-level grant model** that composes them and plugs into the governance already signed off (owner sign-off 2026-06-02).

## 2. The x0x primitives we compose (not reinvent)

| Primitive | x0x API | What it gives us |
|-----------|---------|------------------|
| Bearer capability | `Agent::create_invite(group_id, max_role: GroupRole) -> SignedInvite` | a signed, transferable token whose *possession* = a right; expiry + max_role + issuer tracking. |
| Roles | `GroupRole { Owner, Admin, Moderator, Member, Guest }`, `GroupPolicy { discoverability, admission, confidentiality, read_access, write_access }` | coarse role gating inside a group. |
| Command ACL | `ExecAcl` / `AllowEntry { (AgentId, MachineId), tokens }` | per-identity argv allowlist for attested execution. |
| Trust | `ContactStore`/`TrustLevel { Blocked, Unknown, Known, Trusted }`, `TrustEvaluator::evaluate -> TrustDecision { Accept, AcceptWithFlag, RejectMachineMismatch, RejectBlocked, Unknown }` | who is even allowed to be heard. |
| Identity | `MachineId` / `AgentId` / `UserId`, `is_agent_machine_verified`, `AgentCertificate` (user→agent binding) | provable cross-owner identity. |
| Secure exec | `ExecService::run_remote(target, ExecRunOptions)` | the *enforcement engine* for attested command grants. |
| Group crypto | saorsa-mls `TreeKemGroup` (pending wiring) | FS+PCS for multi-party "the Fae" groups. |

**Gap:** x0x's `SignedInvite` is a *group-join* bearer token. It is **not** a *scoped capability to invoke specific tools/runners on my agent*. `ExecAcl` is per-`(AgentId,MachineId)` argv allowlisting but has no notion of consent receipts, revocation epochs, data-class scoping, or Fae tool/skill/runner semantics. We need a Fae object that **binds a grantee identity to a bounded set of Fae capabilities, with consent, expiry, revocation, and audit** — then *projects* onto these primitives for enforcement.

> **Source-verified (2026-06-05).** `SignedInvite` (`src/groups/invite.rs:27`) is confirmed **pure bearer** — its `invite_secret` is a 32-byte random token, possession = right, no identity binding. The only revocation x0x offers is `ContactStore::revoke` (`src/contacts.rs:320` — permanent, agent-wide, one-way), group `GroupMemberState::Banned`, and MLS epoch rekey. **No per-action capability object and no per-capability revocation exist.** This confirms `CapabilityGrant`/`GrantEnforcer`/`GrantStore` must be built fresh (identity-bound, scoped, epoch-revocable) — they cannot be reduced to existing x0x types. `AgentCertificate` (`src/identity.rs:390`, signs `user_pubkey || agent_pubkey || ts` with the user key) gives the cryptographic UserId→AgentId binding the grant relies on for identity-bound (non-bearer) grantees.

## 3. The capability grant

### 3.1 Data structure

```rust
/// A grantor (human, via their Fae) authorising a grantee to invoke a bounded
/// set of capabilities on the grantor's fleet. Signed; revocable; audited.
struct CapabilityGrant {
    grant_id:        [u8; 16],
    v:               u8,                  // = 1

    grantor_user:    UserId,              // who owns the resources
    grantor_agent:   AgentId,             // the issuing Fae
    grantee:         Grantee,             // who may exercise it (see below)

    scope:           CapabilityScope,     // WHAT may be done (closed taxonomy, §4)
    constraints:     GrantConstraints,    // limits on HOW (§5)

    consent_id:      [u8; 16],            // links to the grantor's stored consent receipt
    issued_at_ms:    u64,
    not_after_ms:    u64,                 // hard expiry — no infinite grants
    epoch:           u32,                 // revocation generation (§6)

    signature:       Vec<u8>,            // ML-DSA-65 over canonical bytes of all above
}

enum Grantee {
    Agent(AgentId),                       // a specific remote Fae/agent
    User(UserId),                         // any agent provably owned by this human
    GroupRole { group_id: String, min_role: GroupRole }, // anyone at/above role in "the Fae" group
}
```

A grant is **capability-scoped, not role-scoped**: possession of a valid, unexpired, unrevoked grant whose `scope` covers the requested action — *and* whose `grantee` matches the verified caller identity — authorises it. Possession alone is insufficient (unlike a pure bearer token): the caller must *be* the bound grantee, proven by ML-DSA-65 identity + `is_agent_machine_verified`. This defeats grant theft.

### 3.2 Why not just use `SignedInvite`?

`SignedInvite` is bearer (possession = right) and group-coarse. A stolen invite grants access. Cross-owner tool invocation is far more dangerous than group join, so Tier 2 grants are **identity-bound** (not bearer) and **capability-fine** (not role-coarse). We *do* reuse `SignedInvite` for the lower-stakes act of *joining* a "the Fae" group; the grant governs what you may *do* once in.

## 4. Capability scope taxonomy (closed)

Scopes are a **closed enum** — unknown scope = denied (mirrors G5 closed-kind envelopes). Tiered by blast radius:

```rust
enum CapabilityScope {
    // Tier A — read/answer, lowest risk
    Ask { topics: Option<Vec<String>> },         // "answer questions", optionally topic-fenced
    ReadTool { tools: Vec<String> },             // named read-only tools (web_search, fetch_url, screenshot…)
    MemoryQuery { data_classes: Vec<DataClass> },// query memory, fenced to data-classes (§7)

    // Tier B — scoped action, medium risk
    RunSkill { skills: Vec<String> },            // named instruction/executable skills
    RunRunner { runners: Vec<RunnerKind> },      // x0x-symphony Runner kinds (shell/codex/claude_code/custom)
    WriteTool { tools: Vec<String>, paths: Vec<PathRule> }, // named write tools, path-fenced

    // Tier C — attested execution, highest risk
    Exec { allow: Vec<AllowEntry> },             // projects onto x0x ExecAcl; argv-allowlisted, attested
}
```

- **Never** a wildcard. No `scope: All`. No "grant everything."
- `WriteTool`/`Exec` always carry path/argv fences; they project onto `PathPolicy` + `ExecAcl`.
- `RunRunner` is how cross-owner **agent teams** happen: Alice grants me `RunRunner{ [claude_code] }` so my conductor can claim a symphony issue that her `claude_code` runner executes — *her* compute, *her* harness, *my* scoped request.
- DamageControlPolicy `block`/`disaster` operations are **never grantable** — a grant can only *narrow* the catastrophic-op floor, never widen it.

## 5. Constraints (how, not what)

```rust
struct GrantConstraints {
    max_calls:        Option<u32>,         // total invocations
    rate:             Option<RateLimit>,   // calls per window
    max_tokens:       Option<u32>,         // per Ask/Runner turn
    quiet_hours:      Option<TimeWindow>,  // honour grantor's quiet hours
    require_approval: ApprovalMode,        // Auto | PerCall | FirstThenAuto
    data_egress:      EgressPolicy,        // what may leave grantor's machine in results (§7)
    relay:            RelayMode,           // direct_preferred | relay_required (W4 MASQUE)
}

enum ApprovalMode { Auto, PerCall, FirstThenAuto }
```

`require_approval = PerCall` means every cross-owner invocation pops the grantor's approval overlay (the human stays in the loop). `FirstThenAuto` earns auto after one approval — mirrors `AdapterDeploymentManager`'s earned-autonomy pattern. Tier-C scopes **force** `PerCall` regardless of request.

## 6. Lifecycle

```
ISSUE → DISTRIBUTE → PRESENT → VERIFY → (APPROVE) → INVOKE → AUDIT → REVOKE/EXPIRE
```

1. **Issue.** Grantor's human consents ("let Alice's Fae use my research runner, read-only, for a week"). Fae builds a `CapabilityGrant`, stores a **consent receipt** (`consent_id`) and the grant in a local `GrantStore`, signs with the grantor agent's ML-DSA-65 key.
2. **Distribute.** Grant delivered to grantee over x0x direct message (`fae.grant/v1`), or — for `Grantee::GroupRole` — published into the "the Fae" group's MLS-encrypted state once TreeKEM lands.
3. **Present.** Grantee's conductor, when it wants to delegate cross-owner, attaches the `grant_id` (not the whole grant) to the `DelegationRequest` (extends Tier-1 envelope with `grant_id: Option<[u8;16]>`).
4. **Verify (grantor side).** On inbound cross-owner request, the **GrantEnforcer** (new) checks, in order, fail-closed:
   - G5 envelope valid (signature, closed kind, not expired/oversized).
   - Caller identity = grant's `grantee` (`is_agent_machine_verified`; `UserId`/`AgentId`/group-role match).
   - Grant exists in `GrantStore`, `epoch` current, `not_after_ms` not passed.
   - Requested action ⊆ `scope`.
   - `constraints` satisfied (rate/quota/quiet-hours/tokens).
   - DamageControlPolicy floor (catastrophic ops blocked regardless).
   - **Any failure → deny + audit. Unknown anything → deny.**
5. **Approve.** If `require_approval` demands it, the grantor's approval overlay fires; human decision recorded.
6. **Invoke.** Action runs through the **normal local stack** as if the grantor's own user requested it but with `actor = grantee`, locked to scope: ToolExecutor / SkillManager / `ExecService::run_remote` (for `Exec`) / symphony Runner (for `RunRunner`).
7. **Audit.** Every step → `SecurityEventLogger`: `grant_id`, `consent_id`, caller `(AgentId,MachineId,UserId)`, scope element exercised, approval decision, result **hash**, egress decision. No silent cross-owner action — ever (W3/W4 kill criterion).
8. **Revoke/Expire.** Revocation bumps the grantor's `epoch`; all grants at the old epoch are dead on next verify (immediate, no propagation race). Expiry is automatic at `not_after_ms`. Group grants additionally die on MLS rekey (ban/remove). Revocation writes an audit record; in-flight calls are cancelled.

## 7. Data egress — the memory membrane on results

A cross-owner invocation produces a **result** that flows back to the grantee. This is the dangerous direction (it leaves the grantor's machine), so it reuses the *outbound* half of the existing stack:

- Results pass `PrivacyFilterBridge` (PII) + `OutboundExfiltrationGuard` + DamageControlPolicy `nonLocal` (the exact CoWork external-call path).
- `EgressPolicy` on the grant fences which `data_class` may appear in results: default **`shareable_context` only**; `private_user` records **never** cross an owner boundary (memory-migration-plan kill criterion). `MemoryQuery` scope's `data_classes` is intersected with `EgressPolicy` — the stricter wins.
- On the **grantee** side, ingested results are written with `provenance = peer:<grantor_agent>`, `data_class = peer_claim`, `consent_id`, `source_envelope_id`, `review_status = unreviewed`. They are **quarantined**: per W3, peer-sourced memory **must not influence system/developer prompts without user review + data-class upgrade.** This is the same membrane already designed for peer memory — capability grants don't get to bypass it.

## 8. Enforcement points (where grants are checked)

```
Inbound cross-owner DelegationRequest (with grant_id)
   │
   ▼  [1] G5 envelope parser ......................... reject malformed/unknown-kind
   ▼  [2] TrustEvaluator ............................. blocked/unknown peer → drop
   ▼  [3] GrantEnforcer.verify(grant_id, caller, action) ... §6.4, fail-closed
   ▼  [4] ApprovalMode gate .......................... human in loop if required
   ▼  [5] DamageControlPolicy ........................ catastrophic floor (ungrantable)
   ▼  [6] dispatch to local stack (actor = grantee, scope-locked)
   ▼  [7] Outbound egress guard (PII/exfil/data_class) on the RESULT
   ▼  [8] SecurityEventLogger ........................ full audit
```

Steps 1, 2, 5, 7, 8 already exist (CoWork/governance stack). **Only [3] GrantEnforcer + the `GrantStore` are new.** That is the entire net-new surface for Tier 2 authorization — the rest is wiring existing guards in a new order with a new actor identity.

## 9. Relationship to "the Fae" groups

- 1:1 cross-owner grants (`Grantee::Agent`/`User`) work over **direct QUIC** and can ship as soon as Tier 1 + GrantEnforcer exist — they do **not** require TreeKEM (no group crypto involved; the channel is point-to-point, the grant is the authorization).
- **Group** grants (`Grantee::GroupRole`) — "everyone in my research team at Member+ may use this runner" — **require** TreeKEM-wired MLS groups (FS+PCS) so grant distribution and revocation ride encrypted group state. These stay **hard-gated** on TreeKEM + G5 production enforcement, consistent with `cross-platform-engine-plan` §11A.
- This means cross-owner agent teams arrive in **two steps**: (1) pairwise grants over direct QUIC (earlier), (2) group-scoped grants over MLS (gated on TreeKEM). The vision degrades gracefully to pairwise.

## 10. Threat model deltas (beyond G5/W4)

| Threat | Mitigation |
|--------|-----------|
| Grant theft / replay | identity-bound (not bearer): caller must *be* the grantee, ML-DSA-65 + machine-verified. Stolen `grant_id` is useless without the grantee's key. |
| Scope creep via crafted request | closed scope taxonomy; action ⊆ scope checked structurally; unknown scope/action denied. |
| Revocation race | epoch bump is grantor-local and checked on every invoke; no distributed consensus needed; in-flight cancelled. |
| Compromised/injected grantee | DamageControl floor ungrantable; `PerCall` approval for Tier B/C; egress guard on results; all audited. |
| Exfil via results | outbound PII/exfil/data_class membrane (§7); `private_user` never crosses owner boundary. |
| Quiet-hours / abuse | `GrantConstraints` rate/quota/quiet-hours enforced at verify. |
| Metadata leakage of "who works with whom" | grants distributed over W4 controls (presence off by default, topic HMAC, MASQUE relay per `RelayMode`). |

## 11. Kill criteria (Tier 2 blocked until all hold)

- [ ] A grant cannot authorise any DamageControlPolicy `block`/`disaster` operation (floor is ungrantable).
- [ ] A revoked or expired grant denies on the *next* invocation, in-flight calls cancelled, audited.
- [ ] A request whose action is not ⊆ scope is denied (structural, not heuristic).
- [ ] A caller who is not the bound `grantee` (identity-verified) is denied even with a valid `grant_id`.
- [ ] Tier B/C scopes cannot run without the configured approval mode being honoured.
- [ ] No `private_user` data crosses an owner boundary in any result; egress guard proven.
- [ ] Peer results enter grantee memory only as `peer_claim` + `review_status=unreviewed`; cannot reach system/developer prompts without explicit user review + data-class upgrade (W3 kill criterion).
- [ ] Every issue/present/invoke/approve/revoke writes an audit record; no silent cross-owner action.
- [ ] Group-scoped grants remain disabled until TreeKEM wiring + G5 production enforcement land.
- [ ] Red-team: grant theft, scope-escalation, revocation-race, exfil-via-result, injection-via-result.
- [ ] Owner residual-risk sign-off (mirrors G5/W4 acceptance).

## 12. Build surface (what's actually net-new)

1. `CapabilityGrant` + closed `CapabilityScope`/`GrantConstraints` types (this doc's §3–5).
2. `GrantStore` — local persistence of issued + received grants + consent receipts + epoch.
3. `GrantEnforcer` — the §6.4 verify pipeline; the **only** new enforcement component.
4. `fae.grant/v1` distribution envelope (direct-message now; MLS-group later).
5. Extension of Tier-1 `DelegationRequest` with `grant_id: Option<[u8;16]>` and a cross-owner code path.
6. Grant-issuance UX in the thin client (consent capture → receipt) + approval-overlay reuse.
7. `FaeBenchmark`/red-team adversarial suite for §11.

Everything else (envelope parsing, trust, DamageControl, PII/exfil egress, audit, ExecService, symphony Runner) **already exists or is already planned** — Tier 2 composes them.

## 13. Open questions

1. **Grant discovery.** How does my conductor *know* Alice granted me `RunRunner{claude_code}` so it can route to it? **Designed in [`conductor-capability-advertisement-2026-06-05.md`](./conductor-capability-advertisement-2026-06-05.md)** — a received-grants index plus grant-scoped capability adverts the router's `CapabilityIndex` consults at routing time. Unified with Tier-1 self-fleet advertisement.
2. **Delegated re-grant.** May a grantee re-delegate (Alice lets me use her runner; may *my* other agent use it through me)? Default **no** (grants are non-transitive); a `delegable: bool` flag is a deliberate future extension, off by default.
3. **Consent receipt format & storage** — align with `memory-migration-plan` `consent_id` and the W3 review-required store; one schema, not two.
4. **Group grant revocation vs MLS epoch** — do we piggyback grant `epoch` on MLS `secret_epoch`, or keep them independent? Independent is simpler to reason about; revisit when TreeKEM wiring lands.
5. **Earned autonomy across owners** — does `FirstThenAuto` make sense cross-owner, or should cross-owner always be `PerCall` for Tier B/C? Lean conservative: Tier C always `PerCall`.

## 14. References
- `conductor-tier1-own-fleet-2026-06-05.md` — Tier 1; the §9.2 own-vs-other boundary that routes here.
- `fae-to-fae-governance.md` (G5) — envelope, consent, revocation, kill criteria.
- `directive-and-soul-migration.md` (W3) — 6-layer precedence, peer-memory quarantine.
- `x0x-metadata-threat-model.md` (W4) — presence/topic/relay controls for grant distribution.
- `memory-migration-plan.md` (G4) — provenance/`data_class`/`consent_id`/`review_status`, egress kill criterion.
- `cross-platform-engine-plan-2026-05-30.md` §11A — peer-tool gate (this doc closes it), group gating on TreeKEM.
- x0x: `create_invite`/`SignedInvite`, `GroupRole`/`GroupPolicy`, `ExecAcl`/`AllowEntry`, `ExecService::run_remote`, `ContactStore`/`TrustEvaluator`/`TrustDecision`, `is_agent_machine_verified`, `AgentCertificate`.
- x0x-symphony: `Runner`/`RunnerKind` (the `RunRunner` scope target).
- saorsa-mls `TreeKemGroup` — group-grant crypto dependency.
