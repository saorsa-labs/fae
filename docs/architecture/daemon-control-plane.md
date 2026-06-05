# Fae Daemon Control Plane — Phase 0 Security Design

> Required by G5 / review-brief precondition 7 before Phase 1 daemon implementation. This document specifies the local control-plane security boundary for a future user-scoped Rust daemon. It is design + Phase-0 acceptance criteria, not production implementation approval.

## Status

**Commit-blocker partially open.** This document now specifies the required security model, but W2 is not complete until the Phase-0 G5 enforcement scaffold compiles and red-team/oracle review accepts the residual risk.

## Security goal

The daemon may eventually own sensitive local capabilities: conversation, mic/audio, memory, tools, scheduler, skills, model access, and x0x identity. Therefore the control plane must defend against:

- unauthenticated local web pages;
- DNS rebinding;
- malicious browser extensions/Electron apps running as the same user;
- stale or stolen client tokens;
- confused-deputy use of a broad daemon token;
- peer or skill content trying to cross into memory/tools/LLM prompts without policy;
- accidental unsafe defaults during development.

## Baseline to match or exceed

Current x0x `x0xd` local control plane provides the minimum baseline:

- API binds to `127.0.0.1` by default;
- generated bearer token stored with owner-only permissions (`0600` on Unix);
- auth middleware across control-plane endpoints;
- CORS restricted to literal loopback origins;
- unauthenticated sensitive endpoints return `401`.

Fae must exceed this baseline by adding **per-client capabilities** and per-message authorization. Daemon-wide bearer auth is not sufficient.

## Transport decisions

### Default transport

1. **Unix domain socket is default on macOS/Linux.**
   - Parent directory: `~/Library/Application Support/fae/run/` on macOS, mode `0700`.
   - Socket path: `~/Library/Application Support/fae/run/fae-daemon.sock`.
   - Socket file: create with restrictive umask and chmod/verify owner-only permissions immediately after bind where the platform exposes socket mode bits; fail closed if permissions cannot be made owner-only on supported Apple v1 platforms.
   - No world-writable directory component is allowed.

2. **TCP loopback is development/diagnostic only unless explicitly enabled.**
   - Bind addresses: literal `127.0.0.1` and `::1` only.
   - Never bind `0.0.0.0`, `::`, LAN IPs, mDNS names, or wildcard hostnames.
   - If TCP is enabled, both IPv4 and IPv6 listeners enforce identical auth/origin/host policy.

3. **Remote access is not part of Apple MVP.**
   - x0x/Fae↔Fae features are separate post-MVP tracks requiring G5 enforcement.

## Client classes and capability scopes

Each authenticated client gets a `client_id`, class, expiry, and exact capability set. No request authorizes solely because it has a valid daemon token.

| Client class | Default scopes | Notes |
|---|---|---|
| Swift macOS frontend | `status:read`, `conversation:write`, `audio:playback` | `audio:capture`, memory, and tool scopes require explicit feature flag/approval during rollout. |
| CLI diagnostic | `status:read` | Admin scopes require short-lived elevated token. |
| Test harness | explicitly requested test scopes only | Disabled in release builds unless owner enables dev mode. |
| Browser diagnostic UI | `status:read` only | Served UI must use strict Host/Origin checks and no sensitive operations. |
| x0x/peer bridge | none by default | Requires G5 envelope gate and explicit owner approval. |

### Scope catalog

| Scope | Authorized examples |
|---|---|
| `status:read` | health, version, model load status |
| `conversation:write` | inject user text/audio events |
| `conversation:read` | subscribe to turn/token events |
| `memory:read` | recall/search summaries |
| `memory:write` | capture, supersede, invalidate |
| `tool:read` | list tools and schemas |
| `tool:execute:safe` | low-risk read-only tools |
| `tool:execute:dangerous` | bash/write/edit/mail/calendar mutations; always needs broker/confirmation |
| `audio:capture` | start/stop mic capture |
| `audio:playback` | TTS playback control |
| `scheduler:read` | list scheduled jobs |
| `scheduler:write` | create/update/delete jobs |
| `x0x:message` | peer send/receive after G5 envelope gate |
| `x0x:admin` | contact/trust/group changes |
| `admin` | shutdown, update, config mutation, emergency lockout |

Unknown scopes are denied. Unknown endpoints are denied.

## Authentication and token lifecycle

### Bootstrap

- The first trusted client is the Swift app launched by the same user.
- Bootstrap creates a local client record in the daemon state DB and stores client secret material in the macOS Keychain when available.
- File fallback is allowed only for development or non-Keychain platforms and must use `0600` token files in a `0700` directory.

### Token shape

- Tokens are opaque random values, minimum 256 bits from OS CSPRNG.
- Tokens identify a client session, not global daemon authority.
- Stored server-side token material is hashed with a modern password/hash or keyed digest; never log raw tokens.
- Client records include: `client_id`, class, scopes, issued_at, expires_at, last_used_at, revoked_at, display_name, and audit metadata.

### Expiry / rotation / revocation

- Default user-facing app token: rotate at least every 30 days or on app reinstall/security event.
- Elevated/admin tokens: maximum 10 minutes.
- WS/SSE tickets: maximum 60 seconds and single-use.
- Revocation is checked on every request and message.
- Emergency lockout revokes every non-bootstrap token and stops TCP listeners.

## HTTP, Host, Origin, CORS

For any HTTP/WebSocket/SSE listener:

1. Reject requests unless `Host` is exactly one of:
   - `127.0.0.1:<port>`
   - `[::1]:<port>`
2. Reject `localhost`, private/LAN/custom hostnames, and mDNS names even if they resolve to loopback. Literal loopback IPs are required for TCP diagnostics.
3. CORS allowlist is literal and minimal:
   - Swift app does not need browser CORS.
   - Diagnostic browser UI may use `http://127.0.0.1:<port>` and `http://[::1]:<port>` only.
4. Set defensive headers for any browser-visible response:
   - `X-Content-Type-Options: nosniff`
   - `Cache-Control: no-store`
   - `Content-Security-Policy: default-src 'none'; connect-src 'self'; script-src 'self'; style-src 'self'`
5. Preflight requests are subject to the same Host/Origin policy.

## WebSocket/SSE authentication

Long-lived `?token=` URL query authentication is forbidden.

Required flow:

1. Client authenticates over HTTP or Unix socket with its client token.
2. Client requests a short-lived single-use stream ticket for a specific purpose/scope.
3. Daemon returns a ticket bound to:
   - client id;
   - endpoint path;
   - requested scopes;
   - nonce;
   - expiry <= 60 seconds.
4. Client presents ticket via `Sec-WebSocket-Protocol` or an HTTP-only same-origin cookie for browser diagnostic UI.
5. Daemon stores issued ticket ids/nonces in an in-memory replay cache with expiry. A ticket is consumed atomically during upgrade; reused, unknown, expired, or wrong-endpoint tickets are denied and audited.
6. Daemon upgrades only if ticket is valid, unexpired, unused, and bound to the requested stream.
7. Every message/event still gets per-message authorization.

## Per-message authorization

Every command maps to required scopes. The daemon must check authorization after parsing and before any side effect.

Examples:

| Command | Required scopes |
|---|---|
| `host.ping` | `status:read` |
| `runtime.status` | `status:read` |
| `conversation.inject_text` | `conversation:write` |
| `audio.start_capture` | `audio:capture` |
| `memory.search` | `memory:read` |
| `memory.capture` | `memory:write` |
| `tool.execute` safe | `tool:execute:safe` plus broker allow |
| `tool.execute` dangerous | `tool:execute:dangerous` plus broker confirm |
| `runtime.shutdown` | `admin` |

Default for unknown command/scope is deny + audit.

## Audit logging

Audit rows are required for:

- authentication failure;
- authorization denial;
- token issue/rotation/revocation;
- WS/SSE ticket issue/consume/failure;
- high-risk commands;
- all tool execution attempts;
- all memory writes;
- all peer envelope ingress/egress after G5;
- emergency lockout.

Minimum fields:

- `event_id`;
- timestamp;
- `client_id` if known;
- command/endpoint;
- decision: `allow`, `deny`, `confirm_required`, `error`;
- reason code;
- capability scopes involved;
- redacted argument hash, never raw secrets;
- peer/message id if relevant.

## Emergency lockout / panic mode

The daemon must expose an owner-accessible emergency mode that:

1. revokes all non-bootstrap tokens;
2. stops TCP listeners;
3. rejects WS/SSE ticket issuance;
4. disables tools, memory writes, scheduler writes, and audio capture;
5. writes an audit event;
6. requires local owner action to re-enable.

## G5 peer envelope boundary

Peer/x0x/Fae↔Fae data is untrusted. No peer text may reach the LLM, memory writer, or tool broker until it passes a machine-enforced envelope gate.

Required envelope properties:

- closed `kind` enum;
- `schema_version` gate;
- signature verification hook;
- consent/authorization lookup hook;
- audit write before dispatch;
- peer-sourced memory marked with provenance and low data class;
- unknown fields rejected where practical;
- no free-form peer text treated as developer/system instruction.

## Exit criteria

W2 exits only when:

- this design is reviewed by red-team/oracle;
- a Phase-0 enforcement scaffold compiles;
- tests prove unknown kind/schema rejection and audit-writing;
- WS/SSE query token auth remains forbidden;
- residual risks are explicitly accepted by owner.

Until then, **production daemon ownership of mic, memory, tools, scheduler, or peer features remains blocked.**
