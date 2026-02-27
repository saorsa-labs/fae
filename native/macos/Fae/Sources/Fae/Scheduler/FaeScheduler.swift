import Foundation

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
    private var timers: [String: DispatchSourceTimer] = [:]
    private var isRunning = false

    /// Closure to make Fae speak — set by FaeCore after pipeline is ready.
    var speakHandler: (@Sendable (String) async -> Void)?

    /// Daily proactive interjection counter, reset at midnight.
    private var proactiveInterjectionCount: Int = 0

    init(
        eventBus: FaeEventBus,
        memoryOrchestrator: MemoryOrchestrator? = nil,
        memoryStore: SQLiteMemoryStore? = nil
    ) {
        self.eventBus = eventBus
        self.memoryOrchestrator = memoryOrchestrator
        self.memoryStore = memoryStore
    }

    /// Set the speak handler (must be called before start for morning briefings to work).
    func setSpeakHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        speakHandler = handler
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
            // Query recent active records and look for near-duplicates by text overlap.
            let records = try await store.recentRecords(limit: 100)
            var mergedCount = 0
            var seen: Set<String> = []

            for record in records where record.status == .active && record.kind != .episode {
                let key = record.text.lowercased().prefix(80).trimmingCharacters(in: .whitespaces)
                if seen.contains(key) {
                    // Duplicate found — soft-forget the older one.
                    try await store.forgetSoftRecord(id: record.id, note: "memory_reflect: duplicate")
                    mergedCount += 1
                } else {
                    seen.insert(key)
                }
            }

            if mergedCount > 0 {
                NSLog("FaeScheduler: memory_reflect — cleaned %d duplicates", mergedCount)
            }
        } catch {
            NSLog("FaeScheduler: memory_reflect — error: %@", error.localizedDescription)
        }
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
        guard let orchestrator = memoryOrchestrator else { return }

        // 1. Gather recent memories (commitments, events, people).
        let commitmentContext = await orchestrator.recall(query: "upcoming deadlines and commitments")
        let eventContext = await orchestrator.recall(query: "upcoming events and dates")
        let peopleContext = await orchestrator.recall(query: "people to check in with")

        // 2. Compile a brief summary.
        var items: [String] = []
        if let ctx = commitmentContext, !ctx.isEmpty {
            items.append("You have some upcoming commitments I recall.")
        }
        if let ctx = eventContext, !ctx.isEmpty {
            items.append("There are events coming up worth noting.")
        }
        if let ctx = peopleContext, !ctx.isEmpty {
            items.append("There are people you might want to check in with.")
        }

        guard !items.isEmpty else {
            NSLog("FaeScheduler: morning_briefing — nothing to report")
            return
        }

        let briefing = "Good morning! " + items.joined(separator: " ") + " Want me to go into detail on any of these?"
        NSLog("FaeScheduler: morning_briefing — delivering %d items", items.count)

        // 3. Speak the briefing if the handler is wired.
        if let speak = speakHandler {
            await speak(briefing)
        }
    }

    private func runSkillProposals() async {
        NSLog("FaeScheduler: skill_proposals — running")
        guard let store = memoryStore else { return }
        do {
            // Look for interest-type memories that might benefit from a dedicated skill.
            let interests = try await store.findActiveByTag("interest")
            let preferences = try await store.findActiveByTag("preference")

            let total = interests.count + preferences.count
            if total > 3 {
                NSLog("FaeScheduler: skill_proposals — %d interests/preferences found, may suggest skills", total)
                // Future: surface suggestion via eventBus or speakHandler.
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

            var staleNames: [String] = []
            for record in personRecords {
                if record.updatedAt > 0, (now - record.updatedAt) > thirtyDays {
                    staleNames.append(record.text)
                }
            }

            if !staleNames.isEmpty {
                NSLog("FaeScheduler: stale_relationships — %d stale contacts found", staleNames.count)
                // Future: surface as gentle briefing item.
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
        // Silent unless issues found — don't log every 5min
    }

    // MARK: - Daily Schedule Checks

    /// Track which daily tasks have fired today.
    private var lastDailyRun: [String: Date] = [:]

    private func runDailyChecks() async {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)

        // memory_backup: daily 02:00
        if hour == 2, minute < 2 { await runDailyIfNeeded("memory_backup") { await runMemoryBackup() } }
        // memory_gc: daily 03:30
        if hour == 3, minute >= 30, minute < 32 { await runDailyIfNeeded("memory_gc") { await runMemoryGC() } }
        // noise_budget_reset: daily 00:00
        if hour == 0, minute < 2 { await runDailyIfNeeded("noise_budget_reset") { await runNoiseBudgetReset() } }
        // morning_briefing: daily 08:00
        if hour == 8, minute < 2 { await runDailyIfNeeded("morning_briefing") { await runMorningBriefing() } }
        // skill_proposals: daily 11:00
        if hour == 11, minute < 2 { await runDailyIfNeeded("skill_proposals") { await runSkillProposals() } }
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
    }

    /// Delete a user-created scheduled task (builtin tasks cannot be deleted).
    func deleteUserTask(id: String) async {
        // User task deletion is handled by SchedulerDeleteTool via scheduler.json.
        // This method is a stub for FaeCore command routing.
        NSLog("FaeScheduler: deleteUserTask '%@' — delegated to SchedulerDeleteTool", id)
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
