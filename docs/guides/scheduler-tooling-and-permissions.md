# Scheduler tooling, channels, and permission behavior

This note summarizes the current runtime behavior for scheduler + tool integration.

## Scheduler startup channels

At runtime start, the host initializes scheduler channels via:

- `crate::startup::start_scheduler_with_llm(...)`

The host now wires both returned values:

- scheduler join handle (`sched_jh`) is stored for lifecycle ownership
- scheduler result receiver (`sched_rx`) is consumed on a background Tokio task

File:

- `src/host/handler.rs`

## Scheduler error surfacing

Scheduler task failures are surfaced as host runtime errors.

When the scheduler result channel emits `TaskResult::Error(msg)`, the host sends:

- event name: `runtime.error`
- payload: `{ "source": "scheduler", "error": msg }`

This keeps scheduler failures visible to GUI/TUI consumers without crashing runtime control flow.

## Tool + permissions behavior (summary)

Scheduler mutation tooling and approval/permissions paths remain layered:

1. tool registry mode gates which scheduler tools are exposed
2. mutation-capable tools are wrapped by approval flow when approvals are enabled
3. shared permission state is threaded through runtime channels so permission updates are observed immediately by gated tools

Related files:

- `src/agent/mod.rs`
- `src/host/handler.rs`
- `src/permissions.rs`

## TODO (tool-activity UX polish)

Tool activity feedback in macOS UI is functional but still needs tuning:

- [ ] refine cue loudness/timbre for execute/success/failure sounds
- [ ] tune status-bubble phrasing/persistence to reduce chatter in rapid tool chains
- [ ] consider debouncing repeated tool events into a concise summary bubble
