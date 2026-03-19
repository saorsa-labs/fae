# Phase 3: Tools & Agent System — Fae Takes Action

## Your Mission

Give Fae the ability to execute tools — bash commands, file I/O, web search, Apple ecosystem (calendar, contacts, reminders), and Python skills. Implement the agent loop (LLM → tool call → execute → loop) and the approval system for dangerous tools.

**Deliverable**: Say "What time is it?" → bash tool fires → approval overlay appears → approve → spoken answer.

---

## Prerequisites (completed by Phases 0–2)

- Pure Swift app with working voice pipeline (speak → hear response)
- Memory system (recall before LLM, capture after turn)
- `FaeCore`, `FaeEventBus`, `PipelineCoordinator`, `MemoryOrchestrator` functional
- `IntentClassifier` routes tool-needing queries to background agent
- `PersonalityManager` assembles prompts including `BACKGROUND_AGENT_PROMPT`

---

## Context

### How Tools Work in Fae

Fae has a dual-channel architecture:
1. **Voice channel** — fast, no tools, direct LLM response for conversational queries
2. **Background channel** — tools enabled, async, for queries that need action

When the user says something like "what time is it?", the `IntentClassifier` detects tool need (`bash`), plays a canned acknowledgment ("Let me check that"), and spawns a background agent with tools. The agent loop runs: LLM generates → requests tool call → tool executes (with approval if dangerous) → result fed back to LLM → final response spoken.

### Approval System

In `full` tool mode (default), dangerous tools (bash, write, edit, python_skill, desktop_automation) are gated by user approval. The flow:
1. Agent requests tool execution
2. `ApprovalManager` sends `.approvalRequested` event → existing `ApprovalOverlayView.swift` shows floating card
3. User clicks Yes/No button, presses Enter/Escape, or speaks "yes"/"no"
4. 58-second auto-deny timeout
5. Tool executes or is denied

The Swift UI for approval already exists (`ApprovalOverlayController.swift`, `ApprovalOverlayView.swift`). You just need to send the right events and handle responses.

### Rust Source Files to Read

| File | Lines | What to port |
|------|-------|-------------|
| `src/fae_llm/agent/loop_engine.rs` | ~2,000 | Agent loop: generate → parse → execute → loop |
| `src/fae_llm/agent/executor.rs` | ~2,000 | Tool execution, timeout, error handling |
| `src/fae_llm/agent/accumulator.rs` | ~2,000 | Streaming token accumulator, tool call JSON parsing |
| `src/agent/mod.rs` | ~500 | Tool registry, ApprovalTool wrapper, build_registry() |
| `src/voice_command.rs` | ~200 | parse_approval_response(), parse_voice_command() |
| `src/tools/read.rs` | ~100 | ReadTool |
| `src/tools/write.rs` | ~100 | WriteTool |
| `src/tools/edit.rs` | ~200 | EditTool |
| `src/tools/bash.rs` | ~150 | BashTool |
| `src/tools/web_search.rs` | ~200 | WebSearchTool |
| `src/tools/fetch_url.rs` | ~150 | FetchURLTool |
| `src/tools/apple/calendar.rs` | ~300 | CalendarTool (Rust uses AppleScript — you'll use EventKit) |
| `src/tools/apple/contacts.rs` | ~200 | ContactsTool (Rust uses AppleScript — you'll use Contacts.framework) |
| `src/tools/apple/reminders.rs` | ~200 | RemindersTool (Rust uses AppleScript — you'll use EventKit) |
| `src/tools/apple/mail.rs` | ~150 | MailTool (keep AppleScript bridge) |
| `src/tools/apple/notes.rs` | ~150 | NotesTool (keep AppleScript bridge) |

---

## Tasks

### 3.1 — Tool Protocol & Registry

**`Sources/Fae/Tools/Tool.swift`**:

```swift
import Foundation

protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersSchema: ToolParametersSchema { get }
    var requiresApproval: Bool { get }
    func execute(input: [String: Any]) async throws -> ToolResult
}

struct ToolResult: Sendable {
    let content: String
    let isError: Bool

    static func success(_ content: String) -> ToolResult {
        ToolResult(content: content, isError: false)
    }

    static func error(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: true)
    }
}

struct ToolParametersSchema: Sendable {
    let properties: [String: ToolParameter]
    let required: [String]
}

struct ToolParameter: Sendable {
    let type: String  // "string", "integer", "boolean", "array"
    let description: String
    let enumValues: [String]?  // for enum-type parameters
}
```

**`Sources/Fae/Tools/ToolRegistry.swift`**:

```swift
actor ToolRegistry {
    private var tools: [String: any Tool] = [:]

    func register(_ tool: any Tool) {
        tools[tool.name] = tool
    }

    func get(_ name: String) -> (any Tool)? {
        tools[name]
    }

    func all() -> [any Tool] {
        Array(tools.values)
    }

    /// Build the full registry based on permissions
    func buildRegistry(permissions: PermissionStore) {
        // Always available
        register(ReadTool())

        // Gated by tool mode
        if permissions.toolMode != "off" && permissions.toolMode != "read_only" {
            register(WriteTool())
            register(EditTool())
            register(BashTool())
            register(WebSearchTool())
            register(FetchURLTool())
        }

        // Apple tools — gated by individual permission
        if permissions.isEnabled("calendar") { register(CalendarTool()) }
        if permissions.isEnabled("contacts") { register(ContactsTool()) }
        if permissions.isEnabled("reminders") { register(RemindersTool()) }
        if permissions.isEnabled("mail") { register(MailTool()) }
        if permissions.isEnabled("notes") { register(NotesTool()) }
        if permissions.isEnabled("desktop_automation") { register(DesktopTool()) }
    }

    /// Generate tool schemas for LLM prompt injection
    func toolSchemasJSON() -> String {
        // Format all registered tools as JSON schema for the LLM to understand
    }
}
```

### 3.2 — Built-in Tools

Create `Sources/Fae/Tools/` directory with one file per tool:

**`ReadTool.swift`** — `requiresApproval: false`:
```swift
struct ReadTool: Tool {
    let name = "read"
    let description = "Read contents of a file"
    let requiresApproval = false
    // Parameters: path (string, required), offset (int, optional), limit (int, optional)
    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let path = input["path"] as? String else { return .error("Missing path") }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return .success(content)
    }
}
```

**`WriteTool.swift`** — `requiresApproval: true`:
```swift
struct WriteTool: Tool {
    let name = "write"
    let requiresApproval = true
    // Parameters: path (string), content (string)
    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let path = input["path"] as? String,
              let content = input["content"] as? String else { return .error("Missing params") }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return .success("Written to \(path)")
    }
}
```

**`EditTool.swift`** — `requiresApproval: true`:
- Parameters: path, old_string, new_string
- Read file, replace first occurrence of old_string with new_string, write back

**`BashTool.swift`** — `requiresApproval: true`:
```swift
struct BashTool: Tool {
    let name = "bash"
    let requiresApproval = true
    // Parameters: command (string), timeout_ms (int, optional, default 30000)
    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let command = input["command"] as? String else { return .error("Missing command") }
        let timeout = input["timeout_ms"] as? Int ?? 30000

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Timeout handling via Task.sleep + process.terminate()
        // Capture stdout + stderr
        // Return output
    }
}
```

**`WebSearchTool.swift`** — `requiresApproval: false`:
- Use URLSession to hit a search API (DuckDuckGo HTML API or similar)
- Parse results, return top N

**`FetchURLTool.swift`** — `requiresApproval: false`:
- URLSession GET request
- Return body text (strip HTML tags for readability)
- Timeout: 15s

**`CalendarTool.swift`** — `requiresApproval: false` (read) / `true` (create/delete):
```swift
import EventKit

struct CalendarTool: Tool {
    let name = "calendar"
    // Actions: list_events, create_event, delete_event
    // Much simpler than the Rust version which used AppleScript!
    private let store = EKEventStore()

    func execute(input: [String: Any]) async throws -> ToolResult {
        let action = input["action"] as? String ?? "list_events"
        switch action {
        case "list_events":
            // EKEventStore predicateForEvents
        case "create_event":
            // EKEvent creation
        default:
            return .error("Unknown action")
        }
    }
}
```

**`ContactsTool.swift`** — native Contacts.framework (replaces AppleScript):
```swift
import Contacts

struct ContactsTool: Tool {
    let name = "contacts"
    private let store = CNContactStore()
    // Actions: search_contacts, get_contact, create_contact
}
```

**`RemindersTool.swift`** — native EventKit:
```swift
import EventKit

struct RemindersTool: Tool {
    let name = "reminders"
    private let store = EKEventStore()
    // Actions: list_reminders, create_reminder, complete_reminder
}
```

**`MailTool.swift`** — AppleScript bridge (Mail.app has no public framework):
- Use `NSAppleScript` or `Process` running `osascript`

**`NotesTool.swift`** — AppleScript bridge:
- Same approach as MailTool

**`DesktopTool.swift`** — `requiresApproval: true`:
- Screenshots via `CGWindowListCreateImage`
- Window list via `CGWindowListCopyWindowInfo`
- Mouse/keyboard events via `CGEvent`

**`PythonSkillTool.swift`** — `requiresApproval: true`:
- Launch Python subprocess via `Process`
- JSON-RPC communication over stdin/stdout
- Health check, timeout handling

**`SchedulerTools.swift`** — `requiresApproval: false`:
- list_tasks, create_task, update_task, delete_task, trigger_task
- Direct calls to `FaeScheduler` (implemented in Phase 4, stub for now)

**`X0XTool.swift`** — `requiresApproval: false`:
- HTTP client to x0xd at `http://127.0.0.1:12700`
- Actions: list_contacts, add_contact, trust_contact, block_contact, send_message, etc.

### 3.3 — Agent Loop

**`Sources/Fae/Agent/AgentLoop.swift`**

This is the core tool execution engine. Port from `src/fae_llm/agent/` (6,072 lines total).

```swift
actor AgentLoop {
    private let llm: any LLMEngine
    private let tools: ToolRegistry
    private let approvalManager: ApprovalManager
    private let personality: PersonalityManager
    private let eventBus: FaeEventBus

    /// Run the agent loop: generate → parse tool calls → execute → feed back → loop
    func run(
        messages: [ChatMessage],
        systemPrompt: String
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var conversationMessages = messages
                var turnCount = 0
                let maxTurns = 10

                while turnCount < maxTurns {
                    turnCount += 1

                    // 1. Generate LLM response (streaming)
                    var fullResponse = ""
                    for try await token in llm.generate(
                        messages: conversationMessages,
                        systemPrompt: systemPrompt,
                        options: GenerationOptions()
                    ) {
                        fullResponse += token
                        continuation.yield(.token(token))
                    }

                    // 2. Parse for tool calls in the response
                    let toolCalls = parseToolCalls(from: fullResponse)

                    if toolCalls.isEmpty {
                        // No tool calls — final response
                        continuation.yield(.finalResponse(fullResponse))
                        break
                    }

                    // 3. Execute each tool call
                    conversationMessages.append(ChatMessage(role: .assistant, content: fullResponse))

                    for call in toolCalls {
                        let result = try await executeTool(call)
                        conversationMessages.append(ChatMessage(
                            role: .tool,
                            content: result.content,
                            toolCallID: call.id,
                            name: call.toolName
                        ))
                        continuation.yield(.toolResult(name: call.toolName, result: result))
                    }

                    // Loop: LLM will see tool results and generate next response
                }

                continuation.finish()
            }
        }
    }

    private func executeTool(_ call: ToolCall) async throws -> ToolResult {
        guard let tool = await tools.get(call.toolName) else {
            return .error("Unknown tool: \(call.toolName)")
        }

        // Check approval if required
        if tool.requiresApproval {
            let approved = await approvalManager.requestApproval(
                toolName: call.toolName,
                inputJSON: call.inputJSON
            )
            if !approved {
                return .error("Tool execution denied by user")
            }
        }

        // Execute with timeout (30s)
        return try await withThrowingTaskGroup(of: ToolResult.self) { group in
            group.addTask { try await tool.execute(input: call.input) }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return .error("Tool execution timed out after 30s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

enum AgentEvent: Sendable {
    case token(String)
    case toolResult(name: String, result: ToolResult)
    case finalResponse(String)
}

struct ToolCall {
    let id: String
    let toolName: String
    let input: [String: Any]
    let inputJSON: String  // raw JSON for display in approval UI
}
```

**Tool call parsing** — The LLM outputs tool calls in a specific format. Port the parsing logic from `src/fae_llm/agent/accumulator.rs`. Common formats:

```json
<tool_call>
{"name": "bash", "arguments": {"command": "date"}}
</tool_call>
```

Or Qwen-style function calling format. Read the mlx-swift-lm docs to understand what format Qwen3 models use for tool calling.

**Key behaviors to port**:
- Max 10 turns per agent run
- Max 5 tool calls per turn
- 30s timeout per tool execution
- Duplicate response detection (if LLM repeats the same text, stop)
- Per-turn tool allowlist selection (only offer relevant tools based on context)
- Streaming: emit tokens as they arrive for TTS pipelining

### 3.4 — Approval Manager

**`Sources/Fae/Agent/ApprovalManager.swift`**:

```swift
actor ApprovalManager {
    private let eventBus: FaeEventBus
    private var pendingApprovals: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    private var nextID: UInt64 = 0

    init(eventBus: FaeEventBus) {
        self.eventBus = eventBus
    }

    /// Request approval from user. Blocks until approved/denied/timeout.
    func requestApproval(toolName: String, inputJSON: String) async -> Bool {
        let id = nextID
        nextID += 1

        // Send event → ApprovalOverlayView shows
        eventBus.send(.approvalRequested(id: id, toolName: toolName, input: inputJSON))

        // Wait for response with 58s timeout
        return await withCheckedContinuation { continuation in
            pendingApprovals[id] = continuation

            // Auto-deny after 58s
            Task {
                try? await Task.sleep(nanoseconds: 58_000_000_000)
                if let pending = pendingApprovals.removeValue(forKey: id) {
                    pending.resume(returning: false)
                    eventBus.send(.approvalResolved(id: id, approved: false))
                }
            }
        }
    }

    /// Called by FaeCore when user responds (button click or voice)
    func resolve(id: UInt64, approved: Bool) {
        if let continuation = pendingApprovals.removeValue(forKey: id) {
            continuation.resume(returning: approved)
        }
    }
}
```

**Wire into FaeCore**:
```swift
// In FaeCore:
func respondToApproval(requestID: UInt64, approved: Bool) {
    Task { await approvalManager.resolve(id: requestID, approved: approved) }
    eventBus.send(.approvalResolved(id: requestID, approved: approved))
}
```

The existing `ApprovalOverlayController.swift` observes `.faeApprovalRequested` and shows the overlay. It posts `.faeApprovalRespond` when the user clicks. Wire that notification to `faeCore.respondToApproval()`.

### 3.5 — Voice Command Parser

**`Sources/Fae/Core/VoiceCommandParser.swift`**:

Port from `src/voice_command.rs`:

```swift
struct VoiceCommandParser {
    /// Parse yes/no from spoken text (for approval responses)
    static func parseApprovalResponse(_ text: String) -> Bool? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let yesPatterns = ["yes", "yeah", "yep", "yup", "sure", "go ahead", "do it",
                           "approved", "okay", "ok", "affirmative", "proceed"]
        let noPatterns = ["no", "nah", "nope", "don't", "stop", "cancel", "deny",
                          "denied", "negative", "abort"]

        for pattern in yesPatterns {
            if lower.contains(pattern) { return true }
        }
        for pattern in noPatterns {
            if lower.contains(pattern) { return false }
        }
        return nil  // couldn't determine
    }

    /// Parse voice commands (show conversation, switch model, etc.)
    static func parseVoiceCommand(_ text: String) -> VoiceCommand? {
        let lower = text.lowercased()
        if lower.contains("show conversation") || lower.contains("open conversation") {
            return .showConversation
        }
        if lower.contains("hide conversation") || lower.contains("close conversation") {
            return .hideConversation
        }
        if lower.contains("show canvas") || lower.contains("open canvas") {
            return .showCanvas
        }
        // ... more commands
        return nil
    }
}

enum VoiceCommand {
    case showConversation, hideConversation
    case showCanvas, hideCanvas
    case goToSleep, wakeUp
    case switchModel(String)
}
```

### 3.6 — Wire Background Agent into Pipeline

Update `PipelineCoordinator` to use the agent for tool-needing queries:

```swift
// In PipelineCoordinator, after STT transcription:
let intent = IntentClassifier.classifyIntent(transcription.text)

if intent.needsTools {
    // Play acknowledgment
    let ack = personality.randomToolAcknowledgment()
    // Synthesize and play ack via TTS

    // Spawn background agent
    let agentPrompt = personality.backgroundAgentPrompt()
    let messages = [ChatMessage(role: .user, content: transcription.text)]

    Task {
        for try await event in agentLoop.run(messages: messages, systemPrompt: agentPrompt) {
            switch event {
            case .finalResponse(let text):
                // Sentence-chunk and TTS the response
                // Play to user
            case .toolResult(let name, let result):
                // Log tool execution
            case .token:
                break  // Accumulate for sentence chunking
            }
        }
    }
} else {
    // Direct voice LLM response (existing flow)
}
```

---

## Verification

1. Build: `swift build` — zero errors
2. Say "What time is it?"
   - Intent classifier detects bash tool need
   - Canned ack plays: "Let me check that"
   - Approval overlay appears: "I'd like to run: `date`. Approve?"
   - Click Yes or say "yes"
   - Fae speaks the current time
3. Say "Search for weather in Edinburgh"
   - Web search tool fires (no approval needed)
   - Fae speaks weather summary
4. Say "Read my calendar for today"
   - Calendar tool fires (EventKit)
   - Fae speaks today's events
5. Say "Write hello to /tmp/test.txt"
   - Write tool fires
   - Approval overlay appears
   - Approve → file created
   - Deny → "Tool execution denied"
6. Approval auto-deny: don't respond for 58s → tool is denied

---

## Do NOT Do

- Do NOT implement the scheduler (Phase 4)
- Do NOT implement Python skills manager fully (stub is fine — Phase 4)
- Do NOT implement channel integrations (Phase 4)
- Do NOT change the voice pipeline's direct-response path
- Do NOT change the approval overlay UI (it already exists)
