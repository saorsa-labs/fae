import AppKit
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
    /// Returns true when queued/accepted, false when skipped (e.g. assistant busy).
    private var proactiveQueryHandler: (@Sendable (String, Bool, String, Set<String>, Bool) async -> Bool)?

    /// Current awareness configuration — updated by FaeCore on config changes.
    private var awarenessConfig: FaeConfig.AwarenessConfig = FaeConfig.AwarenessConfig()

    /// Vault manager for backup tasks — set by FaeCore.
    private var vaultManager: GitVaultManager?

    /// Daily proactive interjection counter, reset at midnight.
    private var proactiveInterjectionCount: Int = 0

    /// Tracks which interests have already had skill proposals surfaced.
    private var suggestedInterestIDs: Set<String> = []

    // MARK: - Skills-First Heartbeat State

    /// Last successful heartbeat run timestamp.
    private var lastHeartbeatRunAt: Date?

    /// Pending heartbeat retries when proactive queue is busy.
    private var pendingHeartbeatRetryCount: Int = 0

    /// Persisted progression state for capability teaching.
    private var capabilityProgress = CapabilityProgressState()

    /// UserDefaults key for persisted capability progression state.
    private static let capabilityProgressDefaultsKey = "fae.scheduler.capability_progress.v1"

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

        // Best-effort restore of progression state used by skills-first coaching.
        if let data = UserDefaults.standard.data(forKey: Self.capabilityProgressDefaultsKey),
           let restored = try? JSONDecoder().decode(CapabilityProgressState.self, from: data)
        {
            self.capabilityProgress = restored
        }
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
        _ handler: @escaping @Sendable (String, Bool, String, Set<String>, Bool) async -> Bool
    ) {
        proactiveQueryHandler = handler
    }

    /// Update awareness configuration (called by FaeCore on config changes).
    func setAwarenessConfig(_ config: FaeConfig.AwarenessConfig) {
        awarenessConfig = config
    }

    /// Update scheduler configuration (called by FaeCore on config changes).
    func setSchedulerConfig(_ schedulerConfig: FaeConfig.SchedulerConfig) {
        config = schedulerConfig
        restartHeartbeatTaskIfNeeded()
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

        // Skills-first heartbeat lane (batched proactive + teaching orchestration).
        restartHeartbeatTaskIfNeeded()

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

    private func restartHeartbeatTaskIfNeeded() {
        if let timer = timers.removeValue(forKey: "skills_heartbeat") {
            timer.cancel()
        }

        guard isRunning, config.heartbeatEnabled else { return }

        let interval = TimeInterval(max(5, config.heartbeatEveryMinutes) * 60)
        scheduleRepeating("skills_heartbeat", interval: interval) { [weak self] in
            await self?.runSkillsHeartbeat()
        }
    }

    private func runSkillsHeartbeat() async {
        guard config.heartbeatEnabled else { return }
        guard let handler = proactiveQueryHandler else { return }

        if !isWithinHeartbeatActiveHours(Date()) {
            NSLog("FaeScheduler: skills_heartbeat skipped — outside active hours")
            incrementHeartbeatMetric("skipped_outside_hours")
            return
        }

        let iso = ISO8601DateFormatter().string(from: Date())
        let quietMode = AwarenessThrottle.isQuietHours()
        let cooldownRemaining = heartbeatTeachCooldownRemainingMinutes()
        let cooldownActive = cooldownRemaining > 0
        let noiseBudgetAvailable = proactiveInterjectionCount < 2

        let effectiveTarget: String = {
            if quietMode || cooldownActive || !noiseBudgetAvailable {
                return "none"
            }
            return config.heartbeatTarget
        }()

        if effectiveTarget == "none" {
            if quietMode { incrementHeartbeatMetric("delivery_muted_quiet_hours") }
            if cooldownActive { incrementHeartbeatMetric("delivery_muted_cooldown") }
            if !noiseBudgetAvailable { incrementHeartbeatMetric("delivery_muted_noise_budget") }
        }

        let envelope = HeartbeatRunEnvelope(
            runID: UUID().uuidString,
            timestampISO8601: iso,
            deliveryTarget: effectiveTarget,
            quietMode: quietMode,
            checklist: heartbeatChecklist(),
            recentContext: await heartbeatRecentContextLines(),
            progress: capabilityProgress,
            ack: HeartbeatAckPolicy(
                token: config.heartbeatAckToken,
                ackMaxChars: config.heartbeatAckMaxChars
            )
        )

        let prompt = buildHeartbeatPrompt(envelope: envelope)
        let isSilentTarget = effectiveTarget == "none"

        let maxRetries = 3
        var retries = 0

        while true {
            let accepted = await handler(
                prompt,
                isSilentTarget,
                "skills_heartbeat",
                ["activate_skill", "read", "self_config", "web_search", "fetch_url"],
                true
            )

            if accepted {
                pendingHeartbeatRetryCount = 0
                lastHeartbeatRunAt = Date()
                incrementHeartbeatMetric("accepted")
                return
            }

            retries += 1
            pendingHeartbeatRetryCount = retries
            incrementHeartbeatMetric("deferred_busy")

            guard retries <= maxRetries else {
                NSLog("FaeScheduler: skills_heartbeat dropped after retries")
                incrementHeartbeatMetric("dropped_after_retries")
                pendingHeartbeatRetryCount = 0
                return
            }

            let delaySecs = min(30, retries * 5)
            NSLog("FaeScheduler: skills_heartbeat deferred — assistant busy (retry %d in %ds)", retries, delaySecs)
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySecs) * 1_000_000_000)
            } catch {
                NSLog("FaeScheduler: skills_heartbeat retry cancelled")
                pendingHeartbeatRetryCount = 0
                return
            }
        }
    }

    private func heartbeatChecklist() -> [String] {
        [
            "Read capability-coach skill instructions and run progressive coaching logic.",
            "If nothing needs attention, respond with \(config.heartbeatAckToken).",
            "If action is needed, include a <heartbeat_result>{json}</heartbeat_result> decision payload.",
            "Prefer one high-signal teaching nudge at most.",
            "If a visual demo is useful, include a <canvas_intent>{json}</canvas_intent> block.",
        ]
    }

    private func heartbeatRecentContextLines() async -> [String] {
        var lines: [String] = []
        if let lastHeartbeatRunAt {
            lines.append("last_heartbeat_at=\(ISO8601DateFormatter().string(from: lastHeartbeatRunAt))")
        }
        lines.append("progress_stage=\(capabilityProgress.stage.rawValue)")
        lines.append("successful_nudges=\(capabilityProgress.successfulNudges)")
        lines.append("dismissed_nudges=\(capabilityProgress.dismissedNudges)")
        let cooldown = heartbeatTeachCooldownRemainingMinutes()
        lines.append("teach_cooldown_remaining_minutes=\(cooldown)")
        lines.append("noise_budget_remaining=\(max(0, 2 - proactiveInterjectionCount))")
        return lines
    }

    private func heartbeatTeachCooldownRemainingMinutes(now: Date = Date()) -> Int {
        guard let iso = capabilityProgress.lastNudgeAtISO8601,
              let last = ISO8601DateFormatter().date(from: iso)
        else {
            return 0
        }
        let elapsed = Int(now.timeIntervalSince(last) / 60)
        let remaining = config.heartbeatTeachCooldownMinutes - elapsed
        return max(0, remaining)
    }

    private func markHeartbeatNudgeIssued(topic: String?) {
        let nowISO = ISO8601DateFormatter().string(from: Date())
        capabilityProgress.lastNudgeAtISO8601 = nowISO
        capabilityProgress.lastNudgeTopic = topic
        persistCapabilityProgress()
    }

    private func persistCapabilityProgress() {
        if let data = try? JSONEncoder().encode(capabilityProgress) {
            UserDefaults.standard.set(data, forKey: Self.capabilityProgressDefaultsKey)
        }
    }

    private func incrementHeartbeatMetric(_ suffix: String) {
        let key = "fae.heartbeat.\(suffix)"
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    func recordHeartbeatInteraction(userText: String) {
        // Count as positive engagement only when text plausibly follows up
        // on the most recent heartbeat nudge.
        guard let iso = capabilityProgress.lastNudgeAtISO8601,
              let last = ISO8601DateFormatter().date(from: iso)
        else { return }

        guard Date().timeIntervalSince(last) <= 600 else { return }

        guard isLikelyHeartbeatEngagement(
            userText: userText,
            topic: capabilityProgress.lastNudgeTopic
        ) else {
            incrementHeartbeatMetric("interaction_unrelated")
            return
        }

        capabilityProgress.successfulNudges += 1
        if capabilityProgress.successfulNudges % 3 == 0 {
            let nextStage = capabilityProgress.stage.next
            if nextStage != capabilityProgress.stage {
                capabilityProgress.stage = nextStage
                capabilityProgress.lastStageChangeAtISO8601 = ISO8601DateFormatter().string(from: Date())
                incrementHeartbeatMetric("stage_advanced")
            }
        }
        persistCapabilityProgress()
    }

    private func isLikelyHeartbeatEngagement(userText: String, topic: String?) -> Bool {
        let normalized = userText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if let topic,
           !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let normalizedTopic = topic.lowercased()
            if normalized.contains(normalizedTopic) {
                return true
            }

            let topicTerms = Set(normalizedTopic.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 4 })
            let textTerms = Set(normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 4 })

            if !topicTerms.isEmpty {
                let overlap = topicTerms.intersection(textTerms)
                let ratio = Double(overlap.count) / Double(topicTerms.count)
                if ratio >= 0.5 {
                    return true
                }
            }
        }

        let engagementMarkers = [
            "yes", "yeah", "yep", "sure", "okay", "ok", "sounds good",
            "let's do", "show me", "tell me more", "how do i", "help me",
            "do that", "try that", "walk me through", "can you show",
        ]
        return engagementMarkers.contains { normalized.contains($0) }
    }

    func recordHeartbeatDecision(_ decision: HeartbeatRunDecision, delivered: Bool) {
        incrementHeartbeatMetric("status_\(decision.status.rawValue)")

        if let suggested = decision.suggestedStage,
           shouldAdvance(from: capabilityProgress.stage, to: suggested)
        {
            capabilityProgress.stage = suggested
            capabilityProgress.lastStageChangeAtISO8601 = ISO8601DateFormatter().string(from: Date())
            incrementHeartbeatMetric("stage_suggested_advance")
        }

        if decision.status != .ok {
            if delivered {
                proactiveInterjectionCount += 1
                incrementHeartbeatMetric("teaching_nudge")
                markHeartbeatNudgeIssued(topic: decision.nudgeTopic)
            } else {
                capabilityProgress.dismissedNudges += 1
                incrementHeartbeatMetric("nudge_not_delivered")
            }
        }

        persistCapabilityProgress()
    }

    private func shouldAdvance(from current: CapabilityProgressStage, to suggested: CapabilityProgressStage) -> Bool {
        guard let currentIndex = CapabilityProgressStage.allCases.firstIndex(of: current),
              let suggestedIndex = CapabilityProgressStage.allCases.firstIndex(of: suggested)
        else {
            return false
        }
        return suggestedIndex > currentIndex
    }

    private func buildHeartbeatPrompt(envelope: HeartbeatRunEnvelope) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let envelopeJSON: String
        if let data = try? encoder.encode(envelope),
           let str = String(data: data, encoding: .utf8)
        {
            envelopeJSON = str
        } else {
            envelopeJSON = "{}"
        }

        return """
        [SKILLS-FIRST HEARTBEAT RUN]
        Activate and follow the `capability-coach` skill.

        Contract:
        - Use this envelope as authoritative run context.
        - If no action is needed, reply with \(config.heartbeatAckToken).
        - If action is needed, include one decision block:
          <heartbeat_result>{"schemaVersion":1,"status":"nudge|teach|alert|ok","message":"...","nudgeTopic":"...","suggestedStage":"discovering|guidedUse|habitForming|advancedAutomation|powerUser"}</heartbeat_result>
        - Keep any user-facing text concise and high-signal.
        - For visuals, emit at most one typed payload block:
          <canvas_intent>{"kind":"capability_card","payload":{...}}</canvas_intent>

        HEARTBEAT_ENVELOPE_JSON:
        \(envelopeJSON)
        """
    }

    private func isWithinHeartbeatActiveHours(_ date: Date) -> Bool {
        let cal = Calendar.current
        let current = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)

        guard let start = Self.parseHourMinute(config.heartbeatActiveStart),
              let end = Self.parseHourMinute(config.heartbeatActiveEnd)
        else {
            return true
        }

        if start == end {
            return false
        }

        if start < end {
            return current >= start && current < end
        }

        // Wrap-around window (e.g. 22:00-07:00)
        return current >= start || current < end
    }

    private static func parseHourMinute(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              (0 ... 23).contains(h),
              (0 ... 59).contains(m)
        else {
            return nil
        }
        return h * 60 + m
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

        guard let handler = proactiveQueryHandler else { return }

        let silent: Bool
        if case .silentOnly = throttle { silent = true } else { silent = false }
        let prompt = "[PROACTIVE CAMERA OBSERVATION] Check who is at the desk using the camera tool. Follow the proactive-awareness skill instructions."

        NSLog("FaeScheduler: camera_presence_check — firing (silent=%@)", silent ? "yes" : "no")
        _ = await handler(
            prompt,
            silent,
            "camera_presence_check",
            ["camera"],
            awarenessConfig.enabled && awarenessConfig.consentGrantedAt != nil
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

        guard let handler = proactiveQueryHandler else { return }

        let prompt = "[PROACTIVE SCREEN OBSERVATION] Take a screenshot and note the current screen context. Follow the screen-awareness skill instructions."

        NSLog("FaeScheduler: screen_activity_check — firing")
        _ = await handler(
            prompt,
            true, // Screen observations are always silent.
            "screen_activity_check",
            ["screenshot"],
            awarenessConfig.enabled && awarenessConfig.consentGrantedAt != nil
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

        guard let handler = proactiveQueryHandler else { return }

        let prompt = "[OVERNIGHT RESEARCH CYCLE] Research topics the user cares about. Follow the overnight-research skill instructions."

        NSLog("FaeScheduler: overnight_work — firing")
        _ = await handler(
            prompt,
            true, // Always silent — research stored in memory.
            "overnight_work",
            ["web_search", "fetch_url", "activate_skill"],
            awarenessConfig.enabled && awarenessConfig.consentGrantedAt != nil
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

        guard let handler = proactiveQueryHandler else { return }

        morningBriefingDelivered = true

        let prompt = "[ENHANCED MORNING BRIEFING] [USER_JUST_ARRIVED] Deliver a warm, conversational morning briefing. Follow the morning-briefing-v2 skill instructions."

        NSLog("FaeScheduler: enhanced_morning_briefing — firing")
        _ = await handler(
            prompt,
            false, // Briefing should speak.
            "enhanced_morning_briefing",
            ["calendar", "reminders", "contacts", "mail", "notes", "activate_skill"],
            awarenessConfig.enabled && awarenessConfig.consentGrantedAt != nil
        )
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
        // When skills heartbeat is enabled, proposals are driven by heartbeat coaching.
        if hour == config.skillProposalsHour, minute < 2, !config.heartbeatEnabled {
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
        case "embedding_reindex": await runEmbeddingReindex()
        case "vault_backup":     await runVaultBackup()
        case "camera_presence_check":  await runCameraPresenceCheck()
        case "screen_activity_check":  await runScreenActivityCheck()
        case "overnight_work":         await runOvernightWork()
        case "enhanced_morning_briefing": await runEnhancedMorningBriefing()
        case "skills_heartbeat": await runSkillsHeartbeat()
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
            "stale_relationships", "skill_health_check", "embedding_reindex",
            "vault_backup", "camera_presence_check", "screen_activity_check",
            "overnight_work", "enhanced_morning_briefing", "skills_heartbeat",
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
