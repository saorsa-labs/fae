# Fae ACP Integration — Design Specification

> **Status**: Design — not yet implemented
> **Author**: David Irvine + Claude
> **Date**: 2026-03-14

## 1. Overview

This document specifies how Fae integrates with the [Agent Client Protocol (ACP)](https://agentclientprotocol.com) to orchestrate external coding agents — Claude Code, Codex, Gemini CLI, Copilot, and any ACP-compatible agent — as first-class tools in her pipeline.

**Core principle**: Fae is the orchestrator, not the worker. She understands the user's intent, delegates heavy coding work to specialist agents via ACP, monitors progress, and synthesises results. The local LLM handles personality, memory, and judgment; the external agent handles code.

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Fae Pipeline                             │
│                                                              │
│  User: "Refactor the memory module to use async/await"       │
│         │                                                    │
│         ▼                                                    │
│  LLM decides: this needs a coding agent                      │
│         │                                                    │
│         ▼                                                    │
│  Tool call: agent_session(action: "start",                   │
│             agent: "claude", prompt: "Refactor...")           │
│         │                                                    │
│         ▼                                                    │
│  ┌──────────────────────────────────────┐                    │
│  │  ACPSessionManager (actor)            │                   │
│  │                                       │                   │
│  │  Spawns: acpx claude "Refactor..."    │                   │
│  │    ↕ stdio (JSON-RPC 2.0)            │                   │
│  │  Streams: agent_message_chunk         │                   │
│  │  Approves: request_permission         │                   │
│  │  Monitors: tool_call / tool_update    │                   │
│  │  Returns: final response + diffs      │                   │
│  └──────────────────────────────────────┘                    │
│         │                                                    │
│         ▼                                                    │
│  LLM summarises result for user                              │
│  Memory captures: what was done, which agent, outcome        │
│  TTS speaks: "Done — I refactored 3 files using async/await" │
└─────────────────────────────────────────────────────────────┘
```

## 3. Components

### 3.1 Bundled `acpx` Binary

**Location**: `Fae.app/Contents/MacOS/acpx`
**Discovery**: `Bundle.main.path(forAuxiliaryExecutable: "acpx")`
**Fallback**: PATH lookup (`/usr/local/bin/acpx`, `~/.npm/bin/acpx`)
**Version pinning**: Build script downloads specific acpx release, signs alongside app

**Why bundle**: Fae can't assume Node.js is installed. Bundling acpx (a single binary via npm pkg or bun compile) ensures zero runtime dependencies. The CI release workflow already handles binary signing and notarization.

### 3.2 `ACPSessionManager` (Actor)

Central manager for all ACP sessions. One actor, multiple concurrent sessions.

```swift
actor ACPSessionManager {
    /// Active sessions keyed by session label
    private var sessions: [String: ACPSession] = [:]

    /// Start a new session with an agent
    func startSession(
        agent: String,           // "claude", "codex", "gemini", or custom command
        cwd: String,             // working directory
        name: String? = nil,     // optional named session
        approvalPolicy: ApprovalPolicy = .approveReads
    ) async throws -> String     // returns sessionId

    /// Send a prompt to an existing session
    func prompt(
        sessionId: String,
        text: String,
        attachments: [ContentBlock] = []
    ) async throws -> ACPResponse

    /// Check session status
    func status(sessionId: String) -> SessionStatus

    /// Cancel the current turn
    func cancel(sessionId: String) async

    /// Close a session (soft-close, preserves history)
    func close(sessionId: String) async

    /// List all active sessions
    func activeSessions() -> [SessionInfo]
}
```

### 3.3 `ACPSession` (Per-Session State)

```swift
struct ACPSession {
    let id: String
    let agent: String
    let cwd: String
    let name: String?
    let createdAt: Date
    var lastActivityAt: Date
    var status: SessionStatus        // .idle, .prompting, .streaming, .awaitingApproval, .closed
    var process: Process?            // acpx child process
    var turnCount: Int = 0
    var toolCallsThisTurn: [ToolCallInfo] = []
    var lastResponse: String?
}

enum SessionStatus {
    case idle
    case prompting
    case streaming(tokensReceived: Int)
    case awaitingApproval(toolName: String, description: String)
    case completed(stopReason: String)
    case failed(error: String)
    case closed
}
```

### 3.4 `AgentSessionTool` (LLM-Facing Tool)

A single tool with multiple actions, following the pattern of existing Fae tools.

```swift
final class AgentSessionTool: Tool, @unchecked Sendable {
    let name = "agent_session"
    let description = "Delegate tasks to external AI coding agents (Claude Code, Codex, Gemini, etc.)"
    let riskLevel: ToolRiskLevel = .high
    let requiresApproval = true

    let parametersSchema = """
    {
        "action": {
            "type": "string",
            "enum": ["start", "prompt", "status", "cancel", "close", "list"],
            "description": "Session action",
            "required": true
        },
        "agent": {
            "type": "string",
            "description": "Agent name: claude, codex, gemini, copilot, or custom command",
            "required": false
        },
        "prompt": {
            "type": "string",
            "description": "Task description or follow-up prompt",
            "required": false
        },
        "session_id": {
            "type": "string",
            "description": "Session ID for follow-up actions",
            "required": false
        },
        "cwd": {
            "type": "string",
            "description": "Working directory (defaults to current project)",
            "required": false
        },
        "approval_policy": {
            "type": "string",
            "enum": ["approve_all", "approve_reads", "deny_all"],
            "description": "How to handle agent tool permissions (default: approve_reads)",
            "required": false
        }
    }
    """
}
```

**Actions:**

| Action | Parameters | Returns | Use Case |
|--------|-----------|---------|----------|
| `start` | `agent`, `prompt`, `cwd?`, `approval_policy?` | Session ID + initial response | Start a new coding task |
| `prompt` | `session_id`, `prompt` | Agent response | Follow-up in existing session |
| `status` | `session_id` | Session status + turn count | Check progress |
| `cancel` | `session_id` | Confirmation | Abort current turn |
| `close` | `session_id` | Confirmation | End session (preserves history) |
| `list` | — | Active sessions | See what's running |

### 3.5 `AgentDelegateTool` (Simplified One-Shot)

For simple tasks that don't need session management:

```swift
final class AgentDelegateTool: Tool, @unchecked Sendable {
    let name = "agent_delegate"
    let description = "Send a one-shot task to an AI coding agent and get the result"
    let riskLevel: ToolRiskLevel = .high
    let requiresApproval = true

    // Uses acpx exec (no persistent session)
    // Blocks until complete, returns result
}
```

## 4. Process Management

### 4.1 acpx Invocation

```bash
# Start session + send prompt (interactive, persistent)
acpx claude --cwd /path/to/project -s fae-task-1 --format json --approve-reads "Refactor memory module"

# One-shot execution (no session persistence)
acpx claude exec --cwd /path/to/project --format json --approve-reads "Fix the build error in FaeConfig.swift"

# Follow-up prompt in existing session
acpx claude -s fae-task-1 --format json "Now add tests for the changes"

# Check status
acpx claude -s fae-task-1 status

# Cancel current turn
acpx claude -s fae-task-1 cancel
```

### 4.2 Output Parsing (JSON mode)

acpx with `--format json` outputs NDJSON events:

```json
{"eventVersion":1,"sessionId":"abc123","type":"agent_message_chunk","text":"I'll refactor..."}
{"eventVersion":1,"sessionId":"abc123","type":"tool_call","toolName":"edit","status":"pending"}
{"eventVersion":1,"sessionId":"abc123","type":"tool_call_update","toolName":"edit","status":"completed"}
{"eventVersion":1,"sessionId":"abc123","type":"agent_message_chunk","text":"Done. I changed 3 files."}
{"eventVersion":1,"sessionId":"abc123","type":"prompt_complete","stopReason":"end_turn"}
```

Fae parses these events via the same NDJSON pattern used by `WorkerLLMEngine`:
- Spawn `Process` with pipes
- Read stdout line-by-line
- Decode each line as `ACPEvent`
- Route to appropriate handler (stream text, track tools, handle completion)

### 4.3 Timeouts

| Phase | Timeout | Rationale |
|-------|---------|-----------|
| Session start (`initialize` + `session/new`) | 30s | Network + auth |
| First response token | 120s | Model loading, cold start |
| Inter-token silence | 30s | Active streaming |
| Total prompt turn | 15min | Complex multi-tool tasks |
| Idle session (no prompts) | 30min | Resource cleanup |

### 4.4 Crash Recovery

Following `WorkerLLMEngine` patterns:
- `process.terminationHandler` detects death
- Sweep all pending continuations with error
- Sessions marked `.failed` but not deleted (history preserved on disk by acpx)
- User can resume: `agent_session(action: "prompt", session_id: "...", prompt: "continue")`
- acpx handles session reload transparently via `session/load`

## 5. Security

### 5.1 Tool Risk & Broker Integration

```swift
// TrustedActionBroker registration
schedulerTaskAllowlists["acp_session_monitor"] = ["agent_session", "activate_skill"]

// Risk levels
agent_session(action: "start")   → .high, requiresApproval: true
agent_session(action: "prompt")  → .medium (existing session)
agent_session(action: "status")  → .low
agent_session(action: "cancel")  → .low
agent_session(action: "close")   → .low
agent_session(action: "list")    → .low
agent_delegate                   → .high, requiresApproval: true
```

### 5.2 Approval Policies

Fae controls what the external agent can do via acpx `--approve-*` flags:

| Policy | Flag | Use Case |
|--------|------|----------|
| `approve_reads` | `--approve-reads` | Default — agent can read files, user approves writes |
| `approve_all` | `--approve-all` | Trusted tasks (user explicitly requested) |
| `deny_all` | `--deny-all` | Observation only — agent can think but not act |

### 5.3 DamageControlPolicy Integration

ACP sessions pass through layer-0 damage control:
- Agent can't execute `rm -rf /` (Fae's bash tool blocks it, and acpx's own approval gate blocks it)
- Credential paths blocked for non-local sessions
- The external agent's file writes go through acpx's permission system, not Fae's PathPolicy

### 5.4 Network Policy

- ACP agents may make network requests (e.g., Claude Code calls Anthropic API)
- This is expected and acceptable — the user chose to use that agent
- Fae's `NetworkTargetPolicy` doesn't gate acpx subprocess network (it's a child process, not a Fae tool call)
- Privacy mode `strict_local` should block `agent_session` tool entirely (agent requires network)

## 6. Scheduler Integration

### 6.1 Background Agent Tasks

Fae can use ACP sessions for proactive work:

```swift
// Scheduler task: run overnight code maintenance
schedulerTaskAllowlists["acp_overnight_maintenance"] = ["agent_session", "activate_skill"]

// Proactive query:
"Use agent_session to start a Claude Code session in the user's project.
Ask it to run the test suite and fix any failures. Report findings to memory."
```

### 6.2 Session Health Monitor

A scheduler task (every 5min) checks active ACP sessions:
- Detect dead processes
- Clean up sessions idle > 30min
- Report session count in diagnostics

## 7. Memory Integration

When an ACP session completes, Fae captures:

```swift
// Memory record for completed agent task
MemoryRecord(
    kind: .fact,
    content: "Used Claude Code to refactor memory module to async/await. Changed 3 files: MemoryOrchestrator.swift, SQLiteMemoryStore.swift, VectorStore.swift.",
    tags: ["agent_session", "claude", "refactor"],
    confidence: 0.75
)
```

This lets Fae remember:
- What tasks were delegated and to which agent
- What the outcome was
- Which files were modified
- Whether the user was satisfied with the result

## 8. Extensibility Points

### 8.1 Custom Agent Registration

Users can register custom ACP agents via config or directive:

```toml
[agents]
my-local-agent = { command = "./bin/my-acp-server", approval = "approve-all" }
```

Or via Fae conversation:
- "Fae, register a new agent called 'my-agent' that runs './bin/my-acp-server'"
- Stored in config.toml under `[agents]`

### 8.2 Agent Selection Intelligence

As Fae learns which agents work best for which tasks, she can develop preferences:

- "Last time I used Codex for Python refactoring and it worked well" (memory)
- "Claude Code is better for complex multi-file changes" (learned)
- "Gemini CLI is fastest for simple fixes" (observed)

This emerges naturally from memory capture — no special code needed.

### 8.3 Skill-Based Agent Workflows

New skills can compose agent sessions:

```markdown
---
name: code-review
description: Run a multi-agent code review
---

# Code Review Skill

1. Start a Claude Code session to review the changes
2. Start a Codex session independently to review the same changes
3. Compare their findings
4. Synthesise a combined review
```

### 8.4 Mesh Integration

Forge-built tools could be ACP agents themselves:
- Forge creates a Zig binary that speaks ACP
- Published via Mesh to other Fae instances
- Other Fae instances register it as a custom agent

## 9. Implementation Plan

### Phase 1: Foundation (Bundle + Manager + Tool)

| Task | Files | Effort |
|------|-------|--------|
| Bundle acpx binary in Fae.app | `justfile`, CI workflow | Small |
| `ACPSessionManager` actor | `Tools/ACPSessionManager.swift` (new) | Medium |
| `ACPEvent` parser (NDJSON) | `Tools/ACPProtocol.swift` (new) | Small |
| `AgentSessionTool` | `Tools/AgentSessionTool.swift` (new) | Medium |
| `AgentDelegateTool` (one-shot) | `Tools/AgentDelegateTool.swift` (new) | Small |
| Register in `ToolRegistry.buildDefault()` | `Tools/ToolRegistry.swift` | Small |
| TrustedActionBroker rules | `Tools/TrustedActionBroker.swift` | Small |
| Privacy mode gate (block in strict_local) | `Tools/ToolRegistry.swift` | Small |

### Phase 2: Intelligence (Memory + Scheduler)

| Task | Files | Effort |
|------|-------|--------|
| Memory capture for agent task outcomes | `Memory/MemoryOrchestrator.swift` | Small |
| Session health monitor scheduler task | `Scheduler/FaeScheduler.swift` | Small |
| Diagnostics tab: active sessions | `SettingsDiagnosticsTab.swift` | Small |
| Proactive agent task support | `Scheduler/FaeScheduler.swift` | Medium |

### Phase 3: Extensibility (Config + Skills)

| Task | Files | Effort |
|------|-------|--------|
| Custom agent registration in config.toml | `Core/FaeConfig.swift` | Small |
| `self_config` key for agent management | `Tools/BuiltinTools.swift` | Small |
| Multi-agent skill template | `Resources/Skills/code-review/` | Medium |
| Agent preference learning (via memory) | Automatic — no code needed | — |

## 10. What This Enables

**Day 1 (Phase 1):**
- "Fae, use Claude Code to fix the build errors in this project"
- "Fae, ask Codex to write tests for the new UserService class"
- "Fae, delegate this refactoring to Gemini"

**Week 2 (Phase 2):**
- "Fae, run the test suite overnight with Claude Code and fix any failures"
- "Fae, have Codex review my PR while I sleep"
- Fae remembers which agents worked best for which tasks

**Month 2 (Phase 3):**
- Multi-agent code review (Claude + Codex independently, Fae synthesises)
- User registers their own ACP agent, Fae uses it naturally
- Forge-built ACP agents shared via Mesh

**The key insight**: Fae doesn't need to be the best coder. She needs to be the best at understanding what the user wants and routing it to the right specialist. ACP makes every coding agent in the ecosystem available as a Fae tool.
