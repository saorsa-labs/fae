# Native ACP — review-team handoff (2026-06-19)

Status of the P8 / native-ACP track on worktree `…/projects/fae-acp`, branch
`acp-native`. **All stages A1–A4 are complete and (where externally possible)
live-proven.** This doc is the single place to review the track end to end.

---

## TL;DR

The Swift `acpx`-subprocess delegation path has been replaced by a native ACP
client living in the Rust daemon. Fae delegates a task → the daemon spawns the
agent's ACP server → drives it → streams output to the orb → and (A3) routes the
agent's mid-turn permission and fs requests back to Fae's approval card /
PathPolicy. One mock agent + a set of python harnesses prove every hop live.

| Stage | What | State |
|-------|------|-------|
| A1 | Swift `delegate_agent` → daemon `agent.run` (one-shot); `AgentExecute` scope; subprocess fallback | **committed** `4e1cbd20` |
| A2 | Persistent `agent.session_*` lifecycle; streaming `agent.output`/`agent.tool_call` on the V2 bus; `ACPSessionManager` deleted | **committed** `4e1cbd20` |
| A3a | Server-initiated requests (daemon→client, point-to-point); `session/request_permission` → Fae approval card | **committed** `158e4ffd` |
| — | Mock asking-agent + regression fixture | **uncommitted** (this handoff) |
| A3b | fs mediation: `fs/read_text_file` + `fs/write_text_file` → PathPolicy | **uncommitted** (this handoff) |
| A4 | `AgentRunner` conductor seam; error differentiation (auth/rate-limit/network); deleted dead `ACPProtocol.swift` | **uncommitted** (this handoff) |

Crate gate (re-run by you): `cd crates && env -u RUSTFLAGS cargo fmt -p fae-acp
-p fae-daemon -p fae-control-plane -- --check && cargo clippy … -D warnings &&
cargo nextest run -p fae-acp -p fae-daemon -p fae-control-plane` → **77 tests,
fmt + clippy clean.** `swift build --build-tests` clean; `AgentDelegateToolTests`
19/19.

---

## Committed so far

`4e1cbd20` (A1+A2), `158e4ffd` (A3a), `24492e8b` (A3b + mock asking-agent).

## Uncommitted in this handoff (fs.read proof + A4)

```
 M crates/fae-acp/src/bin/mock_acp_agent.rs        # mock now read-after-writes (proves fs.read)
 M crates/fae-acp/tests/mock_agent.rs              # test renamed → read_after_write_mediated
 M crates/fae-daemon/src/session.rs                # A4 classify_agent_error + test
 M native/.../Tools/DaemonAgentClient.swift        # A4 error codes → friendly messages (validate)
 M native/.../Tools/AgentDelegateTool.swift        # A4 use injected AgentRunner
 M native/.../Tools/AgentSessionTool.swift         # A4 use injected AgentRunner
 M native/.../Tests/.../AgentDelegateToolTests.swift  # A4 friendlyAgentError test
?? native/.../Tools/AgentRunner.swift              # A4 conductor seam (protocol + DaemonAgentRunner)
 D native/.../Tools/ACPProtocol.swift              # A4 dead code deleted
 D native/.../Tests/.../ACPProtocolTests.swift     # A4 dead tests deleted
```

**fs.read** is now proven (the reviewer flagged it as required before A4): the
mock reads back what it wrote, mediated through the per-turn channel; covered by
`mock_agent_fs_read_after_write_mediated` and the daemon-path proof
(`/tmp/a3b_acp_proof.py` → `"pong (approved, wrote and read back)"`).

---

## Architecture (the three primitives)

1. **Streaming (A2) — V2 event bus.** `agent.prompt` republishes the agent's
   output as `agent.output` / `agent.tool_call` events (scope `AgentExecute`,
   correlated by `turn_id` = the prompt's `request_id`) on the existing
   `conversation.subscribe` channel. The orb narrates by subscribing; the tool
   gets the final `ok`. One streaming mechanism, no second path.

2. **Server-initiated requests (A3) — point-to-point.** The daemon writes
   `{v, server_request_id, method, params}` on the connection that owns the turn
   and parks a oneshot; the client replies `{v, server_request_id, result}`,
   which the read loop routes via `ServerRequester::resolve`. To keep the read
   loop reading replies during a turn, **only `agent.prompt` is spawned** in
   `transport.rs` — every other inline command path is unchanged. `ServerReply`
   requires a top-level `server_request_id`, so it can never collide with a
   `Command` (which has `request_id`); unit-tested.

3. **Persistent sessions (A2) — `fae_acp::AcpSession`.** The agent's ACP server
   is spawned once (`initialize → session/new`) and kept alive across prompts.
   Per-turn channels carry streamed updates **and** mid-turn server requests
   (permission/fs) out to the daemon; `cancel` sends `session/cancel`.

**A3 flow (per turn):** agent asks (`session/request_permission` or `fs/*`) →
fae-acp routes it to the turn's request channel → daemon drives it to the client
via `ServerRequester` → Swift answers (approval card for permission;
`PathPolicy.validateWritePath` for writes, unrestricted reads) → reply flows
back into the agent's turn.

---

## The mock agent (permanent regression fixture)

`crates/fae-acp/src/bin/mock_acp_agent.rs` — an ACP **agent server** (over stdio)
that, during a prompt, always (1) issues `session/request_permission`, (2) if
approved **and** `FAE_ACP_MOCK_FS=1`, issues `fs/write_text_file` to an absolute
temp path, (3) streams a text chunk + ends the turn. Resolvable as the `mock`
agent only when `FAE_ACP_MOCK_AGENT_BIN` is set (production never sets it).

Why it exists: codex/pi run full-auto and never ask for permission; claude/gemini
are unavailable in this env (claude errors at startup; gemini's ACP server now
rejects individual clients). The mock is the only way to live-prove the security
round-trips, and it doubles as a committed test fixture.

**Committed tests** (`crates/fae-acp/tests/mock_agent.rs`, via
`CARGO_BIN_EXE_mock_acp_agent`): `permission_approved`, `permission_declined`,
`fs_write_mediated` — all pass in <0.5s, no daemon needed.

---

## Live proofs (reproduce these)

Launch a daemon + drive it with a python "client" (plays Fae's role). Run the
daemon **with its parent shell alive for the whole test** (it has parent-watch).

- **A2 streaming** `/tmp/a2_acp_proof.py` — a `conversation.subscribe` client
  sees `agent.output {turn_id}` while a `codex` session prompt runs; full
  start→prompt→cancel→list→close lifecycle returns `ok`.
- **A3a permission** `/tmp/a3_acp_proof.py mock` (daemon launched with
  `FAE_ACP_MOCK_AGENT_BIN=…/mock_acp_agent`) → `PERMISSION_REQUESTS_SEEN: 1`:
  agent asks → daemon emits `permission.request {sr-0}` → client approves
  `option_id='allow'` → turn completes `"pong (approved…)"`.
- **A3b fs** `/tmp/a3b_acp_proof.py` (daemon also `FAE_ACP_MOCK_FS=1`) →
  `FS.WRITE → /var/folders/…/T/a3_proof.txt`, mediator accepts → turn completes
  `"pong (approved, wrote file)"`.

The python harnesses are throwaway reproduction aids; the committed coverage is
the mock tests + the `ServerRequester`/permission-decision/PathPolicy unit tests.

---

## Key learnings / gotchas

- **ACP dispatch-loop deadlock (real bug found + fixed).** An `on_receive_request`
  handler that `block_task().await`s a reverse request deadlocks — the dispatch
  loop can't read the reply it's waiting for (see the dep's `concepts::ordering`).
  The mock's prompt handler and fae-acp's permission/fs handlers all wrap their
  reverse-request work in `cx.spawn(...)` with the responder moved in. This was
  never hit before because no real agent asked.
- **Reads vs writes.** `PathPolicy.validateWritePath` gates writes only (system
  paths, sensitive dotfiles, Fae's own data files); reads are unrestricted by
  design (Fae reads anything local).
- **Absolute paths.** ACP paths are absolute; the mock uses `temp_dir()` so a
  real mediator resolves them and PathPolicy allows the temp dir.
- **Daemon parent-watch.** A directly-launched daemon exits when its launching
  shell dies — run launch + proof in one script.

---

## A4 — done

- **Conductor seam** — `AgentRunner` protocol (`native/.../Tools/AgentRunner.swift`)
  + `DaemonAgentRunner` conformer; `AgentDelegateTool` + `AgentSessionTool` now
  depend on the injected runner, not the concrete `DaemonAgentClient`. The future
  cross-machine conductor (and tests) inject their own runner.
- **Error differentiation** — daemon `classify_agent_error` maps an ACP failure
  to `auth_error` / `rate_limited` / `network_error` / `unknown_agent` /
  `agent_launch_failed` / `agent_error`; Swift `friendlyAgentError` turns the
  code into an actionable message. Both unit-tested (incl. gemini's
  individual-client rejection → `auth_error`).
- **Dead code removed** — `ACPProtocol.swift` + `ACPProtocolTests.swift` (43
  dead tests) deleted; no live references remained.

**Deferred (not blocking; land with their consumers):** attachments in prompts,
and replacing the env-gated `mock` / hard-coded agent recipes with a config table
(mirror the `acp-setup` skill) — best done when the conductor's agent-discovery
needs are concrete.

## Not yet live-proven through the bundled app

Every hop is proven via the mock + python harnesses against a directly-launched
daemon. What remains for a release gate: the **bundled `run-dev` app** path where
(a) the LLM emits `delegate_agent`/`agent_session`, and (b) a real asking-agent
(authed claude, when available) surfaces an actual approval card. The Swift
approval-card + PathPolicy code is unit-tested and compiles; the in-app surface
is the one thing the headless proofs can't exercise.
