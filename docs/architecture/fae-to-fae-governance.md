# Fae↔Fae Governance Architecture (G5) — 2026-06-01

> Phase 0 artifact for Fae↔Fae privacy governance. This is a hard gate for any peer/group feature that can transmit personal memory, trigger tools, or influence durable state.

## Status

G5 is **not complete** until the schema, consent, audit, revocation, exfil tests, and metadata threat model below are implemented and validated. This document defines the required contract.

## Threat model

Reviewers and implementers must assume:

- peers can be malicious, compromised, or prompt-injected;
- x0x bootstrap/relay/gossip observers may be honest-but-curious;
- local same-user processes may try to access daemon tokens;
- browser-origin attacks may target loopback WS/SSE endpoints;
- memory contains highly sensitive facts;
- a network message is untrusted input, never an instruction.

## Identity and trust

Required identities per message:

- `sender_agent_id`
- `sender_machine_id` or privacy-preserving equivalent
- signature over canonical envelope bytes
- trust tier at receipt time: `blocked`, `unknown`, `known`, `trusted`

Trust tier alone is not enough for memory sharing or tool execution. Sensitive actions require explicit consent/capability tickets.

## Machine-enforced message envelope

Every Fae↔Fae message must use a closed, versioned schema. Receivers reject unknown versions/kinds before the LLM sees content.

Minimum fields:

```text
schema_version: u16
kind: enum(chat, presence, task_update, memory_share, consent_request, consent_revocation, exec_request, exec_response, audit_receipt)
sender_agent_id: hex
sender_machine_id: hex or scoped pseudonym
issued_at_unix_ms: i64
ttl_ms: u64
nonce: bytes
capability_ticket_id: optional string
payload: typed object, not free-form instruction text
signature: ML-DSA-65 signature over canonical envelope
```

Required enforcement:

- hard payload size caps before UTF-8 decoding;
- timestamp skew and TTL rejection;
- closed enum for `kind`;
- topic namespace allowlist;
- structural isolation of network content from system/developer prompts;
- no direct tool calls from free-form peer text.

## Consent and data boundaries

No personal memory may cross instance boundaries without a consent receipt.

Consent receipt fields:

```text
consent_id
owner_agent_id
recipient_agent_id
allowed_data_classes
allowed_record_ids or query scope
purpose
retention_policy
forwarding_policy
created_at
expires_at
revoked_at optional
user_visible_summary
signature
```

Data classes:

- `secret` — never share;
- `private_local_only` — never share;
- `workspace_confidential` — share only with explicit scoped consent;
- `shareable_context` — share with consent and audit;
- `public` — may share, still audited if transmitted by Fae.

## Revocation

Revocation is mandatory and must be best-effort propagated:

1. user revokes consent;
2. local Fae marks receipt revoked;
3. peer receives `consent_revocation` message;
4. peer marks affected memories invalidated/forgotten per policy;
5. both sides write audit receipts;
6. UI shows residual-risk note if remote deletion cannot be proven.

## Audit and logging

Every outbound and inbound data transfer writes an audit record containing:

- message id;
- sender/recipient;
- consent id;
- data class;
- record ids or query scope;
- action taken;
- policy decision;
- timestamp;
- hash of payload, not raw sensitive payload unless explicitly required.

Users must be able to inspect a transfer log. Silent memory sharing is forbidden.

## Peer-triggered tools

Peer-originated requests may not execute arbitrary tools. Requirements:

- whitelist allowed tool categories per trust tier;
- require capability ticket for any mutation;
- require user confirmation for destructive actions;
- rate-limit per peer and globally;
- validate all tool inputs against strict schemas;
- write audit events for allowed and denied attempts;
- remote exec must pass both Fae `ToolMode`/DamageControl and x0x exec ACL.

## Local daemon control-plane baseline

The new Fae daemon must match or exceed current x0x local-control-plane posture:

- bind control API to loopback by default;
- require bearer or stronger client auth;
- store tokens/secrets with OS-appropriate owner-only permissions;
- restrict CORS/origin to literal loopback origins;
- authenticate WS/SSE without long-lived query tokens where possible;
- implement per-client capabilities, not only daemon-wide auth;
- expose health/status minimally without auth;
- log security-relevant denies.

Known x0x baseline from local inspection: `x0xd` binds to `127.0.0.1`, stores a generated bearer token as `0600`, applies auth middleware, restricts CORS to loopback literals, and returns `401` for unauthenticated `/agent` and `/ws`.

## Metadata threat model

Before peer features ship, document residual exposure for:

- presence cadence and online/offline inference;
- stable agent/machine identifiers;
- group discovery and subscription correlation;
- bootstrap/relay peer visibility;
- topic-name leakage;
- IP/geolocation leakage from reachable addresses.

Mitigations to evaluate:

- presence default `contacts_only` or `off`;
- topic-name hashing/HMAC;
- group features gated on TreeKEM + governance;
- reduced or jittered beacon cadence;
- privacy-preserving machine pseudonyms for lower trust tiers;
- explicit user setting for discoverability.

## Kill criteria

Do not ship Fae↔Fae personal-memory or group features if any are true:

1. no machine-enforced schema;
2. no consent receipt and revocation protocol;
3. no user-auditable transfer log;
4. peer text can directly influence tools or durable memory;
5. x0x metadata exposure is judged unacceptable and cannot be scoped down;
6. local daemon auth is weaker than x0x baseline;
7. TreeKEM/PCS is absent for group memory features.

## Adversarial validation suite

Required tests before G5 passes:

- prompt injection in peer message body cannot alter system/developer/tool policy;
- oversize/unknown-kind/expired/bad-signature envelopes are rejected;
- blocked/unknown peers cannot trigger memory writes or tools;
- consent revocation prevents further sends and creates audit records;
- peer-triggered destructive tool request requires confirmation or is denied;
- query-token leakage risk is removed or documented with mitigation;
- metadata threat model reviewed and residual risk signed off.

## G5 status

This document satisfies the **governance requirements artifact** part of G5. G5 remains blocked until enforcement code and adversarial tests exist.
