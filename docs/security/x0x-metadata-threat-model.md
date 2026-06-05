# x0x Metadata Threat Model for Fae — W4 Phase 0 Design

> Phase 0 design artifact. This does not authorize Fae↔Fae, peer-memory sharing, group memory, or daemon networking in Apple MVP.

## Status

Design complete when reviewed and owner signs residual risk. Until then, all Fae peer/group features remain blocked.

Owner residual-risk sign-off: **ACCEPTED in-session**  
Owner/date: 2026-06-02 — “I am ok with the security consideration”

## Scope

This document covers metadata exposed by future Fae use of x0x transport, including direct Fae↔Fae messaging, presence, discovery, group membership, and shared-memory coordination.

Apple MVP remains local-first. Peer/group features are post-MVP and require G5 production enforcement.

## x0x secure-groups input

The current x0x line includes substantial secure-group work:

- `v0.20.0` changelog reports TreeKEM secure-group membership via `saorsa-mls::TreeKemGroup`.
- ADR-0012 describes real TreeKEM as the forward secure-group plane for new confidential groups, with GSS grandfathered for legacy groups.
- Named-groups docs describe hidden/listed/public discovery policies, signed group cards, signed state commits, discovery shard caches, and privacy guards.

Impact on Fae:

- This reduces **content confidentiality** risk for future confidential group payloads when Fae eventually uses x0x secure groups.
- It does **not** remove metadata risks: who exists, who talks to whom, group discovery, timing, shard subscriptions, roster changes, IP/geolocation, and presence remain sensitive.
- Fae must not overclaim: TreeKEM/FS/PCS for content is not consent, audit, memory governance, or metadata privacy.
- Fae peer/group features remain blocked until G5 production enforcement exists.

Evidence grade: local x0x repo/changelog/docs verified. Final product claims should reference clean published tags/releases because the local x0x working tree was dirty during review.

## Assets at risk

- User identity and stable agent identity.
- Social graph / contact graph.
- Presence and availability patterns.
- Group membership and roles.
- Topic subscriptions and interests.
- Timing/frequency of communication.
- IP/geolocation and network path hints.
- Memory-sharing intent and consent state.
- Device/machine correlation.

## Adversaries

- Honest-but-curious bootstrap, relay, gossip, or discovery observers.
- Malicious peers or compromised Fae instances.
- Group members who later become untrusted.
- Network observers correlating timing/IPs.
- Same-user local malware stealing daemon tokens or local keys.
- Public-directory scrapers.

## Exposure matrix

| Exposure | Risk | Mitigation | Residual risk |
|---|---|---|---|
| Stable agent id | Long-term correlation | Scoped pseudonyms per trust tier/group where possible | Trusted peers still learn stable identity. |
| Presence | Reveals activity/liveness | Presence default `off`; modes: `off`, `contacts_only`, `trusted_only`, `on` | Contacts may infer routine. |
| Direct-message timing | Social graph and habits | Jitter/batching for non-urgent traffic; avoid background chatter | Timing still visible to endpoints/observers. |
| Group discovery cards | Interests and affiliations | Hidden groups never public; listed-to-contacts only via direct trusted channels; public directory only by explicit user setting | Public groups are intentionally discoverable. |
| Topic/shard subscriptions | Interest leakage | HMAC-SHA256 topic derivation where private; subscribe only when needed; randomize refresh/jitter | Public-directory shards remain observable. |
| Group roster changes | Relationship leakage | Signed state commits; only expose roster to members/admins where policy allows | Members learn roster by design. |
| Request-access events | Interest in joining group | Minimize payload; send to authority topic only; audit | Authority learns requester. |
| Memory-share offers | Reveals sensitive intent | G5 consent receipt; no auto-write; provenance/data-class gate | Recipient learns offer existed. |
| IP/geolocation | Location/network leakage | Prefer x0x/ant-quic NAT traversal privacy best practices; allow policy-selected MASQUE relay use to mask direct IP from peers; avoid unnecessary presence; no public broadcast by default | MASQUE relay sees both sides' relay traffic/timing; endpoints may still infer region/timing; relay choice becomes trust decision. |
| Bootstrap visibility | Network participation leakage | Minimize bootstrap metadata; use signed encrypted envelopes; avoid personal memory over bootstrap | Bootstrap sees connection attempts. |

## Presence policy

Default: `off`.

Allowed settings:

- `off`: no proactive presence publication.
- `contacts_only`: visible only to known contacts via direct/scoped channels.
- `trusted_only`: visible only to explicitly trusted peers.
- `on`: owner explicitly accepts wider visibility.

Presence changes must be auditable and user-visible.

## IP privacy and MASQUE relay policy

ant-quic includes MASQUE relay fallback (ADR-006/ADR-009) and x0x depends on ant-quic. Fae can use this as a future policy lever: x0x can expose available relay options and Fae can decide when to prefer direct, relay-on-failure, or relay-preferred modes.

Recommended Fae policy modes:

| Mode | Behavior | Use case |
|---|---|---|
| `direct_preferred` | Try direct/NAT traversal first, MASQUE on connectivity failure. | Default for trusted local/contact traffic. |
| `relay_on_sensitive_context` | Prefer MASQUE relay for selected peers/groups or sensitive contexts. | Hide direct IP/geolocation from peer while accepting relay metadata exposure. |
| `relay_required` | Refuse direct peer path; use approved MASQUE relay only. | High privacy contexts, public groups, untrusted peers. |
| `offline` | No network path. | Presence off / local-only mode. |

Requirements before Fae can use relay policy automatically:

- x0x exposes relay availability, relay identity, region, trust tier, cost/latency, and health to Fae.
- Fae's policy engine records why a relay was selected.
- User can set defaults and per-peer/per-group overrides.
- Relay use is auditable and visible in diagnostics.
- Fae does not confuse MASQUE IP masking with anonymity: the relay can observe timing and endpoint metadata, and remote peers see the relay path rather than the user's direct address.
- For peer memory/tool contexts, relay choice is only one metadata mitigation; G5 consent/provenance/audit gates still apply.

## Topic derivation

Private topics must not be human-readable group/contact names.

Recommended derivation:

```text
topic = "fae." || purpose || "." || hex(HMAC-SHA256(user_or_group_topic_secret, canonical_context))
```

Where `canonical_context` includes:

- protocol version;
- purpose (`dm`, `presence`, `memory_offer`, `group_control`);
- scoped peer/group id;
- epoch where applicable.

Rotation:

- rotate topic secrets on group removal/ban, trust downgrade, or owner request;
- keep old topic only for a bounded drain window;
- audit rotations.

## Secure groups and Fae memory

Even with x0x TreeKEM secure groups:

- group content confidentiality does not authorize memory writes;
- group membership does not imply consent to share personal memory;
- peer text remains untrusted input;
- memory-share envelopes must pass G5 closed-kind/schema/signature gate;
- peer-sourced memory must not influence system/developer prompts without user review + data-class upgrade;
- group memory features remain blocked until TreeKEM/PCS plus Fae consent/audit/revocation are both proven.

## Required Fae controls before peer/group release

- G5 production envelope parser with closed kinds and typed payloads.
- Consent receipt storage and revocation protocol.
- Transfer/audit log visible to the user.
- Provenance/data-class gates from W3.
- Presence default off.
- Topic HMAC derivation and rotation.
- Metadata residual-risk owner signoff.
- Adversarial tests for prompt injection, exfiltration, blocked peers, revocation, and query probing.

## Acceptance criteria

- [ ] Owner signs residual metadata risk above.
- [ ] Presence default `off` in product settings.
- [ ] Private topic derivation uses HMAC or stronger non-readable scheme.
- [ ] Hidden/contact-scoped groups do not publish public discovery cards.
- [ ] Peer memory/tool behavior remains disabled until G5 production enforcement.
- [ ] Red-team validates metadata leakage and residual-risk wording.

## Phase 0 conclusion

x0x secure groups improve the future transport option for confidential content, and Fae should benefit from that work. They do not remove the need for Fae-specific metadata policy, consent, provenance, audit, or prompt-isolation gates.
