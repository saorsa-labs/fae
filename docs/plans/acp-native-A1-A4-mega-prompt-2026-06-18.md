# Mega-prompt — native ACP client: finish Stages A1→A4 (roadmap phase P8)

Paste into a fresh session. This is a **parallel track**, run on its own branch while another team works
P2/B5 on `llamacpp-serving-adapter`. Self-contained; **verify every claim against the repo and live
output** — static-only review has missed a release-blocking bug on this project, and agents have
fabricated reports. The reviewer re-runs your evidence.

> ## ✅ A1 + A2 DONE — committed `4e1cbd20` on `acp-native` (reviewer-verified, 2026-06-18)
> - **A1**: `AgentDelegateTool` → daemon `agent.run` via `DaemonAgentClient`; `AgentExecute` on
>   SwiftFrontend scopes; legacy `acpx` kept behind a daemon-unavailable fallback.
> - **A2**: `AcpSession` (persistent start/prompt/cancel/close) + `AgentSessionRegistry`; daemon
>   `agent.session_*` commands republish agent output as `agent.output`/`agent.tool_call` on the
>   **existing V2 `conversation.subscribe` bus** (one streaming mechanism, correlated by `turn_id`);
>   `AgentSessionTool` migrated; `ACPSessionManager` deleted. Verified: fmt/clippy `-D warnings`/70 tests;
>   live (codex) subscriber saw `agent.output{delta:"pong"}` on the V2 bus + full lifecycle.
> - **A3a DONE** — committed `158e4ffd` (reviewer-verified). Server-initiated requests: `agent.prompt`
>   spawns so the read loop keeps reading; `{server_request_id,method,params}` out, client
>   `{server_request_id,result}` reply routed back (`ServerRequester`). `permission.request` →
>   Fae governance approval card. fmt/clippy `-D warnings`/73 tests (incl. parse-disambiguation); transport
>   spawn live-proven (codex/pi). **Live gap: no available agent ASKS** (codex/pi full-auto; claude/gemini
>   unavailable) — permission round-trip verified by unit tests + spawn path, not a live asking-agent.
> - **A3b + MOCK AGENT DONE** — committed `24492e8b` (reviewer-verified). The mock ACP asking-agent
>   (`crates/fae-acp/src/bin/mock_acp_agent.rs` + `tests/mock_agent.rs`) LIVE-proves the round-trip
>   (permission: PERMISSION_REQUESTS_SEEN:1; fs.write → temp file → approved → wrote) — closing the A3a
>   live gap. fs/read+write route via the server-request mechanism; `fs.write` gated by
>   `PathPolicy.validateWritePath`. Fixed a real ACP dispatch-loop deadlock (`cx.spawn`). 76 tests +
>   3 Swift PathPolicy tests; clippy `-D warnings` clean.
> - **fs.read SECURITY GATE DONE** — committed `d1884f7f` (reviewer-implemented; the team had read the
>   "REQUIRED fix" as a coverage gap and left `fs.read` unrestricted). Added `PathPolicy.validateReadPath`
>   (reuses `blockedDotfiles` + `protectedFaeRoots`/`protectedFaeFiles` so read/write blocklists can't
>   drift): blocks the secret/identity set on the delegated read path (`~/.ssh`, `speakers.json`,
>   `~/.fae-vault`, …) while ALLOWING general project/system reads. `readFile` gates through it. 3 tests
>   pass (block `~/.ssh`/`speakers.json`, allow `~/Documents`).
> - **A4 DONE** — committed `d1884f7f` (reviewer-verified). Conductor seam (`AgentRunner` protocol +
>   `DaemonAgentRunner`, injected into the tools); error differentiation (`classify_agent_error` →
>   auth/rate/network/… + Swift `friendlyAgentError`); dead `ACPProtocol.swift` + tests deleted. 77 crate
>   tests + 19/19 AgentDelegateToolTests; clippy `-D warnings`/swift build clean.
> - **✅ NATIVE ACP TRACK A1→A4 COMPLETE + gate-green.** Deferred/follow-ons (with the conductor):
>   attachments, config-driven agent discovery, orb rendering of `agent.output` (separate orb lane),
>   deterministic mid-turn cancel proof, and the bundled run-dev surface (real LLM `delegate_agent` +
>   real authed agent card) — that last is the one path the mock/headless proofs can't exercise.

---

## Workflow — read first (per-STAGE hand-back)

**You implement AND test ONE stage to completion, then HAND BACK for review before starting the next.
You do NOT commit/push.** The reviewer verifies against live output + `git diff`, commits, and tells you
to proceed to the next stage. A1 → review → A2 → review → A3 → review → A4. Each stage is independently
useful (A1 alone ships daemon-backed delegation).

Per-stage evidence floor: `git diff --stat`; `cd crates && env -u RUSTFLAGS cargo fmt -p <c> -- --check
&& cargo clippy -p <c> --all-targets -- -D warnings && cargo nextest run -p <c>` for touched crates;
`swift build` clean; and the stage's **live proof** (a real `delegate_agent` turn through `run-dev`,
daemon-log-attributed). Heed the **bundling trap** (daemon must be rebuilt + re-embedded; full bundle/
embed/sign chain — `just build` alone won't update the running daemon).

---

## Objective

Move ACP agent delegation fully into the daemon as a native, cross-platform client, and retire the
Swift `acpx`/subprocess path. The Rust foundation is built; this finishes the Swift wiring (A1),
streaming + persistent sessions (A2), the permission/fs round-trip payoff (A3), and the conductor seam
+ cleanup (A4). Plan of record: open-gaps §A + `~/.claude/plans/smooth-hopping-kettle.md`.

---

## Worktree + what already exists (DO NOT rebuild)

**Work in the dedicated git WORKTREE the reviewer created — `/Users/davidirvine/Desktop/Devel/projects/
fae-acp` on branch `acp-native`, based off the current `llamacpp-serving-adapter` HEAD.** Do all your
work there (`cd /Users/davidirvine/Desktop/Devel/projects/fae-acp`). **Do NOT `git checkout` a different
branch in the main repo `…/projects/fae`** — the P2/B5 team is live in that working tree; switching its
branch would clobber their uncommitted work. The worktree shares the same `.git` but has its own working
directory + branch, so both teams build in parallel without interfering.

**IGNORE the old `acp-native-rust@101146cd` history** — it was 65 commits behind and predates the
llama.cpp daemon; its ACP work is already in the base your worktree starts from. (`acp-native` ≠
`acp-native-rust`.)

Already in the base (green `cd crates && just check`):
- **`crates/fae-acp`** — ACP client on Zed's `agent-client-protocol` 0.14: spawns an agent ACP server
  (`gemini --acp`, `npx claude-code-acp/codex-acp/pi-acp`), drives `initialize → session/new →
  session/prompt`, accumulates streamed text + tool calls, answers permission requests per policy.
  `run_one_shot(...) -> AcpOutcome`. Proven live vs gemini.
- **Daemon command surface** — `Scope::AgentExecute` + `agent.run` (one-shot) + `agent.list` in
  `crates/fae-daemon/src/session.rs` (`agent_run`, ~line 385). 21+ daemon tests pass.
- **Swift (old path, to migrate)**: `AgentDelegateTool.swift`, `AgentSessionTool.swift`,
  `ACPSessionManager.swift`, `ACPProtocol.swift` — currently the macOS-only `acpx` subprocess route.
- **Daemon socket client to reuse**: `DaemonLLMEngine.swift`'s `DaemonSocketConnection` +
  `session.authenticate` (the same path B1.5 uses); the bootstrap client is
  `fae_control_plane::BOOTSTRAP_CLIENT_ID`.

---

## ⚠️ Parallel-work coordination (read before touching shared files)

Another team is editing `llamacpp-serving-adapter` (P2/B5: engine + audio + `DaemonLLMEngine`). To avoid
conflicts and divergence:
- **Stay in ACP-owned files**: `crates/fae-acp/*`, the `agent.*` dispatch in `session.rs`, and the Swift
  `Agent*`/`ACP*` tool files. Do NOT touch the engine/audio/orb code (`llamacpp_adapter.rs`,
  `runAudioTurn`, `ModelManager`, orb host).
- **ONE streaming mechanism (critical).** A2 needs daemon→client streaming. The daemon ALREADY has it:
  the V2 server-push channel — `conversation.subscribe`, `EventBus`/`ConnSink`, and the
  `Event { v, event, payload }` wire type in `fae-control-plane` (see `crates/fae-daemon/src/events.rs`).
  **A2 MUST extend that mechanism (interim event frames on the same channel), NOT invent a second
  streaming path.** Coordinate with the reviewer before building A2 so it composes with the engine's
  streaming, per the open-gaps "design them together" note.
- **Pull `llamacpp-serving-adapter` into your worktree branch frequently** (`git merge` or `git rebase`
  from within the worktree — the branch is visible since the `.git` is shared); the reviewer handles the
  final merge back. Keep `session.rs` dispatch edits minimal + localized (new `agent.*` arms only).
- **Branch hand-back**: you commit on `acp-native` in the worktree per the workflow? NO — same rule as
  every team: do NOT commit/push; hand back per stage and the reviewer commits onto `acp-native`. (The
  worktree just keeps your build isolated from the B5 team's.)

---

## The stages

### A1 — Swift thin client (finish Stage 1)  ← START HERE
**Do:** Repoint `AgentDelegateTool.swift` at the daemon `agent.run` over `DaemonSocketConnection` (reuse
the `DaemonLLMEngine` socket + `session.authenticate`). Grant the Swift bootstrap client the
**`AgentExecute`** scope (it currently holds the SwiftFrontend default scopes — add AgentExecute). Keep
the old Swift `acpx` subprocess path behind a flag as fallback. Rebuild + re-embed the daemon (it must
carry `agent.run`).
**Done:** a live in-conversation `delegate_agent` turn through `run-dev` is served by the **daemon**
`agent.run` (daemon-log-attributed: the `agent.run` dispatch + the spawned agent server), not the Swift
subprocess; fallback flag still works; `swift build` + crate gate green.

### A2 — Streaming + persistent sessions (Stage 2)
**Do:** Add **interim event frames** on the EXISTING V2 channel (same `request_id`, an `event` field,
before the final `ok`) so agent output narrates on the orb live; add `agent.session_start / prompt /
cancel / close`; add a streaming variant of the Swift `roundTrip`. Migrate `AgentSessionTool` to the
daemon. **Delete Swift `ACPSessionManager`.**
**Done:** a multi-turn agent session streams interim output to the orb; session lifecycle
(start/prompt/cancel/close) works; `ACPSessionManager` gone; the streaming reuses the V2 mechanism
(no second streaming path).

### A3 — Permission round-trip + fs mediation (Stage 3, the payoff)
**Do:** Add **server-initiated requests** (daemon → Swift, awaiting a reply) on the control plane. Wire
ACP `session/request_permission` → Fae's approval card; wire `fs/read_text_file` / `fs/write_text_file`
→ gated by `DamageControlPolicy` / `PathPolicy` (the existing security stack).
**Done:** an agent's permission request surfaces Fae's approval card and the user's answer flows back;
agent file reads/writes are mediated by the policy layer (a blocked path is refused); proven live.

### A4 — Conductor seam + polish (Stage 4)
**Do:** Expose `AcpClient` behind the future conductor's `Acp` Runner seam; differentiate errors
(auth / rate-limit / network); attachments; agent install/discovery (mirror the `acp-setup` skill).
**Delete dead Swift `ACPProtocol.swift`.**
**Done:** the ACP client is reachable behind the conductor seam; error classes are distinguished in the
UI; dead Swift ACP code removed; crate + swift build green.

---

## Gotchas
- **Work in the worktree `…/projects/fae-acp` (branch `acp-native`), NOT the main repo** — the B5 team
  is in `…/projects/fae`. Build/bundle from the worktree so your artifacts don't collide with theirs.
- **One streaming mechanism** — A2 extends the V2 `Event`/`conversation.subscribe` channel; coordinate
  before building.
- **ADR-010 / sidecars**: ACP agents are subprocess sidecars under `DaemonProcessRegistry` — ensure
  spawned agent servers join orphan-kill (parent-watch), like `llama-server`.
- **Bootstrap auth**: the Swift client authenticates as `BOOTSTRAP_CLIENT_ID`; it needs `AgentExecute`
  added to its granted scopes (A1).
- `env -u RUSTFLAGS` for crate builds; **quit the dev app before any local `swift test`**; bundling trap
  (rebuild + re-embed the daemon for every stage's live proof).
- Don't touch the B5 team's engine/audio/orb files; **autoresearch.jsonl** stays out of your diff.

## Done criteria (per stage — hand back after each)
- **A1**: live `delegate_agent` served by daemon `agent.run` (attributed); fallback flag intact; green.
- **A2**: streaming interim frames on the V2 channel; session lifecycle; `ACPSessionManager` deleted.
- **A3**: permission round-trip → approval card; fs mediated by DamageControl/PathPolicy; proven live.
- **A4**: conductor seam; error differentiation; `ACPProtocol.swift` deleted; green.
- Each: `git diff --stat`, crate gate (`env -u RUSTFLAGS` fmt/clippy `-D warnings`/nextest), `swift
  build`, and the live proof. **Hand back; do not commit/push.**

## Suggested order
A1 (start — small, ships daemon-backed delegation) → hand back → A2 (coordinate streaming first) → hand
back → A3 (the payoff) → hand back → A4 (polish + cleanup). Full plan:
`docs/plans/cross-platform-completion-roadmap-2026-06-18.md` (P8).
