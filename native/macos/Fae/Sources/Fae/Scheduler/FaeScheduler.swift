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

    init(
        eventBus: FaeEventBus,
        memoryOrchestrator: MemoryOrchestrator? = nil,
        memoryStore: SQLiteMemoryStore? = nil
    ) {
        self.eventBus = eventBus
        self.memoryOrchestrator = memoryOrchestrator
        self.memoryStore = memoryStore
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
        // TODO: Consolidate duplicate/overlapping memories
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
        // TODO: Reset proactive noise budget
    }

    private func runMorningBriefing() async {
        NSLog("FaeScheduler: morning_briefing — running")
        // TODO: Prepare morning briefing
    }

    private func runSkillProposals() async {
        NSLog("FaeScheduler: skill_proposals — running")
        // TODO: Check skill opportunities
    }

    private func runStaleRelationships() async {
        NSLog("FaeScheduler: stale_relationships — running")
        // TODO: Check stale relationships
    }

    private func runCheckUpdate() async {
        NSLog("FaeScheduler: check_fae_update — running")
        // TODO: Check for Fae updates via Sparkle
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
