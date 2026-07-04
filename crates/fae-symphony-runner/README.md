# fae-symphony-runner

A standalone binary that lets a Fae instance join a **group-of-Fae** task swarm.
It implements x0x-symphony's `Runner` trait over the local **fae-daemon** control
socket: it claims a `TaskItem` from **x0xd** (trust-gated, ML-DSA-signed by x0xd),
executes the work by driving `fae-daemon`'s native jailed agentic loop
(`conversation.delegate`, Phase F1) inside an isolated workspace, and lets the
stock `x0x-symphony-orchestrator` publish a **signed** handoff + proof artefacts.

Phase F commit 3.

## How it fits together

```
x0xd  ──(claim, trust-gated, signed)──►  X0xCrdtTracker ─┐
                                                         ├─► x0x-symphony-orchestrator
fae-daemon ──(conversation.delegate)──►  FaeRunner ──────┘        │
   (jailed ToolHost, budgets, receipts)                          ▼
                                              signed Handoff + proofs → x0xd (review)
```

- `FaeRunner` (`src/runner.rs`) — `Runner` impl. `start_session` verifies the
  daemon socket + token; `run_turn` opens an authenticated connection and
  delegates the issue into the daemon's jailed loop rooted at the issue's
  workspace. `stream_events` is `stream::empty` for v1 (structured event
  fidelity is a fast-follow); `stop_session` returns an empty usage report.
- `DaemonClient` (`src/daemon_client.rs`) — NDJSON client for the daemon's
  `session.authenticate` + `conversation.delegate` commands. Uses the
  `fae-control-plane` `Command`/`Response` envelope. **Never** depends on
  `fae-daemon`.
- `src/main.rs` — wires the production `X0xCrdtTracker` + `X0xdClient` signer
  into `Orchestrator::new(...)` and runs the dispatch loop. **Fails closed**: if
  x0xd `/agent` is unreachable at startup it refuses to run (no unsigned
  handoffs).

## Quarantine invariant (daemon stays clean)

Only this crate may depend on any `x0x-symphony-*` crate. Verify:

```bash
cd crates
cargo tree -i x0x-symphony-core
```

The output must list **only** `fae-symphony-runner` as a dependent — `fae-daemon`
must never appear.

## Dependency mechanics (git-rev pin)

The `x0x-symphony-*` crates are consumed as **git dependencies pinned to a
commit rev** (see `Cargo.toml`), not path deps. This is deliberate: the crate is
developed in a git *worktree* whose depth under `projects/` differs from the
folded `projects/fae/` checkout, so a fixed relative path dep would resolve to
two different places. A git-rev pin is location-independent.

x0x-symphony is a **private, unpublished** repo. On a machine without a cargo
git credential helper, export:

```bash
export CARGO_NET_GIT_FETCH_WITH_CLI=true   # reuse your CLI ssh credential
```

`Cargo.toml` documents a `dev override` path form and a `TODO(publish)` for the
eventual crates.io pin.

## Configuration

Environment variables (or a TOML file via `FAE_SYMPHONY_CONFIG`):

| Variable | Required | Default | Meaning |
|----------|----------|---------|---------|
| `FAE_SYMPHONY_X0XD_URL` | no | `http://127.0.0.1:12700` | x0xd REST base URL (signing + task list) |
| `FAE_SYMPHONY_TASK_LIST` | **yes** | — | x0xd TaskList id to claim from |
| `FAE_SYMPHONY_GROUP` | no | — | x0x group scoping an MLS-private list |
| `FAE_SYMPHONY_WORKSPACE_ROOT` | **yes** | — | root dir for per-issue workspaces |
| `FAE_SYMPHONY_PROOFS_DIR` | no | `proofs` | proof-artefact root |
| `FAE_DAEMON_SOCKET` | **yes** | — | fae-daemon control socket path |
| `FAE_DAEMON_TOKEN_PATH` | **yes** | — | fae-daemon bootstrap token file (0600) |
| `FAE_DAEMON_CLIENT_ID` | no | bootstrap client id | control-plane client id (needs `agent:delegate`) |
| `FAE_SYMPHONY_POLL_SECS` | no | `5` | poll-loop interval |

## Tests

Headless (CI-safe, no x0xd, no model — a mock daemon socket + in-memory tracker):

```bash
cd crates
cargo test -p fae-symphony-runner
```

Live (needs a running x0xd; self-seeding — creates a unique TaskList, seeds a
task, and proves the signer + tracker + signed-handoff legs end to end):

```bash
X0X_API_TOKEN=$(cat "$HOME/Library/Application Support/x0x/api-token") \
FAE_SYMPHONY_X0XD_URL=http://127.0.0.1:12700 \
cargo test -p fae-symphony-runner --test live_x0xd -- --ignored --nocapture
```

## v1 does not do

- No nested delegation (leaf role, depth 0 — F1 contract; fan-out is F2).
- No streaming `RunnerEvent` fidelity (`stream::empty` + final `TurnOutcome`).
- No unsigned handoffs — refuses to start if x0xd signing is unreachable.
- No `fae-daemon` dependency — the runner is a pure socket client.
