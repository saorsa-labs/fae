import AppKit
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
    private let entityStore: EntityStore?
    private let vectorStore: VectorStore?
    private let embeddingEngine: NeuralEmbeddingEngine?
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

    /// Closure to inject a proactive query into the pipeline — set by FaeCore.
    /// Parameters: (prompt, silent, taskId, allowedTools, consentGranted).
    private var proactiveQueryHandler: (@Sendable (String, Bool, String, Set<String>, Bool) async -> Void)?

    /// Current awareness configuration — updated by FaeCore on config changes.
    private var awarenessConfig: FaeConfig.AwarenessConfig = FaeConfig.AwarenessConfig()

    /// Vault manager for backup tasks — set by FaeCore.
    private var vaultManager: GitVaultManager?

    /// Daily proactive interjection counter, reset at midnight.
    var proactiveInterjectionCount: Int = 0
    var proactiveDigestEligibleCounts: [String: Int] = [:]

    /// Tracks which interests have already had skill proposals surfaced.
    private var suggestedInterestIDs: Set<String> = []

    // MARK: - Awareness Tracking State

    /// When the user was last seen by camera.
    private var lastUserSeenAt: Date?

    /// Whether the enhanced morning briefing has been delivered today.
    private var morningBriefingDelivered: Bool = false

    /// Last camera check timestamp (for interval enforcement).
    private var lastCameraCheckAt: Date?

    /// Last screen check timestamp (for interval enforcement).
    private var lastScreenCheckAt: Date?

    /// Last frontmost app bundle identifier (for smart screen gating).
    private var lastFrontmostAppBundleId: String?

    /// Last persisted screen context hash for coalescing duplicate observations.
    private var lastScreenContentHash: String?

    /// Last time a screen context observation was persisted.
    private var lastScreenContextPersistedAt: Date?

    init(
        eventBus: FaeEventBus,
        memoryOrchestrator: MemoryOrchestrator? = nil,
        memoryStore: SQLiteMemoryStore? = nil,
        entityStore: EntityStore? = nil,
        vectorStore: VectorStore? = nil,
        embeddingEngine: NeuralEmbeddingEngine? = nil,
        config: FaeConfig.SchedulerConfig = FaeConfig.SchedulerConfig()
    ) {
        self.eventBus = eventBus
        self.memoryOrchestrator = memoryOrchestrator
        self.memoryStore = memoryStore
        self.entityStore = entityStore
        self.vectorStore = vectorStore
        self.embeddingEngine = embeddingEngine
        self.config = config
    }

    /// Set the speak handler (must be called before start for morning briefings to work).
    func setSpeakHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        speakHandler = handler
    }

    /// Set the vault manager for backup tasks.
    func setVaultManager(_ manager: GitVaultManager) {
        vaultManager = manager
    }

    /// Set the proactive query handler (must be called before start for awareness tasks to work).
    func setProactiveQueryHandler(
        _ handler: @escaping @Sendable (String, Bool, String, Set<String>, Bool) async -> Void
    ) {
        proactiveQueryHandler = handler
    }

    /// Update awareness configuration (called by FaeCore on config changes).
    func setAwarenessConfig(_ config: FaeConfig.AwarenessConfig) {
        awarenessConfig = config
    }

    /// Record that the user was seen (called from camera presence observations).
    func recordUserSeen() {
        lastUserSeenAt = Date()
    }

    /// Whether the morning briefing has been delivered today.
    func isMorningBriefingDelivered() -> Bool {
        morningBriefingDelivered
    }

    /// Coalesce duplicate screen observations: persist only when hash changed or
    /// at least 2 minutes elapsed since the previous persisted context.
    func shouldPersistScreenContext(contentHash: String) -> Bool {
        let now = Date()
        let hashChanged = (contentHash != lastScreenContentHash)
        let minElapsed = now.timeIntervalSince(lastScreenContextPersistedAt ?? .distantPast) >= 120

        if hashChanged || minElapsed {
            lastScreenContentHash = contentHash
            lastScreenContextPersistedAt = now
            return true
        }

        return false
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

        // Awareness tasks — only scheduled when awareness is enabled.
        if awarenessConfig.enabled, awarenessConfig.consentGrantedAt != nil {
            startAwarenessTasks()
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
        proactiveDigestEligibleCounts.removeAll()
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

    private func runEmbeddingReindex() async {
        NSLog("FaeScheduler: embedding_reindex — running")
        guard let store = memoryStore,
              let entityStore,
              let vs = vectorStore,
              let engine = embeddingEngine
        else {
            NSLog("FaeScheduler: embedding_reindex — missing dependencies, skipping")
            return
        }
        EmbeddingBackfillRunner.backfillIfNeeded(
            memoryStore: store,
            entityStore: entityStore,
            vectorStore: vs,
            embeddingEngine: engine
        )
    }

    private func runVaultBackup() async {
        NSLog("FaeScheduler: vault_backup — running")
        guard let vault = vaultManager else {
            NSLog("FaeScheduler: vault_backup — no vault manager configured")
            return
        }
        let result = await vault.backup(reason: "scheduled daily backup")
        switch result {
        case .success(let hash):
            NSLog("FaeScheduler: vault_backup — complete (%@)", hash)
        case .noChanges:
            NSLog("FaeScheduler: vault_backup — skipped (no changes)")
        case .failure(let error):
            NSLog("FaeScheduler: vault_backup — failed: %@", error)
        }
    }

    private func runCheckUpdate() async {
        NSLog("FaeScheduler: check_fae_update — running")
        // Sparkle handles update checks automatically when configured.
        // This task logs the check for observability.
    }

    private func runSkillHealthCheck() async {
        let manager = SkillManager()
        let results = await manager.healthCheckAll()
        guard !results.isEmpty else { return }

        var degraded: [String] = []
        var broken: [String] = []

        for (name, status) in results {
            switch status {
            case .healthy:
                continue
            case .degraded(let reason):
                degraded.append("\(name): \(reason)")
            case .broken(let reason):
                broken.append("\(name): \(reason)")
            }
        }

        if !degraded.isEmpty {
            NSLog(
                "FaeScheduler: skill_health_check — degraded skills: %@",
                degraded.sorted().joined(separator: " | ")
            )
        }
        if !broken.isEmpty {
            NSLog(
                "FaeScheduler: skill_health_check — broken skills: %@",
                broken.sorted().joined(separator: " | ")
            )
        }
    }

    // MARK: - Awareness Tasks

    /// Start awareness-specific repeating tasks.
    private func startAwarenessTasks() {
        let cameraInterval = TimeInterval(awarenessConfig.cameraIntervalSeconds)
        let screenInterval = TimeInterval(awarenessConfig.screenIntervalSeconds)

        if awarenessConfig.cameraEnabled {
            scheduleRepeating("camera_presence_check", interval: cameraInterval) { [weak self] in
                await self?.runCameraPresenceCheck()
            }
        }
        if awarenessConfig.screenEnabled {
            scheduleRepeating("screen_activity_check", interval: screenInterval) { [weak self] in
                await self?.runScreenActivityCheck()
            }
        }

        NSLog("FaeScheduler: awareness tasks started (camera=%@, screen=%@)",
              awarenessConfig.cameraEnabled ? "on" : "off",
              awarenessConfig.screenEnabled ? "on" : "off")
    }

    /// Restart awareness tasks after config changes. Call from FaeCore after updating awareness config.
    func restartAwarenessTasks() {
        // Cancel existing awareness timers.
        for id in ["camera_presence_check", "screen_activity_check"] {
            if let timer = timers.removeValue(forKey: id) {
                timer.cancel()
            }
        }

        // Re-schedule if awareness is enabled.
        if isRunning, awarenessConfig.enabled, awarenessConfig.consentGrantedAt != nil {
            startAwarenessTasks()
        }
    }

    @discardableResult
    private func dispatchProactiveTask(
        taskId: String,
        prompt: String,
        urgency: ProactiveUrgency,
        defaultSilent: Bool,
        throttle: ThrottleDecision,
        allowedTools: Set<String>
    ) async -> Bool {
        guard let handler = proactiveQueryHandler else { return false }

        let mode = await proactiveDispatchMode(taskID: taskId, urgency: urgency)
        guard mode != .suppress else {
            NSLog("FaeScheduler: %@ suppressed by proactive policy", taskId)
            return false
        }

        let throttleSilent = {
            if case .silentOnly = throttle { return true }
            return false
        }()
        let silent = defaultSilent || throttleSilent || mode == .digest
        if !silent {
            proactiveInterjectionCount += 1
        }

        NSLog(
            "FaeScheduler: %@ dispatching (mode=%@, silent=%@)",
            taskId,
            mode.rawValue,
            silent ? "yes" : "no"
        )
        await handler(
            prompt,
            silent,
            taskId,
            allowedTools,
            awarenessConfig.enabled && awarenessConfig.consentGrantedAt != nil
        )
        return true
    }

    private func runCameraPresenceCheck() async {
        let throttle = AwarenessThrottle.check(
            config: awarenessConfig,
            taskId: "camera_presence_check",
            lastUserSeenAt: lastUserSeenAt
        )

        switch throttle {
        case .skip(let reason):
            NSLog("FaeScheduler: camera_presence_check skipped — %@", reason)
            return
        case .silentOnly, .normal:
            break
        }

        // Adaptive frequency: reduce to every 5 min when user absent >30 min.
        if AwarenessThrottle.shouldReduceFrequency(lastUserSeenAt: lastUserSeenAt) {
            if let lastCheck = lastCameraCheckAt,
               Date().timeIntervalSince(lastCheck) < 290 { // ~5 min minus jitter
                return
            }
        }

        // Enforce minimum interval with jitter.
        if let lastCheck = lastCameraCheckAt {
            let minInterval = TimeInterval(awarenessConfig.cameraIntervalSeconds) + AwarenessThrottle.randomJitter()
            if Date().timeIntervalSince(lastCheck) < minInterval {
                return
            }
        }
        lastCameraCheckAt = Date()

        let prompt = "[PROACTIVE CAMERA OBSERVATION] Check who is at the desk using the camera tool. Follow the proactive-awareness skill instructions."
        _ = await dispatchProactiveTask(
            taskId: "camera_presence_check",
            prompt: prompt,
            urgency: .low,
            defaultSilent: false,
            throttle: throttle,
            allowedTools: ["camera"]
        )
    }

    private func runScreenActivityCheck() async {
        let throttle = AwarenessThrottle.check(
            config: awarenessConfig,
            taskId: "screen_activity_check",
            lastUserSeenAt: lastUserSeenAt
        )

        switch throttle {
        case .skip(let reason):
            NSLog("FaeScheduler: screen_activity_check skipped — %@", reason)
            return
        case .silentOnly, .normal:
            break
        }

        // Smart gating: only run when frontmost app changed or 2 min minimum.
        let currentApp = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        let appChanged = (currentApp != lastFrontmostAppBundleId)
        lastFrontmostAppBundleId = currentApp

        if !appChanged {
            if let lastCheck = lastScreenCheckAt,
               Date().timeIntervalSince(lastCheck) < 120 { // 2 min minimum
                return
            }
        }

        // Enforce minimum interval with jitter.
        if let lastCheck = lastScreenCheckAt {
            let minInterval = TimeInterval(awarenessConfig.screenIntervalSeconds) + AwarenessThrottle.randomJitter()
            if Date().timeIntervalSince(lastCheck) < minInterval {
                return
            }
        }
        lastScreenCheckAt = Date()

        let prompt = "[PROACTIVE SCREEN OBSERVATION] Take a screenshot and note the current screen context. Follow the screen-awareness skill instructions."
        _ = await dispatchProactiveTask(
            taskId: "screen_activity_check",
            prompt: prompt,
            urgency: .low,
            defaultSilent: true,
            throttle: throttle,
            allowedTools: ["screenshot"]
        )
    }

    private func runOvernightWork() async {
        let throttle = AwarenessThrottle.check(
            config: awarenessConfig,
            taskId: "overnight_work",
            lastUserSeenAt: lastUserSeenAt
        )

        switch throttle {
        case .skip(let reason):
            NSLog("FaeScheduler: overnight_work skipped — %@", reason)
            return
        case .silentOnly, .normal:
            break
        }

        let prompt = "[OVERNIGHT RESEARCH CYCLE] Research topics the user cares about. Follow the overnight-research skill instructions."
        _ = await dispatchProactiveTask(
            taskId: "overnight_work",
            prompt: prompt,
            urgency: .low,
            defaultSilent: true,
            throttle: throttle,
            allowedTools: ["web_search", "fetch_url", "activate_skill"]
        )
    }

    private func runEnhancedMorningBriefing() async {
        guard !morningBriefingDelivered else { return }

        let throttle = AwarenessThrottle.check(
            config: awarenessConfig,
            taskId: "enhanced_morning_briefing",
            lastUserSeenAt: lastUserSeenAt
        )

        switch throttle {
        case .skip(let reason):
            NSLog("FaeScheduler: enhanced_morning_briefing skipped — %@", reason)
            return
        case .silentOnly:
            // Don't deliver briefing during quiet hours.
            return
        case .normal:
            break
        }

        let prompt = "[ENHANCED MORNING BRIEFING] [USER_JUST_ARRIVED] Deliver a warm, conversational morning briefing. Follow the morning-briefing-v2 skill instructions."
        let dispatched = await dispatchProactiveTask(
            taskId: "enhanced_morning_briefing",
            prompt: prompt,
            urgency: .medium,
            defaultSilent: false,
            throttle: throttle,
            allowedTools: ["calendar", "reminders", "contacts", "mail", "notes", "activate_skill"]
        )
        if dispatched {
            morningBriefingDelivered = true
        }
    }

    /// Called when user is first detected after quiet hours — triggers morning briefing.
    func notifyUserDetectedPostQuietHours() async {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 7, !morningBriefingDelivered else { return }
        guard awarenessConfig.enabled, awarenessConfig.enhancedBriefingEnabled else { return }
        await runEnhancedMorningBriefing()
    }

    /// Fallback: trigger morning briefing on first user interaction after 07:00.
    func checkMorningBriefingFallback() async {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 7, hour < 12, !morningBriefingDelivered else { return }
        guard awarenessConfig.enabled, awarenessConfig.enhancedBriefingEnabled else { return }
        await runEnhancedMorningBriefing()
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
        // vault_backup: daily 02:30
        if hour == 2, minute >= 30, minute < 32 { await runDailyIfNeeded("vault_backup") { await runVaultBackup() } }
        // memory_gc: daily 03:30
        if hour == 3, minute >= 30, minute < 32 { await runDailyIfNeeded("memory_gc") { await runMemoryGC() } }
        // noise_budget_reset: daily 00:00 + morning briefing flag reset
        if hour == 0, minute < 2 {
            await runDailyIfNeeded("noise_budget_reset") { await runNoiseBudgetReset() }
            morningBriefingDelivered = false
        }
        // morning_briefing: configurable hour (default 08:00)
        // Skip legacy briefing when enhanced awareness briefing is enabled.
        if hour == config.morningBriefingHour,
           minute < 2,
           !(awarenessConfig.enabled && awarenessConfig.enhancedBriefingEnabled)
        {
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
        // embedding_reindex: weekly on Sunday at 03:00.
        if weekday == 1, hour == 3, minute < 2 {
            await runDailyIfNeeded("embedding_reindex") { await runEmbeddingReindex() }
        }

        // Awareness: overnight_work — hourly during 22:00-06:00.
        if awarenessConfig.enabled, awarenessConfig.overnightWorkEnabled,
           (hour >= 22 || hour < 6), minute < 2 {
            let key = "overnight_work_\(hour)"
            await runDailyIfNeeded(key) { await runOvernightWork() }
        }

        // Awareness: enhanced_morning_briefing — deferred until user detected after 07:00.
        // This is a fallback check; primary trigger is notifyUserDetectedPostQuietHours().
        if awarenessConfig.enabled, awarenessConfig.enhancedBriefingEnabled,
           hour >= 7, hour < 12, !morningBriefingDelivered, minute < 2 {
            // If camera is disabled, try fallback on the 5-minute scheduler tick.
            if !awarenessConfig.cameraEnabled {
                await runDailyIfNeeded("enhanced_morning_briefing") { await runEnhancedMorningBriefing() }
            }
        }

        await runDueUserTasksIfNeeded(now: now)
    }

    private func runDailyIfNeeded(_ name: String, _ action: () async -> Void) async {
        let today = Calendar.current.startOfDay(for: Date())
        if let lastRun = lastDailyRun[name], Calendar.current.isDate(lastRun, inSameDayAs: today) {
            return // Already ran today
        }
        lastDailyRun[name] = Date()
        await action()
    }

    private func schedulerPrompt(for task: SchedulerTask) -> String {
        """
        [USER SCHEDULED TASK]
        Task name: \(task.name)
        Task instructions: \(task.action)

        Run this scheduled task on the user's behalf. Prefer relevant skills when they help, and stay within the scheduled-task tool allowlist for this run.
        """
    }

    private func persistSchedulerTasks(_ tasks: [SchedulerTask]) {
        do {
            try writeSchedulerTasks(tasks)
        } catch {
            NSLog("FaeScheduler: failed to persist scheduler tasks: %@", error.localizedDescription)
        }
    }

    private func normalizedNextRun(for task: SchedulerTask, after reference: Date) -> String? {
        schedulerNextRunString(for: task, after: reference)
    }

    private func ensureNextRun(for task: inout SchedulerTask, after reference: Date) -> Bool {
        if let nextRun = task.nextRun,
           schedulerISO8601Formatter.date(from: nextRun) != nil
        {
            return false
        }

        let updated = normalizedNextRun(for: task, after: reference)
        guard task.nextRun != updated else { return false }
        task.nextRun = updated
        return true
    }

    private func recordSuccessfulRun(taskID: String, at runAt: Date, reason: String) async {
        runHistory[taskID, default: []].append(runAt)

        guard let store = persistenceStore else { return }

        let record = TaskRunRecord(
            taskID: taskID,
            idempotencyKey: "\(reason):\(taskID):\(Int(runAt.timeIntervalSince1970))",
            state: .success,
            attempt: 0,
            updatedAt: runAt,
            lastError: nil
        )

        do {
            try await store.insertRun(record)
        } catch {
            NSLog("FaeScheduler: failed to persist run for '%@': %@", taskID, error.localizedDescription)
        }
    }

    private func dispatchUserTask(_ task: SchedulerTask, silent: Bool) async -> Bool {
        guard let handler = proactiveQueryHandler else {
            NSLog("FaeScheduler: no proactive query handler for user task '%@'", task.id)
            return false
        }

        let allowedTools = Set(normalizedAutonomousSchedulerTools(from: task.allowedTools))
        await handler(
            schedulerPrompt(for: task),
            silent,
            task.id,
            allowedTools,
            true
        )
        return true
    }

    @discardableResult
    private func runUserTaskIfExists(id: String, at reference: Date, silent: Bool, reason: String) async -> Bool {
        var tasks = readSchedulerTasks()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.kind == "user" }) else {
            return false
        }

        let task = tasks[index]
        guard task.enabled, !disabledTaskIDs.contains(task.id) else {
            NSLog("FaeScheduler: user task '%@' is disabled", task.id)
            return true
        }

        guard await dispatchUserTask(task, silent: silent) else {
            return true
        }

        tasks[index].nextRun = normalizedNextRun(for: task, after: reference)
        persistSchedulerTasks(tasks)
        await recordSuccessfulRun(taskID: task.id, at: reference, reason: reason)
        return true
    }

    private func runDueUserTasksIfNeeded(now: Date) async {
        var tasks = readSchedulerTasks()
        var didChangeTasks = false

        for index in tasks.indices {
            guard tasks[index].kind == "user" else { continue }

            if ensureNextRun(for: &tasks[index], after: now) {
                didChangeTasks = true
            }

            guard tasks[index].enabled, !disabledTaskIDs.contains(tasks[index].id) else { continue }
            guard let nextRunString = tasks[index].nextRun,
                  let nextRunDate = schedulerISO8601Formatter.date(from: nextRunString),
                  nextRunDate <= now
            else {
                continue
            }

            let task = tasks[index]
            guard await dispatchUserTask(task, silent: true) else { continue }

            tasks[index].nextRun = normalizedNextRun(for: task, after: now)
            didChangeTasks = true
            await recordSuccessfulRun(taskID: task.id, at: now, reason: "scheduled")
        }

        if didChangeTasks {
            persistSchedulerTasks(tasks)
        }
    }

    // MARK: - External Task Control

    /// Trigger a named task to run immediately (from FaeCore command or SchedulerTriggerTool).
    func triggerTask(id: String) async {
        NSLog("FaeScheduler: manual trigger for '%@'", id)
        if disabledTaskIDs.contains(id) {
            NSLog("FaeScheduler: task '%@' is disabled", id)
            return
        }
        let runAt = Date()
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
        case "embedding_reindex": await runEmbeddingReindex()
        case "vault_backup":     await runVaultBackup()
        case "camera_presence_check":  await runCameraPresenceCheck()
        case "screen_activity_check":  await runScreenActivityCheck()
        case "overnight_work":         await runOvernightWork()
        case "enhanced_morning_briefing": await runEnhancedMorningBriefing()
        default:
            if await runUserTaskIfExists(id: id, at: runAt, silent: true, reason: "trigger") {
                return
            }
            NSLog("FaeScheduler: unknown task id '%@'", id)
            return
        }
        await recordSuccessfulRun(taskID: id, at: runAt, reason: "trigger")
    }

    /// Delete a user-created scheduled task (builtin tasks cannot be deleted).
    func deleteUserTask(id: String) async {
        var tasks = readSchedulerTasks()
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.kind == "user" }) else {
            NSLog("FaeScheduler: task '%@' not found or not deletable", id)
            return
        }

        tasks.remove(at: index)
        persistSchedulerTasks(tasks)
        disabledTaskIDs.remove(id)
        runHistory[id] = nil
        NSLog("FaeScheduler: deleted user task '%@'", id)
    }

    func setTaskEnabled(id: String, enabled: Bool) async {
        if enabled {
            disabledTaskIDs.remove(id)
        } else {
            disabledTaskIDs.insert(id)
        }

        var tasks = readSchedulerTasks()
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].enabled = enabled
            if enabled {
                _ = ensureNextRun(for: &tasks[index], after: Date())
            }
            persistSchedulerTasks(tasks)
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
        ids.formUnion(readSchedulerTasks().map(\.id))

        // Include all known task IDs from the builtin list
        let builtinIDs = [
            "memory_reflect", "memory_reindex", "memory_migrate",
            "memory_gc", "memory_backup", "check_fae_update",
            "morning_briefing", "noise_budget_reset", "skill_proposals",
            "stale_relationships", "skill_health_check", "embedding_reindex",
            "vault_backup", "camera_presence_check", "screen_activity_check",
            "overnight_work", "enhanced_morning_briefing",
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
