import Foundation

private struct SchedulerPersistedTask: Codable {
    var id: String
    var name: String
    var kind: String
    var enabled: Bool
    var scheduleType: String
    var scheduleParams: [String: String]
    var action: String
    var nextRun: String?
}

private struct SchedulerPersistedEnvelope: Codable {
    var tasks: [SchedulerPersistedTask]
}

/// Background task scheduler with 11 built-in tasks.
///
/// Uses `DispatchSourceTimer` for periodic tasks and `Calendar`-based
/// scheduling for daily tasks at specific times.
///
/// Replaces: `src/scheduler/{runner.rs, tasks.rs}` (3,611 lines)
actor FaeScheduler {
    private let eventBus: FaeEventBus
    private let memoryOrchestrator: MemoryOrchestrator?
    private let memoryStore: SQLiteMemoryStore?
    private var config: FaeConfig.SchedulerConfig
    private var timers: [String: DispatchSourceTimer] = [:]
    private var isRunning = false
    private var disabledTaskIDs: Set<String> = []
    private var runHistory: [String: [Date]] = [:]

    /// Persistence store for scheduler state (optional, injected by FaeCore).
    private var persistenceStore: SchedulerPersistenceStore?

    /// Task run ledger for idempotency and retry tracking.
    private(set) var taskRunLedger: TaskRunLedger = TaskRunLedger()

    /// Closure to make Fae speak — set by FaeCore after pipeline is ready.
    var speakHandler: (@Sendable (String) async -> Void)?

    /// Daily proactive interjection counter, reset at midnight.
    private var proactiveInterjectionCount: Int = 0

    /// Tracks which interests have already had skill proposals surfaced.
    private var suggestedInterestIDs: Set<String> = []

    init(
        eventBus: FaeEventBus,
        memoryOrchestrator: MemoryOrchestrator? = nil,
        memoryStore: SQLiteMemoryStore? = nil,
        config: FaeConfig.SchedulerConfig = FaeConfig.SchedulerConfig()
    ) {
        self.eventBus = eventBus
        self.memoryOrchestrator = memoryOrchestrator
        self.memoryStore = memoryStore
        self.config = config
    }

    /// Set the speak handler (must be called before start for morning briefings to work).
    func setSpeakHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        speakHandler = handler
    }

    /// Configure persistence — creates a persistence-backed ledger and loads saved state.
    func configurePersistence(store: SchedulerPersistenceStore) async {
        self.persistenceStore = store
        self.taskRunLedger = TaskRunLedger(store: store)

        // Load persisted disabled task IDs.
        do {
            let saved = try await store.loadDisabledTaskIDs()
            disabledTaskIDs = saved
            if !saved.isEmpty {
                NSLog("FaeScheduler: loaded %d disabled tasks from persistence", saved.count)
            }
        } catch {
            NSLog("FaeScheduler: failed to load disabled tasks: %@", error.localizedDescription)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Periodic tasks
        scheduleRepeating("memory_reflect", interval: 6 * 3600) { [weak self] in
            await self?.runMemoryReflect()
        }
        scheduleRepeating("memory_reindex", interval: 3 * 3600) { [weak self] in
            await self?.runMemoryReindex()
        }
        scheduleRepeating("memory_migrate", interval: 3600) { [weak self] in
            await self?.runMemoryMigrate()
        }
        scheduleRepeating("check_fae_update", interval: 6 * 3600) { [weak self] in
            await self?.runCheckUpdate()
        }
        scheduleRepeating("skill_health_check", interval: 300) { [weak self] in
            await self?.runSkillHealthCheck()
        }

        // Daily tasks (check every 60s, run if past due)
        scheduleRepeating("scheduler_tick", interval: 60) { [weak self] in
            await self?.runDailyChecks()
        }

        NSLog("FaeScheduler: started with %d timers", timers.count)
    }

    func stop() {
        for (name, timer) in timers {
            timer.cancel()
            NSLog("FaeScheduler: cancelled %@", name)
        }
        timers.removeAll()
        isRunning = false
        NSLog("FaeScheduler: stopped")
    }

    // MARK: - Task Implementations

    private func runMemoryReflect() async {
        NSLog("FaeScheduler: memory_reflect — running")
        guard let store = memoryStore else { return }
        do {
            let records = try await store.recentRecords(limit: 100)
            var mergedCount = 0

            // Group non-episode active records by kind for pairwise comparison.
            let durable = records.filter { $0.status == .active && $0.kind != .episode }
            let grouped = Dictionary(grouping: durable) { $0.kind }

            for (_, group) in grouped where group.count > 1 {
                var superseded: Set<String> = []
                for i in 0 ..< group.count {
                    guard !superseded.contains(group[i].id) else { continue }
                    for j in (i + 1) ..< group.count {
                        guard !superseded.contains(group[j].id) else { continue }

                        // Use cached embeddings if available, fall back to text prefix match.
                        let similar: Bool
                        if let embA = group[i].cachedEmbedding, !embA.isEmpty,
                           let embB = group[j].cachedEmbedding, !embB.isEmpty
                        {
                            similar = cosineSimilarity(embA, embB) > 0.92
                        } else {
                            let keyA = group[i].text.lowercased().prefix(80)
                                .trimmingCharacters(in: .whitespaces)
                            let keyB = group[j].text.lowercased().prefix(80)
                                .trimmingCharacters(in: .whitespaces)
                            similar = keyA == keyB
                        }

                        if similar {
                            // Keep the higher-confidence record, supersede the other.
                            let (keep, drop) = group[i].confidence >= group[j].confidence
                                ? (group[i], group[j])
                                : (group[j], group[i])
                            try await store.forgetSoftRecord(
                                id: drop.id,
                                note: "memory_reflect: semantic duplicate of \(keep.id)"
                            )
                            superseded.insert(drop.id)
                            mergedCount += 1
                        }
                    }
                }
            }

            if mergedCount > 0 {
                NSLog("FaeScheduler: memory_reflect — cleaned %d semantic duplicates", mergedCount)
            }
        } catch {
            NSLog("FaeScheduler: memory_reflect — error: %@", error.localizedDescription)
        }
    }

    /// Cosine similarity between two float vectors.
    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let length = min(lhs.count, rhs.count)
        guard length > 0 else { return 0 }

        var dot: Float = 0
        var lhsSq: Float = 0
        var rhsSq: Float = 0

        for i in 0 ..< length {
            dot += lhs[i] * rhs[i]
            lhsSq += lhs[i] * lhs[i]
            rhsSq += rhs[i] * rhs[i]
        }

        let denom = sqrt(lhsSq) * sqrt(rhsSq)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    private func runMemoryReindex() async {
        NSLog("FaeScheduler: memory_reindex — running")
        do {
            try await memoryStore?.integrityCheck()
            NSLog("FaeScheduler: memory_reindex — integrity check passed")
        } catch {
            NSLog("FaeScheduler: memory_reindex — integrity error: %@", error.localizedDescription)
        }
    }

    private func runMemoryMigrate() async {
        NSLog("FaeScheduler: memory_migrate — schema check")
        // Schema migrations are applied at store init; this is a health check.
    }

    private func runMemoryGC() async {
        NSLog("FaeScheduler: memory_gc — running")
        let cleaned = await memoryOrchestrator?.garbageCollect(retentionDays: 90) ?? 0
        if cleaned > 0 {
            NSLog("FaeScheduler: memory_gc — cleaned %d records", cleaned)
        }
    }

    private func runMemoryBackup() async {
        NSLog("FaeScheduler: memory_backup — running")
        guard let store = memoryStore else { return }
        do {
            let dbPath = await store.databasePath
            let backupDir = (dbPath as NSString).deletingLastPathComponent + "/backups"
            _ = try MemoryBackup.backup(dbPath: dbPath, backupDir: backupDir)
            _ = try MemoryBackup.rotateBackups(backupDir: backupDir, keepCount: 7)
        } catch {
            NSLog("FaeScheduler: memory_backup — error: %@", error.localizedDescription)
        }
    }

    private func runNoiseBudgetReset() async {
        NSLog("FaeScheduler: noise_budget_reset — running")
        proactiveInterjectionCount = 0
        NSLog("FaeScheduler: noise_budget_reset — counter reset to 0")
    }

    private func runMorningBriefing() async {
        NSLog("FaeScheduler: morning_briefing — running")
        guard let store = memoryStore else { return }

        do {
            var items: [String] = []

            // 1. Query commitments — extract actual text.
            let commitments = try await store.findActiveByKind(.commitment, limit: 5)
            for record in commitments {
                let text = record.text
                    .replacingOccurrences(of: "User commitment: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    items.append("you mentioned \(text)")
                }
            }

            // 2. Query events — include details.
            let events = try await store.findActiveByKind(.event, limit: 3)
            for record in events {
                let text = record.text
                    .replacingOccurrences(of: "User event: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    items.append(text)
                }
            }

            // 3. Query people — mention specific names.
            let people = try await store.findActiveByKind(.person, limit: 2)
            let now = UInt64(Date().timeIntervalSince1970)
            let sevenDays: UInt64 = 7 * 24 * 3600
            for record in people where record.updatedAt > 0 && (now - record.updatedAt) > sevenDays {
                let name = extractPersonName(from: record.text)
                if !name.isEmpty {
                    items.append("it's been a while since you mentioned \(name)")
                }
            }

            guard !items.isEmpty else {
                NSLog("FaeScheduler: morning_briefing — nothing meaningful to report")
                return
            }

            // Limit to 3 items max.
            let selected = Array(items.prefix(3))
            let briefing: String
            if selected.count == 1 {
                briefing = "Good morning! Just a heads up — \(selected[0])."
            } else {
                let joined = selected.dropLast().joined(separator: ", ")
                briefing = "Good morning! Just a heads up — \(joined), and \(selected.last ?? "")."
            }

            NSLog("FaeScheduler: morning_briefing — delivering %d items", selected.count)
            if let speak = speakHandler {
                await speak(briefing)
            }
        } catch {
            NSLog("FaeScheduler: morning_briefing — error: %@", error.localizedDescription)
        }
    }

    /// Extract a person's name from memory text like "User knows: my sister Sarah works at..."
    private func extractPersonName(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "User knows: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to find a capitalized name word after the relationship prefix.
        let relationshipPrefixes = [
            "my wife ", "my husband ", "my partner ",
            "my sister ", "my brother ", "my mom ", "my mum ", "my dad ",
            "my daughter ", "my son ", "my friend ", "my colleague ",
            "my boss ", "my manager ", "my girlfriend ", "my boyfriend ",
        ]
        let lower = cleaned.lowercased()
        for prefix in relationshipPrefixes {
            if lower.hasPrefix(prefix) {
                let afterPrefix = String(cleaned.dropFirst(prefix.count))
                let firstWord = afterPrefix.prefix(while: { $0.isLetter || $0 == "-" })
                    .trimmingCharacters(in: .whitespaces)
                if !firstWord.isEmpty {
                    return firstWord
                }
            }
        }

        // Fall back to first 30 chars.
        return String(cleaned.prefix(30))
    }

    private func runSkillProposals() async {
        NSLog("FaeScheduler: skill_proposals — running")
        guard let store = memoryStore else { return }
        do {
            let interests = try await store.findActiveByTag("interest")

            // Find an interest we haven't suggested yet.
            let unsuggestedInterest = interests.first { !suggestedInterestIDs.contains($0.id) }
            guard let interest = unsuggestedInterest else {
                NSLog("FaeScheduler: skill_proposals — no unsurfaced interests")
                return
            }

            // Extract the topic from the interest text.
            let topic = interest.text
                .replacingOccurrences(of: "User is interested in: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !topic.isEmpty else { return }

            // Mark as suggested so we don't repeat.
            suggestedInterestIDs.insert(interest.id)

            // Store a commitment memory so the LLM can follow up naturally
            // on the next conversation (memory recall will surface this).
            _ = try await store.insertRecord(
                kind: .commitment,
                text: "Fae suggested creating a Python skill for \(topic) — awaiting user response.",
                confidence: 0.80,
                sourceTurnId: "scheduler:skill_proposals",
                tags: ["skill_proposal", "pending"],
                importanceScore: 0.60
            )

            let phrases = [
                "I noticed you're into \(topic). I could write a quick script to track updates on that. Want me to?",
                "Hey, since you're interested in \(topic), I could build a little skill to help with that. Shall I?",
                "By the way, I could create a Python skill around \(topic) to keep you updated. Interested?",
            ]
            let suggestion = phrases[Int.random(in: 0 ..< phrases.count)]

            NSLog("FaeScheduler: skill_proposals — suggesting skill for '%@'", topic)
            if let speak = speakHandler {
                await speak(suggestion)
            }
        } catch {
            NSLog("FaeScheduler: skill_proposals — error: %@", error.localizedDescription)
        }
    }

    private func runStaleRelationships() async {
        NSLog("FaeScheduler: stale_relationships — running")
        guard let store = memoryStore else { return }
        do {
            let personRecords = try await store.findActiveByTag("person")
            let now = UInt64(Date().timeIntervalSince1970)
            let thirtyDays: UInt64 = 30 * 24 * 3600

            // Find stale contacts (not mentioned in 30+ days).
            var staleRecords: [MemoryRecord] = []
            for record in personRecords {
                if record.updatedAt > 0, (now - record.updatedAt) > thirtyDays {
                    staleRecords.append(record)
                }
            }

            guard let staleRecord = staleRecords.first else {
                NSLog("FaeScheduler: stale_relationships — no stale contacts")
                return
            }

            let name = extractPersonName(from: staleRecord.text)
            guard !name.isEmpty else { return }

            let phrases = [
                "By the way, you haven't mentioned \(name) in a while. Everything good?",
                "Just a thought — it's been a while since \(name) came up. Might be worth reaching out.",
                "Hey, I noticed you haven't talked about \(name) recently. Hope all is well.",
            ]
            let reminder = phrases[Int.random(in: 0 ..< phrases.count)]

            NSLog("FaeScheduler: stale_relationships — reminding about '%@'", name)
            if let speak = speakHandler {
                await speak(reminder)
            }
        } catch {
            NSLog("FaeScheduler: stale_relationships — error: %@", error.localizedDescription)
        }
    }

    private func runCheckUpdate() async {
        NSLog("FaeScheduler: check_fae_update — running")
        // Sparkle handles update checks automatically when configured.
        // This task logs the check for observability.
    }

    private func runSkillHealthCheck() async {
        // Scan skills directory for .py files and verify PEP 723 metadata.
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        guard let skillsDir = appSupport?.appendingPathComponent("fae/skills") else { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: skillsDir.path) else { return }

        do {
            let contents = try fm.contentsOfDirectory(
                at: skillsDir,
                includingPropertiesForKeys: nil
            )
            let pyFiles = contents.filter { $0.pathExtension == "py" }
            guard !pyFiles.isEmpty else { return }

            var brokenSkills: [String] = []
            for file in pyFiles {
                let text = try String(contentsOf: file, encoding: .utf8)
                // Check for PEP 723 inline metadata header.
                if !text.contains("# /// script") {
                    brokenSkills.append(file.lastPathComponent)
                }
            }

            if !brokenSkills.isEmpty {
                NSLog(
                    "FaeScheduler: skill_health_check — %d skills missing PEP 723 metadata: %@",
                    brokenSkills.count,
                    brokenSkills.joined(separator: ", ")
                )
            }

            // Check if uv is available on PATH.
            let uvProcess = Process()
            uvProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            uvProcess.arguments = ["uv"]
            let pipe = Pipe()
            uvProcess.standardOutput = pipe
            uvProcess.standardError = pipe
            try uvProcess.run()
            uvProcess.waitUntilExit()
            if uvProcess.terminationStatus != 0 {
                NSLog("FaeScheduler: skill_health_check — uv not found on PATH")
            }
        } catch {
            // Silent on errors — this runs every 5 minutes.
            NSLog("FaeScheduler: skill_health_check — error: %@", error.localizedDescription)
        }
    }

    // MARK: - Daily Schedule Checks

    /// Track which daily tasks have fired today.
    private var lastDailyRun: [String: Date] = [:]

    private func runDailyChecks() async {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let weekday = cal.component(.weekday, from: now)

        // memory_backup: daily 02:00
        if hour == 2, minute < 2 { await runDailyIfNeeded("memory_backup") { await runMemoryBackup() } }
        // memory_gc: daily 03:30
        if hour == 3, minute >= 30, minute < 32 { await runDailyIfNeeded("memory_gc") { await runMemoryGC() } }
        // noise_budget_reset: daily 00:00
        if hour == 0, minute < 2 { await runDailyIfNeeded("noise_budget_reset") { await runNoiseBudgetReset() } }
        // morning_briefing: configurable hour (default 08:00)
        if hour == config.morningBriefingHour, minute < 2 {
            await runDailyIfNeeded("morning_briefing") { await runMorningBriefing() }
        }
        // skill_proposals: configurable hour (default 11:00)
        if hour == config.skillProposalsHour, minute < 2 {
            await runDailyIfNeeded("skill_proposals") { await runSkillProposals() }
        }
        // stale_relationships: weekly on Sunday at 10:00.
        if weekday == 1, hour == 10, minute < 2 {
            await runDailyIfNeeded("stale_relationships") { await runStaleRelationships() }
        }
    }

    private func runDailyIfNeeded(_ name: String, _ action: () async -> Void) async {
        let today = Calendar.current.startOfDay(for: Date())
        if let lastRun = lastDailyRun[name], Calendar.current.isDate(lastRun, inSameDayAs: today) {
            return // Already ran today
        }
        lastDailyRun[name] = Date()
        await action()
    }

    // MARK: - External Task Control

    /// Trigger a named task to run immediately (from FaeCore command or SchedulerTriggerTool).
    func triggerTask(id: String) async {
        NSLog("FaeScheduler: manual trigger for '%@'", id)
        if disabledTaskIDs.contains(id) {
            NSLog("FaeScheduler: task '%@' is disabled", id)
            return
        }
        switch id {
        case "memory_reflect":    await runMemoryReflect()
        case "memory_reindex":    await runMemoryReindex()
        case "memory_migrate":    await runMemoryMigrate()
        case "memory_gc":         await runMemoryGC()
        case "memory_backup":     await runMemoryBackup()
        case "check_fae_update":  await runCheckUpdate()
        case "morning_briefing":  await runMorningBriefing()
        case "noise_budget_reset": await runNoiseBudgetReset()
        case "skill_proposals":   await runSkillProposals()
        case "stale_relationships": await runStaleRelationships()
        case "skill_health_check": await runSkillHealthCheck()
        default:
            NSLog("FaeScheduler: unknown task id '%@'", id)
        }
        runHistory[id, default: []].append(Date())

        // Persist the run to the store
        if let store = persistenceStore {
            let record = TaskRunRecord(
                taskID: id, idempotencyKey: "trigger:\(id):\(Int(Date().timeIntervalSince1970))",
                state: .success, attempt: 0,
                updatedAt: Date(), lastError: nil
            )
            do {
                try await store.insertRun(record)
            } catch {
                NSLog("FaeScheduler: failed to persist trigger run: %@", error.localizedDescription)
            }
        }
    }

    /// Delete a user-created scheduled task (builtin tasks cannot be deleted).
    func deleteUserTask(id: String) async {
        guard let schedulerURL = Self.schedulerFileURL() else {
            NSLog("FaeScheduler: scheduler file path unavailable")
            return
        }
        do {
            let didDelete = try Self.deleteUserTaskFromFile(id: id, fileURL: schedulerURL)
            if didDelete {
                NSLog("FaeScheduler: deleted user task '%@'", id)
            } else {
                NSLog("FaeScheduler: task '%@' not found or not deletable", id)
            }
        } catch {
            NSLog("FaeScheduler: failed to delete task '%@': %@", id, error.localizedDescription)
        }
    }

    func setTaskEnabled(id: String, enabled: Bool) async {
        if enabled {
            disabledTaskIDs.remove(id)
        } else {
            disabledTaskIDs.insert(id)
        }

        // Persist to store
        if let store = persistenceStore {
            do {
                try await store.setTaskEnabled(id: id, enabled: enabled)
            } catch {
                NSLog("FaeScheduler: failed to persist enabled state: %@", error.localizedDescription)
            }
        }
    }

    func isTaskEnabled(id: String) async -> Bool {
        !disabledTaskIDs.contains(id)
    }

    func status(taskID: String) async -> [String: Any] {
        // Check persistence store for last run time if not in memory
        var lastRunAt: TimeInterval?
        if let memoryRun = runHistory[taskID]?.last {
            lastRunAt = memoryRun.timeIntervalSince1970
        } else if let store = persistenceStore {
            do {
                let history = try await store.runHistory(taskID: taskID, limit: 1)
                lastRunAt = history.first?.timeIntervalSince1970
            } catch {
                NSLog("FaeScheduler: failed to query run history: %@", error.localizedDescription)
            }
        }

        return [
            "id": taskID,
            "enabled": !disabledTaskIDs.contains(taskID),
            "last_run_at": lastRunAt as Any,
        ]
    }

    func history(taskID: String, limit: Int = 20) async -> [Date] {
        // Prefer persistence store if available
        if let store = persistenceStore {
            do {
                return try await store.runHistory(taskID: taskID, limit: limit)
            } catch {
                NSLog("FaeScheduler: failed to query history: %@", error.localizedDescription)
            }
        }
        let runs = runHistory[taskID] ?? []
        return Array(runs.suffix(max(1, limit)))
    }

    func statusAll() async -> [[String: Any]] {
        var ids = Set(runHistory.keys).union(disabledTaskIDs)

        // Include all known task IDs from the builtin list
        let builtinIDs = [
            "memory_reflect", "memory_reindex", "memory_migrate",
            "memory_gc", "memory_backup", "check_fae_update",
            "morning_briefing", "noise_budget_reset", "skill_proposals",
            "stale_relationships", "skill_health_check",
        ]
        ids.formUnion(builtinIDs)

        return ids.sorted().map { id in
            [
                "id": id,
                "enabled": !disabledTaskIDs.contains(id),
                "last_run_at": runHistory[id]?.last?.timeIntervalSince1970 as Any,
            ]
        }
    }

    // MARK: - Scheduler File Helpers

    private static func schedulerFileURL() -> URL? {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")

        return appSupport.appendingPathComponent("fae/scheduler.json")
    }

    private static func deleteUserTaskFromFile(id: String, fileURL: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return false }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()

        var tasks: [SchedulerPersistedTask]
        var wrapped = false

        if let envelope = try? decoder.decode(SchedulerPersistedEnvelope.self, from: data) {
            tasks = envelope.tasks
            wrapped = true
        } else if let array = try? decoder.decode([SchedulerPersistedTask].self, from: data) {
            tasks = array
        } else {
            return false
        }

        guard let index = tasks.firstIndex(where: { $0.id == id && $0.kind == "user" }) else {
            return false
        }

        tasks.remove(at: index)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output: Data
        if wrapped {
            output = try encoder.encode(SchedulerPersistedEnvelope(tasks: tasks))
        } else {
            output = try encoder.encode(tasks)
        }

        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: fileURL, options: .atomic)
        return true
    }

    // MARK: - Timer Helpers

    private func scheduleRepeating(
        _ name: String,
        interval: TimeInterval,
        action: @escaping @Sendable () async -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .seconds(5)
        )
        timer.setEventHandler {
            Task { await action() }
        }
        timer.resume()
        timers[name] = timer
    }
}
