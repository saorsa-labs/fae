# ADR-006: Voice Privilege Escalation (Tool Approval System)

**Status:** Accepted
**Date:** 2026-02-23
**Scope:** Tool safety across pipeline, agent, host, and native UI layers

## Context

Fae operates with a `tool_mode` config that controls which tools are available:
`off`, `read_only`, `read_write`, `full`, `full_no_approval`. In `full` mode,
powerful tools like `bash`, `write`, `edit`, `python_skill`, and
`desktop_automation` are available to background agents.

Running arbitrary shell commands or editing files without user consent is
dangerous. The user must stay in control of what Fae executes on their machine,
while Fae must be able to request elevated access conversationally (voice or
button) without breaking the real-time pipeline flow.

## Decision

### Approval-gated tools

In `full` mode, all dangerous tools are wrapped in `ApprovalTool`, which
intercepts execution and waits for explicit user consent before proceeding.

```
BashTool        → ApprovalTool(BashTool)
WriteTool       → ApprovalTool(WriteTool)
EditTool        → ApprovalTool(EditTool)
PythonSkillTool → ApprovalTool(PythonSkillTool)
DesktopTool     → ApprovalTool(DesktopTool)
```

`ReadTool` is never approval-gated (read-only is safe).

`full_no_approval` bypasses gating entirely — intended for trusted automation
scenarios, not default usage.

### Three resolution paths

When an `ApprovalTool` fires, the user can respond via:

1. **Voice** — the coordinator speaks a prompt ("I'd like to run a command:
   `date`. Say yes or no.") and listens for a yes/no response.
2. **Button** — the Swift UI shows a floating approval card with Yes/No buttons
   and keyboard shortcuts (Enter/Escape).
3. **Timeout** — after 58 seconds with no response, the request is auto-denied.

All three paths converge on the same resolution channel. Duplicate resolution
(e.g., button tap after voice "yes") is handled gracefully with a
"already resolved" log.

### Architecture (7 phases)

#### Phase 1: Voice response parser (`src/voice_command.rs`)

- `ApprovalVoiceResponse` enum: `Approved`, `Denied`, `Ambiguous`
- `parse_approval_response()` with wake prefix stripping, punctuation tolerance
- Word-boundary matching prevents "yes" matching "yesterday"
- Negation-aware: "not sure" → Denied, not Approved

#### Phase 2: Notification channel (`src/pipeline/messages.rs`, `src/host/handler.rs`)

- `ApprovalNotification` struct: `request_id`, `tool_name`, `input_json`
- `mpsc::unbounded_channel` pair created during `request_runtime_start()`
- Handler bridge forwards to coordinator AND emits `"approval.requested"` for UI

#### Phase 3: Coordinator state machine (`src/pipeline/coordinator.rs`)

- `PendingVoiceApproval` struct with timing and reprompt tracking
- `awaiting_approval` `Arc<AtomicBool>` shared between VAD and LLM stages
- Transcriptions intercepted during approval mode (never reach the LLM)
- `approval_queue: Vec<ApprovalNotification>` for sequential processing
- Ambiguous responses re-prompt up to 2x, then auto-deny

#### Phase 4: Echo bypass

- `awaiting_approval` flag gates echo suppression so the listening tone plays
  during approval windows, even though Fae just spoke
- Ensures the mic is active for the user's yes/no response

#### Phase 5: TTS prompt generation (`src/personality.rs`)

- `format_approval_prompt()` generates tool-specific spoken prompts
- `extract_approval_detail()` parses JSON args (bash→command, write→path)
- Canned response banks: `APPROVAL_GRANTED`, `APPROVAL_DENIED`,
  `APPROVAL_TIMEOUT`, `APPROVAL_AMBIGUOUS`

#### Phase 6: Swift UI overlay

- `ApprovalOverlayController.swift` — observes `.faeApprovalRequested`,
  publishes `activeApproval`, `approve()`/`deny()` actions
- `ApprovalOverlayView.swift` — compact card with glass material, Yes/No
  buttons, Enter/Escape keyboard shortcuts
- `AuxiliaryWindowManager.swift` — manages approval NSPanel positioning
- `BackendEventRouter.swift` — routes `"approval.requested"` →
  `.faeApprovalRequested`, `"approval.resolved"` → `.faeApprovalResolved`
- `HostCommandBridge.swift` — routes `.faeApprovalRespond` →
  `"approval.respond"` command back to Rust

#### Phase 7: Response drain (`src/host/handler.rs`)

- Async task drains `(request_id, approved)` tuples from coordinator
- Resolves `ToolApprovalRequest` oneshot channels in the pending map
- Emits `"approval.resolved"` event for Swift UI dismissal
- Handles race conditions (already resolved by button/timeout)

### Intent-based tool routing

The coordinator uses `classify_intent()` to detect whether a user message needs
tools. Keyword categories route to specific tool allowlists:

| Keywords | Tools |
|----------|-------|
| time, date, clock, disk, system, uptime, weather | `bash` |
| search, web, internet, lookup | `web_search`, `fetch_url` |
| calendar, meeting, event, schedule | calendar tools |
| reminder, todo | reminder tools |
| note, notes | notes tools |
| mail, email, inbox | mail tools |
| contact, address book | contact tools |
| read file, open file | `read` |

When `needs_tools = true`, the coordinator:
1. Speaks a canned acknowledgment ("Checking that now.")
2. Spawns a background agent with the restricted tool allowlist
3. The background agent's tool calls trigger approval via `ApprovalTool`
4. Results are spoken via TTS after the background agent completes

### End-to-end flow example

```
User: "What time is it?"
  → classify_intent() matches "what time" → ["bash"]
  → Canned ack: "Checking that now." (TTS)
  → Background agent spawned with bash access
  → Agent calls bash("date")
  → ApprovalTool intercepts → sends ToolApprovalRequest
  → Handler emits "approval.requested" → Swift shows overlay
  → Coordinator speaks: "I'd like to run a command: date. Say yes or no."
  → User: "yes" (voice) or taps Yes (button)
  → Approval resolved → bash executes → "Sun Feb 23 14:32:00 GMT 2026"
  → Background agent formats: "It's 2:32 PM on Sunday."
  → Result spoken via TTS
```

## Consequences

### Positive

- **User stays in control** — every dangerous operation requires explicit consent
- **Multi-modal approval** — voice, button, or timeout (no dead ends)
- **Non-blocking** — voice engine continues accepting new turns while background
  agent waits for approval
- **Composable** — new tools automatically get approval gating when wrapped
- **Auditable** — all approvals logged with request_id, latency, source

### Negative

- **Latency** — approval adds ~3-5s to tool execution (speaking prompt + waiting)
- **Approval fatigue** — frequent tool use may annoy users (mitigated by
  `full_no_approval` mode for trusted scenarios)
- **Small model limitations** — 1.7B model sometimes misclassifies intent or
  generates unnecessary tool calls

## Implementation files

| File | Role |
|------|------|
| `src/voice_command.rs` | Approval response parser + voice commands |
| `src/pipeline/messages.rs` | `ApprovalNotification` type |
| `src/pipeline/coordinator.rs` | State machine, queue, echo bypass |
| `src/personality.rs` | Prompt generation, canned responses |
| `src/agent/mod.rs` | `build_registry()`, `ApprovalTool` wrapping, intent classification |
| `src/host/handler.rs` | Bridge, drain, event emission |
| `src/runtime.rs` | `RuntimeEvent::ApprovalResolved` |
| `native/.../ApprovalOverlayController.swift` | Swift controller |
| `native/.../ApprovalOverlayView.swift` | SwiftUI overlay card |
| `native/.../AuxiliaryWindowManager.swift` | Panel management |
| `native/.../BackendEventRouter.swift` | Event routing |
| `native/.../HostCommandBridge.swift` | Button response bridge |

## References

- ADR-005: Self-Modification Safety Model (layer boundaries)
- `src/fae_llm/tools/approval.rs` — `ApprovalTool` wrapper implementation
- `src/agent/mod.rs:build_registry()` — tool registration by mode
