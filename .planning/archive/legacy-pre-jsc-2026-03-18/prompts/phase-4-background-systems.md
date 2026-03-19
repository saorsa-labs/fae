# Phase 4: Background Systems — Full Feature Parity

## Your Mission

Implement all background systems that make Fae a complete assistant: scheduler (11 tasks), Python skill manager, channel integrations (Discord/WhatsApp), intelligence features (morning briefing, noise budget), canvas rendering, credentials, x0x network listener, and diagnostics.

**Deliverable**: All 11 scheduler tasks run on schedule. Python skills execute. Channels receive messages. Full parity with the Rust implementation.

---

## Prerequisites (completed by Phases 0–3)

- Pure Swift app with working voice pipeline
- Memory system with recall/capture
- Tool system with 15+ tools, agent loop, and approval
- `FaeCore`, `FaeEventBus`, `PipelineCoordinator`, `MemoryOrchestrator`, `AgentLoop`, `ToolRegistry` all functional

---

## Rust Source Files to Read

| File / Directory | Lines | What to port |
|-----------------|-------|-------------|
| `src/scheduler/runner.rs` | ~1,800 | Scheduler loop, timer management |
| `src/scheduler/tasks.rs` | ~1,800 | 11 built-in task definitions |
| `src/skills/` (directory) | 10,593 | Skill manager, Python subprocess, JSON-RPC, PEP 723 |
| `src/channels/` (directory) | 1,736 | Discord/WhatsApp integration |
| `src/intelligence/` (directory) | 3,842 | Morning briefing, skill proposals, noise budget |
| `src/canvas/` (directory) | 3,748 | Canvas scene graph, HTML rendering |
| `src/credentials/` (directory) | 1,640 | Keychain credential storage |
| `src/x0x_listener.rs` | ~200 | SSE listener for x0x network |
| `src/diagnostics/` (directory) | ~2,000 | Health checks, log rotation |

---

## Tasks

### 4.1 — Scheduler

**`Sources/Fae/Scheduler/FaeScheduler.swift`**

Port from `src/scheduler/{runner.rs, tasks.rs}` (3,611 lines).

```swift
import Foundation

actor FaeScheduler {
    private var timers: [String: DispatchSourceTimer] = [:]
    private var tasks: [String: ScheduledTask] = [:]
    private let memoryOrchestrator: MemoryOrchestrator
    private let eventBus: FaeEventBus

    func start() {
        registerBuiltinTasks()
        for (name, task) in tasks {
            scheduleTask(name: name, task: task)
        }
    }

    func stop() {
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
    }

    private func registerBuiltinTasks() {
        // All 11 built-in tasks:
        register(MemoryBackupTask())       // daily 02:00
        register(MemoryGCTask())           // daily 03:30
        register(MemoryReflectTask())      // every 6h
        register(MemoryReindexTask())      // every 3h
        register(MemoryMigrateTask())      // every 1h
        register(NoiseBudgetResetTask())   // daily 00:00
        register(MorningBriefingTask())    // daily 08:00
        register(SkillProposalsTask())     // daily 11:00
        register(StaleRelationshipsTask()) // every 7d
        register(CheckFaeUpdateTask())     // every 6h
        register(SkillHealthCheckTask())   // every 5min
    }

    private func scheduleTask(name: String, task: ScheduledTask) {
        let timer = DispatchSource.makeTimerSource(queue: .global())

        switch task.schedule {
        case .interval(let seconds):
            timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
        case .daily(let hour, let minute):
            // Calculate next occurrence using Calendar
            let next = nextOccurrence(hour: hour, minute: minute)
            let interval = next.timeIntervalSinceNow
            timer.schedule(deadline: .now() + .seconds(Int(interval)), repeating: .seconds(86400))
        }

        timer.setEventHandler { [weak self] in
            Task { try? await self?.runTask(name: name) }
        }
        timer.resume()
        timers[name] = timer
    }

    // MARK: - Scheduler tool interface (for SchedulerTools)

    func listTasks() -> [TaskInfo] { /* return all registered tasks with next run time */ }
    func createTask(name: String, schedule: TaskSchedule, action: String) { /* user-created tasks */ }
    func updateTask(name: String, schedule: TaskSchedule?) { /* modify schedule */ }
    func deleteTask(name: String) { /* remove user task (cannot delete builtins) */ }
    func triggerTask(name: String) async throws { try await runTask(name: name) }
}

protocol ScheduledTask {
    var name: String { get }
    var schedule: TaskSchedule { get }
    func run(context: TaskContext) async throws
}

enum TaskSchedule {
    case interval(seconds: Int)
    case daily(hour: Int, minute: Int)
}

struct TaskContext {
    let memoryOrchestrator: MemoryOrchestrator
    let eventBus: FaeEventBus
    // Add other dependencies as needed
}
```

**Built-in task implementations** (each is a struct conforming to `ScheduledTask`):

| Task | Schedule | Implementation |
|------|----------|---------------|
| `MemoryBackupTask` | daily 02:00 | Call `MemoryBackup.backup()` |
| `MemoryGCTask` | daily 03:30 | Call `memoryOrchestrator.garbageCollect()` |
| `MemoryReflectTask` | every 6h (21600s) | Call `memoryOrchestrator.reflect()` |
| `MemoryReindexTask` | every 3h (10800s) | `PRAGMA quick_check` + re-embed any memories missing embeddings |
| `MemoryMigrateTask` | every 1h (3600s) | Check schema version, run migrations if needed |
| `NoiseBudgetResetTask` | daily 00:00 | Reset proactive message counter to 0 |
| `MorningBriefingTask` | daily 08:00 | Generate briefing from calendar + memory + weather |
| `SkillProposalsTask` | daily 11:00 | Analyze recent conversations for skill opportunities |
| `StaleRelationshipsTask` | every 7d (604800s) | Check contacts not interacted with recently |
| `CheckFaeUpdateTask` | every 6h (21600s) | Check GitHub releases or Sparkle for updates |
| `SkillHealthCheckTask` | every 5min (300s) | Ping running Python skill subprocesses |

### 4.2 — Skills Manager

**`Sources/Fae/Skills/SkillManager.swift`**

Port from `src/skills/` (10,593 lines). This is the most complex port in Phase 4.

```swift
actor SkillManager {
    private var runningSkills: [String: SkillProcess] = [:]
    private let skillsDir: URL  // ~/Library/Application Support/fae/skills/

    // MARK: - Lifecycle

    func loadSkill(path: URL) async throws -> SkillManifest {
        // 1. Parse PEP 723 metadata from .py file header
        // 2. Validate manifest (name, version, permissions)
        // 3. Bootstrap Python environment with uv if needed
        // 4. Return manifest for review
    }

    func startSkill(name: String) async throws {
        // 1. Find skill .py file
        // 2. Launch Python subprocess via Process
        // 3. Establish JSON-RPC communication over stdin/stdout
        // 4. Send initialize request
        // 5. Register skill's tools in ToolRegistry
    }

    func stopSkill(name: String) async {
        guard let process = runningSkills[name] else { return }
        process.terminate()
        runningSkills.removeValue(forKey: name)
    }

    // MARK: - JSON-RPC

    func callSkill(name: String, method: String, params: [String: Any]) async throws -> Any {
        guard let process = runningSkills[name] else {
            throw SkillError.notRunning(name)
        }
        return try await process.sendRequest(method: method, params: params)
    }

    // MARK: - Health

    func healthCheck() async -> [String: SkillHealth] {
        // Ping each running skill, check response time
        // Restart any that have crashed
    }
}

struct SkillProcess {
    let process: Process
    let stdin: FileHandle
    let stdout: FileHandle
    var requestID: Int = 0

    func sendRequest(method: String, params: [String: Any]) async throws -> Any {
        // JSON-RPC 2.0 protocol over stdin/stdout
        // Write: {"jsonrpc": "2.0", "id": N, "method": "...", "params": {...}}
        // Read: {"jsonrpc": "2.0", "id": N, "result": ...}
    }

    func terminate() {
        process.terminate()
    }
}

struct SkillManifest: Codable {
    let name: String
    let version: String
    let description: String
    let permissions: [String]
    let tools: [SkillToolDef]
}
```

**PEP 723 parsing**: Skills are single-file Python scripts with metadata in a special comment block:
```python
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests"]
# [tool.fae]
# name = "weather"
# version = "1.0"
# description = "Get weather forecasts"
# permissions = ["web"]
# ///
```

Port the PEP 723 parser from Rust — it's regex-based string extraction.

**uv bootstrap**: If the skill has dependencies, use `uv` (Python package installer) to create a virtual environment. Check if `uv` is available at `/usr/local/bin/uv` or `~/.cargo/bin/uv`.

### 4.3 — Channel Integrations

**`Sources/Fae/Channels/ChannelManager.swift`**

Port from `src/channels/` (1,736 lines):

```swift
actor ChannelManager {
    private var discord: DiscordChannel?
    private var whatsapp: WhatsAppChannel?

    func configure(config: ChannelsConfig) {
        if config.enabled {
            if let discordConfig = config.discord, !discordConfig.botToken.isEmpty {
                discord = DiscordChannel(config: discordConfig)
            }
            if let whatsappConfig = config.whatsapp, !whatsappConfig.accessToken.isEmpty {
                whatsapp = WhatsAppChannel(config: whatsappConfig)
            }
        }
    }

    func start() async {
        await discord?.connect()
        await whatsapp?.startWebhookListener()
    }

    func stop() async {
        await discord?.disconnect()
        await whatsapp?.stopWebhookListener()
    }
}
```

**Discord**: Connect to Discord Gateway WebSocket, listen for messages in allowed channels, route to LLM, send response back.

**WhatsApp**: HTTP webhook receiver (listen on a local port), verify webhook token, route incoming messages to LLM, send response via WhatsApp Cloud API.

Both channels route messages through the same `AgentLoop` that voice uses, but with text I/O instead of audio.

### 4.4 — Intelligence

Create `Sources/Fae/Intelligence/` directory:

**`MorningBriefing.swift`**:
```swift
struct MorningBriefing {
    /// Generate morning briefing from multiple sources
    func generate(
        memory: MemoryOrchestrator,
        calendar: CalendarTool?,
        config: FaeConfig
    ) async throws -> String {
        // 1. Fetch today's calendar events
        // 2. Check recent memories for pending tasks/reminders
        // 3. Optional: weather via web search
        // 4. Format into concise spoken briefing
        // 5. Respect noise budget
    }
}
```

**`SkillProposals.swift`**:
```swift
struct SkillProposals {
    /// Analyze recent conversations for skill opportunities
    func analyze(memory: MemoryOrchestrator) async throws -> [SkillProposal] {
        // 1. Recall recent conversation turns
        // 2. Look for patterns: repeated tool use, failed lookups, frequent topics
        // 3. Suggest skills that could automate these patterns
    }
}

struct SkillProposal {
    let name: String
    let description: String
    let reason: String  // "You've asked about weather 5 times this week"
}
```

**`NoiseBudget.swift`**:
```swift
actor NoiseBudget {
    private var proactiveMessageCount: Int = 0
    private let dailyLimit: Int = 5  // configurable

    func canSendProactive() -> Bool {
        proactiveMessageCount < dailyLimit
    }

    func recordProactiveMessage() {
        proactiveMessageCount += 1
    }

    func reset() {
        proactiveMessageCount = 0
    }
}
```

### 4.5 — Canvas

**`Sources/Fae/Canvas/CanvasManager.swift`**

Port from `src/canvas/` (3,748 lines):

```swift
actor CanvasManager {
    private var scenes: [String: CanvasScene] = [:]

    /// Render a scene to HTML for display in canvas WebView
    func render(scene: CanvasScene) -> String {
        // Convert scene graph to HTML/SVG/Canvas
    }

    /// Update scene from LLM tool output
    func updateScene(id: String, operations: [CanvasOperation]) {
        // Apply operations to scene graph
    }

    /// Export scene to image/PDF
    func export(id: String, format: ExportFormat) throws -> Data { ... }
}

struct CanvasScene {
    var elements: [CanvasElement]
    var width: Double
    var height: Double
}

enum CanvasElement {
    case text(String, position: CGPoint, style: TextStyle)
    case rect(CGRect, fill: String, stroke: String?)
    case image(URL, frame: CGRect)
    case chart(ChartData)
    // ... more element types
}
```

The existing `CanvasWindowView.swift` and `CanvasController.swift` handle the WebView display. You need to generate the HTML/SVG content that gets displayed.

### 4.6 — Credentials

**`Sources/Fae/Core/CredentialManager.swift`**

Port from `src/credentials/` (1,640 lines). Much simpler in Swift:

```swift
import Security

actor CredentialManager {
    private let service = "com.saorsalabs.fae"

    func store(key: String, value: String) throws {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        // Delete existing, then add
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.storeFailed(status)
        }
    }

    func retrieve(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

### 4.7 — x0x Network Listener

**`Sources/Fae/Network/X0XListener.swift`**

Port from `src/x0x_listener.rs` (200 lines):

```swift
actor X0XListener {
    private let x0xdURL = URL(string: "http://127.0.0.1:12700/events")!
    private var task: Task<Void, Never>?
    private var rateLimit = RateLimiter(perSender: 10, global: 30)  // per minute

    func start(eventBus: FaeEventBus) {
        task = Task {
            // SSE (Server-Sent Events) listener via URLSession
            var request = URLRequest(url: x0xdURL)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                for try await line in bytes.lines {
                    if line.hasPrefix("data: ") {
                        let json = String(line.dropFirst(6))
                        try processMessage(json, eventBus: eventBus)
                    }
                }
            } catch {
                // Reconnect after delay
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                start(eventBus: eventBus)  // retry
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func processMessage(_ json: String, eventBus: FaeEventBus) throws {
        // 1. Parse message JSON
        // 2. Check trust level — only deliver Trusted + verified
        // 3. Rate limit check (10/min per sender, 30/min global)
        // 4. Safety: NEVER inject body raw — wrap in envelope:
        //    [Network message from trusted contact "X" via x0x]
        // 5. Route to LLM via eventBus
    }
}
```

### 4.8 — Diagnostics

**`Sources/Fae/Core/DiagnosticsManager.swift`**

Port from `src/diagnostics/` (~2,000 lines):

```swift
actor DiagnosticsManager {
    /// Comprehensive health check
    func healthCheck() async -> HealthReport {
        HealthReport(
            memoryDB: await checkMemoryDB(),
            models: await checkModels(),
            audio: checkAudio(),
            scheduler: await checkScheduler(),
            skills: await checkSkills(),
            diskSpace: checkDiskSpace(),
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    /// Log rotation — clean old log files
    func rotateOnLogs() {
        // Remove log files older than 7 days from ~/Library/Application Support/fae/logs/
    }

    /// Runtime audit — record significant events
    func recordAuditEvent(_ event: String) {
        // Append to audit log
    }
}

struct HealthReport: Codable {
    let memoryDB: ComponentHealth
    let models: ComponentHealth
    let audio: ComponentHealth
    let scheduler: ComponentHealth
    let skills: ComponentHealth
    let diskSpace: DiskSpaceInfo
    let uptime: TimeInterval
}

enum ComponentHealth: String, Codable {
    case healthy, degraded, failed, unknown
}
```

Wire diagnostics into `SettingsDeveloperTab.swift` for display.

---

## Wire Everything into FaeCore

Update `FaeCore.swift` to initialize and manage all Phase 4 components:

```swift
@MainActor
final class FaeCore: ObservableObject {
    // ... existing properties ...
    private var scheduler: FaeScheduler?
    private var skillManager: SkillManager?
    private var channelManager: ChannelManager?
    private var x0xListener: X0XListener?
    private var credentialManager: CredentialManager?
    private var diagnostics: DiagnosticsManager?

    func start() async throws {
        // ... Phase 1 model loading and pipeline start ...

        // Phase 4: Background systems
        scheduler = FaeScheduler(memoryOrchestrator: memoryOrchestrator, eventBus: eventBus)
        await scheduler?.start()

        skillManager = SkillManager()
        // Auto-start previously running skills

        channelManager = ChannelManager()
        channelManager?.configure(config: config.channels)
        await channelManager?.start()

        x0xListener = X0XListener()
        await x0xListener?.start(eventBus: eventBus)

        credentialManager = CredentialManager()
        diagnostics = DiagnosticsManager()
    }

    func stop() async {
        await scheduler?.stop()
        await channelManager?.stop()
        await x0xListener?.stop()
        // ... Phase 1 pipeline stop ...
    }
}
```

---

## Verification

1. Build: `swift build` — zero errors
2. **Scheduler**: Check logs for scheduled task executions:
   - Memory backup runs at 02:00 (or trigger manually via scheduler tool)
   - Health check runs every 5 minutes
   - `triggerTask("morning_briefing")` generates and speaks a briefing
3. **Skills**: Import a test Python skill, verify it starts and responds to JSON-RPC calls
4. **Credentials**: Store and retrieve a credential via `CredentialManager`
5. **Diagnostics**: Settings > Developer tab shows health report
6. **x0x Listener**: If x0xd is running locally, verify messages are received and filtered

---

## Do NOT Do

- Do NOT change the voice pipeline (Phase 1)
- Do NOT change memory behavior (Phase 2)
- Do NOT change tool/agent behavior (Phase 3)
- Do NOT modify UI files (Phase 5 handles settings/onboarding updates)
- Do NOT delete the Rust `src/` directory yet
