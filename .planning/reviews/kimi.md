Review this Swift macOS codebase git diff for:
1. Security issues (keychain access, data exposure, privilege escalation)
2. Error handling problems (force unwraps, missing guards)
3. Code quality (performance, maintainability, Swift idioms)
4. Architectural concerns (state management, concurrency, threading)
5. Memory safety issues (retain cycles, leaks)

Format each finding as:
[SEVERITY: A-F] file:line - category - description

Show all findings, sorted by severity.

DIFF:
diff --git a/native/macos/Fae/Sources/Fae/Core/FaeConfig.swift 
b/native/macos/Fae/Sources/Fae/Core/FaeConfig.swift
index 2e382f8..164334f 100644
--- a/native/macos/Fae/Sources/Fae/Core/FaeConfig.swift
+++ b/native/macos/Fae/Sources/Fae/Core/FaeConfig.swift
@@ -14,6 +14,7 @@ struct FaeConfig: Codable {
     var bargeIn: BargeInConfig = BargeInConfig()
     var memory: MemoryConfig = MemoryConfig()
     var speaker: SpeakerConfig = SpeakerConfig()
+    var scheduler: SchedulerConfig = SchedulerConfig()
     var userName: String?
     var onboarded: Bool = false
     var licenseAccepted: Bool = false
@@ -113,6 +114,13 @@ struct FaeConfig: Codable {
         var maxEnrollments: Int = 50
     }
 
+    // MARK: - Scheduler
+
+    struct SchedulerConfig: Codable {
+        var morningBriefingHour: Int = 8
+        var skillProposalsHour: Int = 11
+    }
+
     // MARK: - Model Selection
 
     /// Select the appropriate LLM model based on system RAM and preset.
@@ -125,6 +133,8 @@ struct FaeConfig: Codable {
         let totalGB = (totalMemoryBytes ?? 
ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
 
         switch preset.lowercased() {
+        case "qwen3_5_27b":
+            return ("mlx-community/Qwen3.5-27B-4bit", 65_536)
         case "qwen3_5_35b_a3b":
             return ("mlx-community/Qwen3.5-35B-A3B-4bit", 65_536)
         case "qwen3_8b":
@@ -441,6 +451,16 @@ struct FaeConfig: Codable {
                     config.memory.maxRecallResults = v
                 default: break
                 }
+            case "scheduler":
+                switch key {
+                case "morningBriefingHour":
+                    guard let v = parseInt(rawValue) else { throw 
ParseError.malformedValue(key: key, value: rawValue) }
+                    config.scheduler.morningBriefingHour = v
+                case "skillProposalsHour":
+                    guard let v = parseInt(rawValue) else { throw 
ParseError.malformedValue(key: key, value: rawValue) }
+                    config.scheduler.skillProposalsHour = v
+                default: break
+                }
             case "speaker":
                 switch key {
                 case "enabled":
@@ -541,6 +561,11 @@ struct FaeConfig: Codable {
         lines.append("maxRecallResults = \(memory.maxRecallResults)")
         lines.append("")
 
+        lines.append("")
+        lines.append("morningBriefingHour = \(scheduler.morningBriefingHour)")
+        lines.append("skillProposalsHour = \(scheduler.skillProposalsHour)")
+        lines.append("")
+
         lines.append("")
         lines.append("enabled = \(speaker.enabled ? "true" : "false")")
         lines.append("threshold = \(formatFloat(speaker.threshold))")
diff --git a/native/macos/Fae/Sources/Fae/Core/FaeCore.swift 
b/native/macos/Fae/Sources/Fae/Core/FaeCore.swift
index d191483..1d30c9c 100644
--- a/native/macos/Fae/Sources/Fae/Core/FaeCore.swift
+++ b/native/macos/Fae/Sources/Fae/Core/FaeCore.swift
@@ -109,12 +109,21 @@ final class FaeCore: ObservableObject, HostCommandSender {
                     memoryOrchestrator: orchestrator,
                     memoryStore: memoryStore
                 )
+
+                // Wire persistence store for scheduler state.
+                if let schedulerStore = try? 
Self.createSchedulerPersistenceStore() {
+                    await sched.configurePersistence(store: schedulerStore)
+                }
+
                 await sched.setSpeakHandler {  text in
                     await coordinator?.speakDirect(text)
                 }
                 await sched.start()
                 self.scheduler = sched
 
+                // Observe scheduler update notifications from 
SchedulerUpdateTool.
+                self.observeSchedulerUpdates()
+
                 pipelineState = .running
                 eventBus.send(.runtimeState(.started))
                 NSLog("FaeCore: pipeline started")
@@ -250,6 +259,39 @@ final class FaeCore: ObservableObject, HostCommandSender {
                 Task { await scheduler?.triggerTask(id: taskId) }
             }
 
+        case "scheduler.enable":
+            if let taskId = payload["id"] as? String {
+                Task { await scheduler?.setTaskEnabled(id: taskId, enabled: 
true) }
+            }
+
+        case "scheduler.disable":
+            if let taskId = payload["id"] as? String {
+                Task { await scheduler?.setTaskEnabled(id: taskId, enabled: 
false) }
+            }
+
+        case "scheduler.set_enabled":
+            if let taskId = payload["id"] as? String,
+               let enabled = payload["enabled"] as? Bool
+            {
+                Task { await scheduler?.setTaskEnabled(id: taskId, enabled: 
enabled) }
+            }
+
+        case "scheduler.status":
+            if let taskId = payload["id"] as? String {
+                Task {
+                    let status = await scheduler?.status(taskID: taskId) ?? [:]
+                    NSLog("FaeCore: scheduler.status %@", String(describing: 
status))
+                }
+            }
+
+        case "scheduler.history":
+            if let taskId = payload["id"] as? String {
+                Task {
+                    let history = await scheduler?.history(taskID: taskId, 
limit: 20) ?? []
+                    NSLog("FaeCore: scheduler.history %@ count=%d", taskId, 
history.count)
+                }
+            }
+
         case "data.delete_all":
             NSLog("FaeCore: data.delete_all — stub")
 
@@ -368,6 +410,32 @@ final class FaeCore: ObservableObject, HostCommandSender {
         return try SQLiteMemoryStore(path: dbPath)
     }
 
+    /// Scheduler persistence database path.
+    private static func createSchedulerPersistenceStore() throws -> 
SchedulerPersistenceStore {
+        let appSupport = FileManager.default.urls(
+            for: .applicationSupportDirectory, in: .userDomainMask
+        ).first!
+        let faeDir = appSupport.appendingPathComponent("fae")
+        let dbPath = faeDir.appendingPathComponent("scheduler.db").path
+        return try SchedulerPersistenceStore(path: dbPath)
+    }
+
+    /// Observe scheduler update notifications from SchedulerUpdateTool.
+    private func observeSchedulerUpdates() {
+        NotificationCenter.default.addObserver(
+            forName: .faeSchedulerUpdate,
+            object: nil,
+            queue: .main
+        ) {  notification in
+            guard let self,
+                  let userInfo = notification.userInfo,
+                  let taskId = userInfo["id"] as? String,
+                  let enabled = userInfo["enabled"] as? Bool
+            else { return }
+            Task { await self.scheduler?.setTaskEnabled(id: taskId, enabled: 
enabled) }
+        }
+    }
+
     private func configGetResponse(key: String) -> [String: Any] {
         switch key {
         case "voice_identity":
diff --git a/native/macos/Fae/Sources/Fae/Core/MLProtocols.swift 
b/native/macos/Fae/Sources/Fae/Core/MLProtocols.swift
index afd3627..b88bac5 100644
--- a/native/macos/Fae/Sources/Fae/Core/MLProtocols.swift
+++ b/native/macos/Fae/Sources/Fae/Core/MLProtocols.swift
@@ -63,6 +63,11 @@ extension TTSEngine {
     /// Default no-op for engines that don't support voice cloning.
     func loadVoice(referenceAudioURL: URL, referenceText: String?) async throws
{}
     var isVoiceLoaded: Bool { false }
+
+    /// Default implementation delegates to `synthesize(text:)` ignoring 
voiceInstruct.
+    func synthesize(text: String, voiceInstruct: String?) -> 
AsyncThrowingStream<AVAudioPCMBuffer, Error> {
+        synthesize(text: text)
+    }
 }
 
 /// Text embedding engine protocol for semantic memory search.
diff --git a/native/macos/Fae/Sources/Fae/Core/PersonalityManager.swift 
b/native/macos/Fae/Sources/Fae/Core/PersonalityManager.swift
index ad4fce8..4563e6a 100644
--- a/native/macos/Fae/Sources/Fae/Core/PersonalityManager.swift
+++ b/native/macos/Fae/Sources/Fae/Core/PersonalityManager.swift
@@ -273,6 +273,12 @@ enum PersonalityManager {
                 """)
         }
 
+        // 5b. Current date/time.
+        let dateFormatter = DateFormatter()
+        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
+        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
+        parts.append("Current date and time: \(dateFormatter.string(from: 
Date()))")
+
         // 6. Permission context.
         parts.append(PermissionStatusProvider.promptFragment())
 
diff --git a/native/macos/Fae/Sources/Fae/ML/CoreMLSpeakerEncoder.swift 
b/native/macos/Fae/Sources/Fae/ML/CoreMLSpeakerEncoder.swift
index e8e118a..56d61b7 100644
--- a/native/macos/Fae/Sources/Fae/ML/CoreMLSpeakerEncoder.swift
+++ b/native/macos/Fae/Sources/Fae/ML/CoreMLSpeakerEncoder.swift
@@ -107,6 +107,13 @@ actor CoreMLSpeakerEncoder: SpeakerEmbeddingEngine {
             throw MLEngineError.notLoaded("SpeakerEncoder: audio too short for 
mel spectrogram")
         }
 
+        // Liveness check (non-blocking — log only).
+        let liveness = Self.checkLiveness(mel: mel, numFrames: numFrames)
+        if liveness.isSuspicious {
+            NSLog("CoreMLSpeakerEncoder: liveness warning — low spectral 
variance (%.4f) and low high-freq ratio (%.4f), possible replay",
+                  liveness.spectralVariance, liveness.highFreqRatio)
+        }
+
         // Mel-spectral fallback: mean + std of each mel band → 256-dim vector.
         if usingMelFallback {
             return Self.melSpectralEmbed(mel: mel, numFrames: numFrames)
@@ -402,6 +409,80 @@ actor CoreMLSpeakerEncoder: SpeakerEmbeddingEngine {
         throw MLEngineError.notLoaded("SpeakerEncoder: no valid output tensor 
found")
     }
 
+    // MARK: - Liveness Heuristics
+
+    /// Result of basic replay/liveness checks on audio.
+    struct LivenessCheck: Sendable {
+        /// Variance of mel-band energy across frames (low = potential replay).
+        let spectralVariance: Float
+        /// Ratio of high-frequency energy to total (low = codec compression 
artifacts).
+        let highFreqRatio: Float
+        /// Whether the audio looks suspicious (not blocking — informational 
only).
+        let isSuspicious: Bool
+    }
+
+    /// Run lightweight liveness heuristics on a log-mel spectrogram.
+    ///
+    /// Checks for two replay indicators:
+    /// 1. **Spectral variance**: Real speech has dynamic formant variation 
across frames.
+    ///    Recordings played through speakers tend to be spectrally flatter.
+    /// 2. **High-frequency energy**: Codec compression (MP3, AAC, Opus) 
attenuates
+    ///    energy above ~16 kHz. Raw microphone input preserves full bandwidth.
+    ///
+    /// Returns a `LivenessCheck` with findings. Does NOT block embedding —
+    /// suspicion is logged for diagnostics only.
+    static func checkLiveness(mel: [Float], numFrames: Int) -> LivenessCheck {
+        guard numFrames > 1 else {
+            return LivenessCheck(spectralVariance: 0, highFreqRatio: 0, 
isSuspicious: false)
+        }
+
+        // 1. Spectral variance: compute per-frame energy, then variance across
frames.
+        var frameEnergies = [Float](repeating: 0, count: numFrames)
+        for f in 0..<numFrames {
+            var energy: Float = 0
+            for m in 0..<numMels {
+                energy += mel
+            }
+            frameEnergies = energy / Float(numMels)
+        }
+
+        var meanEnergy: Float = 0
+        vDSP_meanv(frameEnergies, 1, &meanEnergy, vDSP_Length(numFrames))
+
+        var sumSqDiff: Float = 0
+        for e in frameEnergies {
+            let diff = e - meanEnergy
+            sumSqDiff += diff * diff
+        }
+        let spectralVariance = sumSqDiff / Float(numFrames)
+
+        // 2. High-frequency energy ratio: compare top 1/4 mel bands vs total.
+        let highBandStart = numMels * 3 / 4  // top 32 of 128 bands
+        var totalEnergy: Float = 0
+        var highEnergy: Float = 0
+        for m in 0..<numMels {
+            var bandSum: Float = 0
+            let base = m * numFrames
+            vDSP_sve(Array(mel), 1, &bandSum, vDSP_Length(numFrames))
+            totalEnergy += abs(bandSum)
+            if m >= highBandStart {
+                highEnergy += abs(bandSum)
+            }
+        }
+        let highFreqRatio = totalEnergy > 1e-10 ? highEnergy / totalEnergy : 0
+
+        // Thresholds (empirically tuned — conservative to minimize false 
positives).
+        let lowVariance = spectralVariance < 0.05
+        let lowHighFreq = highFreqRatio < 0.02
+        let isSuspicious = lowVariance && lowHighFreq
+
+        return LivenessCheck(
+            spectralVariance: spectralVariance,
+            highFreqRatio: highFreqRatio,
+            isSuspicious: isSuspicious
+        )
+    }
+
     // MARK: - L2 Normalization
 
     private static func l2Normalize(_ vec: [Float]) -> [Float] {
diff --git a/native/macos/Fae/Sources/Fae/ML/SpeakerProfileStore.swift 
b/native/macos/Fae/Sources/Fae/ML/SpeakerProfileStore.swift
index 42b846b..efba6d2 100644
--- a/native/macos/Fae/Sources/Fae/ML/SpeakerProfileStore.swift
+++ b/native/macos/Fae/Sources/Fae/ML/SpeakerProfileStore.swift
@@ -16,6 +16,8 @@ actor SpeakerProfileStore {
         let id: String
         var label: String
         var embeddings: [[Float]]
+        /// Per-embedding timestamps (parallel to `embeddings`). Nil for legacy
profiles.
+        var embeddingDates: [Date]?
         var centroid: [Float]
         let enrolledAt: Date
         var lastSeen: Date
@@ -75,18 +77,23 @@ actor SpeakerProfileStore {
 
     /// Enroll a new speaker or add an embedding to an existing profile.
     func enroll(label: String, embedding: [Float]) {
+        let now = Date()
         if let idx = profiles.firstIndex(where: { $0.label == label }) {
             profiles.embeddings.append(embedding)
+            var dates = profiles.embeddingDates ?? []
+            dates.append(now)
+            profiles.embeddingDates = dates
             profiles.centroid = Self.averageEmbeddings(profiles.embeddings)
-            profiles.lastSeen = Date()
+            profiles.lastSeen = now
         } else {
             let profile = SpeakerProfile(
                 id: UUID().uuidString,
                 label: label,
                 embeddings: ,
+                embeddingDates: ,
                 centroid: embedding,
-                enrolledAt: Date(),
-                lastSeen: Date()
+                enrolledAt: now,
+                lastSeen: now
             )
             profiles.append(profile)
         }
@@ -100,9 +107,13 @@ actor SpeakerProfileStore {
         guard let idx = profiles.firstIndex(where: { $0.label == label }) else 
{ return }
         guard profiles.embeddings.count < max else { return }
 
+        let now = Date()
         profiles.embeddings.append(embedding)
+        var dates = profiles.embeddingDates ?? []
+        dates.append(now)
+        profiles.embeddingDates = dates
         profiles.centroid = Self.averageEmbeddings(profiles.embeddings)
-        profiles.lastSeen = Date()
+        profiles.lastSeen = now
         persist()
     }
 
@@ -112,6 +123,44 @@ actor SpeakerProfileStore {
         persist()
     }
 
+    /// Prune embeddings older than `maxAgeDays` from all profiles.
+    ///
+    /// Prevents centroid drift as a speaker's voice changes over time.
+    /// Profiles with no timestamps (legacy) are left untouched. Profiles
+    /// are never deleted — only their oldest embeddings are removed.
+    func pruneStaleEmbeddings(maxAgeDays: Int = 180) {
+        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
+        var changed = false
+
+        for idx in profiles.indices {
+            guard let dates = profiles.embeddingDates,
+                  dates.count == profiles.embeddings.count
+            else { continue }
+
+            // Keep embeddings newer than cutoff, but always retain at least 1.
+            var keepIndices = [Int]()
+            for (i, date) in dates.enumerated() where date >= cutoff {
+                keepIndices.append(i)
+            }
+            // Always keep the most recent embedding even if all are stale.
+            if keepIndices.isEmpty, let lastIdx = dates.indices.last {
+                keepIndices = 
+            }
+
+            if keepIndices.count < profiles.embeddings.count {
+                let prunedCount = profiles.embeddings.count - keepIndices.count
+                profiles.embeddings = keepIndices.map { profiles.embeddings[$0]
}
+                profiles.embeddingDates = keepIndices.map { dates[$0] }
+                profiles.centroid = Self.averageEmbeddings(profiles.embeddings)
+                changed = true
+                NSLog("SpeakerProfileStore: pruned %d stale embeddings from 
'%@'",
+                      prunedCount, profiles.label)
+            }
+        }
+
+        if changed { persist() }
+    }
+
     /// All enrolled profile labels.
     var enrolledLabels: [String] {
         profiles.map(\.label)
diff --git a/native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift 
b/native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift
index b0e19cb..e9429c1 100644
--- a/native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift
+++ b/native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift
@@ -32,12 +32,21 @@ actor MemoryOrchestrator {
             guard !rerankedHits.isEmpty else { return nil }
 
             let minConfidence: Float = 0.5
+            let now = UInt64(Date().timeIntervalSince1970)
+
+            // Filter out stale records (past their staleAfterSecs expiry).
+            let freshHits = rerankedHits.filter { hit in
+                guard let staleSecs = hit.record.staleAfterSecs,
+                      hit.record.createdAt > 0
+                else { return true }
+                return (hit.record.createdAt + staleSecs) > now
+            }
 
             // Split durable vs episode hits.
-            let durableHits = rerankedHits.filter {
+            let durableHits = freshHits.filter {
                 $0.record.kind != .episode && $0.record.confidence >= 
minConfidence
             }
-            let episodeHits = rerankedHits.filter {
+            let episodeHits = freshHits.filter {
                 $0.record.kind == .episode
                     && $0.score >= MemoryConstants.episodeThresholdLexical
             }
@@ -94,7 +103,9 @@ actor MemoryOrchestrator {
                 text: episodeText,
                 confidence: MemoryConstants.episodeConfidence,
                 sourceTurnId: turnId,
-                tags: ["turn"]
+                tags: ["turn"],
+                importanceScore: 0.30,
+                staleAfterSecs: 7_776_000  // 90 days
             )
             report.episodeId = episode.id
 
@@ -116,7 +127,8 @@ actor MemoryOrchestrator {
                         text: fact,
                         confidence: MemoryConstants.factRememberConfidence,
                         sourceTurnId: turnId,
-                        tags: ["remembered"]
+                        tags: ["remembered"],
+                        importanceScore: 0.80
                     )
                     report.extractedCount += 1
                 }
@@ -136,12 +148,17 @@ actor MemoryOrchestrator {
 
             // 5. Parse preference statements.
             if let pref = extractPreference(from: lower, fullText: userText) {
+                // Check for contradiction with existing preferences.
+                try await supersedeContradiction(
+                    tag: "preference", newText: pref, sourceTurnId: turnId
+                )
                 _ = try await store.insertRecord(
                     kind: .profile,
                     text: pref,
                     confidence: MemoryConstants.profilePreferenceConfidence,
                     sourceTurnId: turnId,
-                    tags: ["preference"]
+                    tags: ["preference"],
+                    importanceScore: 0.85
                 )
                 report.extractedCount += 1
             }
@@ -153,7 +170,8 @@ actor MemoryOrchestrator {
                     text: interest,
                     confidence: MemoryConstants.profilePreferenceConfidence,
                     sourceTurnId: turnId,
-                    tags: ["interest"]
+                    tags: ["interest"],
+                    importanceScore: 0.70
                 )
                 report.extractedCount += 1
             }
@@ -165,7 +183,9 @@ actor MemoryOrchestrator {
                     text: commitment,
                     confidence: MemoryConstants.factConversationalConfidence,
                     sourceTurnId: turnId,
-                    tags: ["commitment"]
+                    tags: ["commitment"],
+                    importanceScore: 0.90,
+                    staleAfterSecs: 2_592_000  // 30 days
                 )
                 report.extractedCount += 1
             }
@@ -177,7 +197,9 @@ actor MemoryOrchestrator {
                     text: event,
                     confidence: MemoryConstants.factConversationalConfidence,
                     sourceTurnId: turnId,
-                    tags: ["event"]
+                    tags: ["event"],
+                    importanceScore: 0.85,
+                    staleAfterSecs: 604_800  // 7 days
                 )
                 report.extractedCount += 1
             }
@@ -189,7 +211,8 @@ actor MemoryOrchestrator {
                     text: person,
                     confidence: MemoryConstants.factConversationalConfidence,
                     sourceTurnId: turnId,
-                    tags: ["person"]
+                    tags: ["person"],
+                    importanceScore: 0.75
                 )
                 report.extractedCount += 1
             }
@@ -216,6 +239,7 @@ actor MemoryOrchestrator {
     // MARK: - Private Helpers
 
     /// Blend lexical and semantic ranking, with safe fallback to lexical 
ordering.
+    /// Uses cached embeddings when available to avoid recomputation.
     private func rerankHitsIfPossible(query: String, hits: [MemorySearchHit]) 
async -> [MemorySearchHit] {
         guard !hits.isEmpty else { return [] }
 
@@ -235,7 +259,13 @@ actor MemoryOrchestrator {
             reranked.reserveCapacity(hits.count)
 
             for hit in hits {
-                let recordEmbedding = try await embeddingEngine.embed(text: 
hit.record.text)
+                // Use cached embedding if available, otherwise compute.
+                let recordEmbedding: [Float]
+                if let cached = hit.record.cachedEmbedding, !cached.isEmpty {
+                    recordEmbedding = cached
+                } else {
+                    recordEmbedding = try await embeddingEngine.embed(text: 
hit.record.text)
+                }
                 let semantic = cosineSimilarity(queryEmbedding, 
recordEmbedding)
                 let blended = (lexicalWeight * hit.score) + (semanticWeight * 
semantic)
                 reranked.append(MemorySearchHit(record: hit.record, score: 
blended))
@@ -274,6 +304,44 @@ actor MemoryOrchestrator {
         sqrt(vector.reduce(Float(0)) { $0 + ($1 * $1) })
     }
 
+    /// Supersede contradicting records for a given tag when new text diverges 
semantically.
+    private func supersedeContradiction(tag: String, newText: String, 
sourceTurnId: String) async throws {
+        let existing = try await store.findActiveByTag(tag)
+        guard !existing.isEmpty else { return }
+
+        do {
+            if !(await embeddingEngine.isLoaded) {
+                try await embeddingEngine.load(modelID: "foundation-hash-384")
+            }
+            let newEmbedding = try await embeddingEngine.embed(text: newText)
+
+            for old in existing {
+                let oldEmbedding: [Float]
+                if let cached = old.cachedEmbedding, !cached.isEmpty {
+                    oldEmbedding = cached
+                } else {
+                    oldEmbedding = try await embeddingEngine.embed(text: 
old.text)
+                }
+                let similarity = cosineSimilarity(newEmbedding, oldEmbedding)
+                if similarity < 0.5 {
+                    // Low similarity with same tag = contradiction → 
supersede.
+                    _ = try await store.supersedeRecord(
+                        oldId: old.id,
+                        newText: newText,
+                        confidence: old.confidence,
+                        sourceTurnId: sourceTurnId,
+                        tags: old.tags,
+                        note: "contradiction detected (cosine=\(String(format: 
"%.2f", similarity)))"
+                    )
+                    NSLog("MemoryOrchestrator: superseded contradicting record 
%@ (tag=%@, cos=%.2f)",
+                          old.id, tag, similarity)
+                }
+            }
+        } catch {
+            NSLog("MemoryOrchestrator: contradiction check error: %@", 
error.localizedDescription)
+        }
+    }
+
     /// Forget records matching a query.
     private func forgetMatching(query: String) async throws -> Int {
         let hits = try await store.search(query: query, limit: 5)
@@ -292,7 +360,8 @@ actor MemoryOrchestrator {
         confidence: Float,
         sourceTurnId: String,
         allTags: [String],
-        report: inout MemoryCaptureReport
+        report: inout MemoryCaptureReport,
+        importanceScore: Float = 1.0
     ) async throws {
         let existing = try await store.findActiveByTag(tag)
 
@@ -312,7 +381,8 @@ actor MemoryOrchestrator {
                 text: text,
                 confidence: confidence,
                 sourceTurnId: sourceTurnId,
-                tags: allTags
+                tags: allTags,
+                importanceScore: importanceScore
             )
             report.extractedCount += 1
         }
diff --git a/native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift 
b/native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift
index b60edf8..ea3a130 100644
--- a/native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift
+++ b/native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift
@@ -48,6 +48,7 @@ struct MemoryRecord: Sendable {
     var importanceScore: Float?
     var staleAfterSecs: UInt64?
     var metadata: String?
+    var cachedEmbedding: [Float]?
 }
 
 struct MemoryAuditEntry: Sendable {
@@ -73,7 +74,7 @@ struct MemoryCaptureReport: Sendable {
 // MARK: - Constants
 
 enum MemoryConstants {
-    static let schemaVersion: UInt32 = 3
+    static let schemaVersion: UInt32 = 4
     static let maxRecordTextLen: Int = 32_768
     static let truncationSuffix: String = " "
 
@@ -87,6 +88,7 @@ enum MemoryConstants {
     // Lexical scoring
     static let scoreEmptyQueryBaseline: Float = 0.20
     static let scoreConfidenceWeight: Float = 0.20
+    static let scoreImportanceWeight: Float = 0.15
     static let scoreFreshnessWeight: Float = 0.10
     static let scoreKindBonusProfile: Float = 0.05
     static let scoreKindBonusFact: Float = 0.03
@@ -140,10 +142,22 @@ func scoreRecord(_ record: MemoryRecord, queryTokens: 
[String]) -> Float {
 
     score += MemoryConstants.scoreConfidenceWeight * min(max(record.confidence,
0), 1)
 
+    // Importance scoring — use stored importanceScore when available.
+    if let importance = record.importanceScore {
+        score += MemoryConstants.scoreImportanceWeight * min(max(importance, 
0), 1)
+    }
+
+    // Exponential temporal decay with kind-gated half-lives.
     let now = UInt64(Date().timeIntervalSince1970)
     if record.updatedAt > 0, record.updatedAt <= now {
         let ageDays = Float(now - record.updatedAt) / 
MemoryConstants.secsPerDay
-        let freshness = 1.0 / (1.0 + ageDays)
+        let halfLife: Float = switch record.kind {
+        case .episode: 30
+        case .fact, .interest, .commitment, .event, .person: 180
+        case .profile: 365
+        }
+        let decay = exp(-0.693 * ageDays / halfLife)
+        let freshness = 0.7 + 0.3 * decay  // floors at 0.7 so old memories 
still surface
         score += MemoryConstants.scoreFreshnessWeight * freshness
     }
 
diff --git a/native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift 
b/native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift
index 420ccd0..d9769d4 100644
--- a/native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift
+++ b/native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift
@@ -53,9 +53,42 @@ actor SQLiteMemoryStore {
                 updated_at       INTEGER NOT NULL DEFAULT 0,
                 importance_score REAL,
                 stale_after_secs INTEGER,
-                metadata         TEXT
+                metadata         TEXT,
+                embedding        BLOB
             )
             """)
+
+        // Migration: add embedding column if missing (v3 → v4).
+        let columns = try Row.fetchAll(db, sql: "PRAGMA 
table_info(memory_records)")
+        let columnNames = Set(columns.map { $0["name"] as String })
+        if !columnNames.contains("embedding") {
+            try db.execute(sql: "ALTER TABLE memory_records ADD COLUMN 
embedding BLOB")
+        }
+
+        // FTS5 full-text index for fast candidate selection.
+        try db.execute(sql: """
+            CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
+                text, content='memory_records', content_rowid='rowid'
+            )
+            """)
+
+        // Triggers to keep FTS in sync.
+        try db.execute(sql: """
+            CREATE TRIGGER IF NOT EXISTS memory_fts_insert AFTER INSERT ON 
memory_records BEGIN
+                INSERT INTO memory_fts(rowid, text) VALUES (new.rowid, 
new.text);
+            END
+            """)
+        try db.execute(sql: """
+            CREATE TRIGGER IF NOT EXISTS memory_fts_delete AFTER DELETE ON 
memory_records BEGIN
+                INSERT INTO memory_fts(memory_fts, rowid, text) 
VALUES('delete', old.rowid, old.text);
+            END
+            """)
+        try db.execute(sql: """
+            CREATE TRIGGER IF NOT EXISTS memory_fts_update AFTER UPDATE OF text
ON memory_records BEGIN
+                INSERT INTO memory_fts(memory_fts, rowid, text) 
VALUES('delete', old.rowid, old.text);
+                INSERT INTO memory_fts(rowid, text) VALUES (new.rowid, 
new.text);
+            END
+            """)
         try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_records_status ON 
memory_records(status)")
         try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_records_kind ON 
memory_records(kind)")
         try db.execute(
@@ -95,7 +128,10 @@ actor SQLiteMemoryStore {
         text: String,
         confidence: Float,
         sourceTurnId: String?,
-        tags: [String]
+        tags: [String],
+        importanceScore: Float? = nil,
+        staleAfterSecs: UInt64? = nil,
+        embedding: [Float]? = nil
     ) throws -> MemoryRecord {
         let now = UInt64(Date().timeIntervalSince1970)
         let record = MemoryRecord(
@@ -107,17 +143,23 @@ actor SQLiteMemoryStore {
             sourceTurnId: sourceTurnId,
             tags: tags,
             createdAt: now,
-            updatedAt: now
+            updatedAt: now,
+            importanceScore: importanceScore,
+            staleAfterSecs: staleAfterSecs
         )
 
+        let embeddingData: Data? = embedding.map { floats in
+            floats.withUnsafeBufferPointer { Data(buffer: $0) }
+        }
+
         try dbQueue.write { db in
             let tagsJSON = Self.encodeTags(tags)
             try db.execute(
                 sql: """
                     INSERT INTO memory_records
                         (id, kind, status, text, confidence, source_turn_id, 
tags, supersedes,
-                         created_at, updated_at, importance_score, 
stale_after_secs, metadata)
-                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
+                         created_at, updated_at, importance_score, 
stale_after_secs, metadata, embedding)
+                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                     """,
                 arguments: [
                     record.id, record.kind.rawValue, record.status.rawValue,
@@ -126,6 +168,7 @@ actor SQLiteMemoryStore {
                     record.createdAt, record.updatedAt,
                     record.importanceScore.map { Double($0) },
                     record.staleAfterSecs, record.metadata,
+                    embeddingData,
                 ]
             )
 
@@ -225,12 +268,27 @@ actor SQLiteMemoryStore {
         }
     }
 
-    // MARK: - Search (Lexical)
+    // MARK: - Search (FTS5 + Lexical Scoring)
 
     func search(query: String, limit: Int, includeInactive: Bool = false) 
throws -> [MemorySearchHit] {
-        let records = try listRecords(includeInactive: includeInactive)
         let queryTokens = tokenizeForSearch(query)
 
+        // Try FTS5 candidate selection first for efficiency.
+        let candidates: [MemoryRecord]
+        if !queryTokens.isEmpty {
+            candidates = try ftsSearch(query: query, limit: max(limit * 5, 50),
includeInactive: includeInactive)
+        } else {
+            candidates = []
+        }
+
+        // Fall back to full scan if FTS returned too few results or query is 
empty.
+        let records: [MemoryRecord]
+        if candidates.count < limit {
+            records = try listRecords(includeInactive: includeInactive)
+        } else {
+            records = candidates
+        }
+
         var hits = records.map { record in
             MemorySearchHit(record: record, score: scoreRecord(record, 
queryTokens: queryTokens))
         }
@@ -238,6 +296,27 @@ actor SQLiteMemoryStore {
         return Array(hits.prefix(limit))
     }
 
+    /// FTS5-based candidate selection — returns records matching the query 
text.
+    private func ftsSearch(query: String, limit: Int, includeInactive: Bool) 
throws -> [MemoryRecord] {
+        try dbQueue.read { db in
+            // Escape FTS5 special characters and form a simple query.
+            let ftsQuery = tokenizeForSearch(query).joined(separator: " OR ")
+            guard !ftsQuery.isEmpty else { return [] }
+
+            let statusFilter = includeInactive ? "" : "AND r.status = 'active'"
+            let sql = """
+                SELECT r.* FROM memory_records r
+                INNER JOIN memory_fts f ON f.rowid = r.rowid
+                WHERE memory_fts MATCH ?
+                \(statusFilter)
+                ORDER BY rank
+                LIMIT ?
+                """
+            let rows = try Row.fetchAll(db, sql: sql, arguments: )
+            return rows.map { Self.recordFromRow($0) }
+        }
+    }
+
     // MARK: - List
 
     func listRecords(includeInactive: Bool = false) throws -> [MemoryRecord] {
@@ -269,6 +348,23 @@ actor SQLiteMemoryStore {
         }
     }
 
+    /// Find active records of a specific kind.
+    func findActiveByKind(_ kind: MemoryKind, limit: Int = 20) throws -> 
[MemoryRecord] {
+        try dbQueue.read { db in
+            let rows = try Row.fetchAll(
+                db,
+                sql: """
+                    SELECT * FROM memory_records
+                    WHERE status = 'active' AND kind = ?
+                    ORDER BY updated_at DESC
+                    LIMIT ?
+                    """,
+                arguments: 
+            )
+            return rows.map { Self.recordFromRow($0) }
+        }
+    }
+
     /// Fetch the most recent active records, ordered by updated_at descending.
     func recentRecords(limit: Int) throws -> [MemoryRecord] {
         try dbQueue.read { db in
@@ -328,6 +424,16 @@ actor SQLiteMemoryStore {
         let tagsStr: String = row["tags"]
         let tags = decodeTags(tagsStr)
 
+        var cachedEmbedding: [Float]?
+        if let data = row["embedding"] as? Data, !data.isEmpty {
+            cachedEmbedding = data.withUnsafeBytes { buffer in
+                guard let baseAddress = buffer.baseAddress else { return nil }
+                let count = data.count / MemoryLayout<Float>.size
+                let floatBuffer = baseAddress.assumingMemoryBound(to: 
Float.self)
+                return Array(UnsafeBufferPointer(start: floatBuffer, count: 
count))
+            }
+        }
+
         return MemoryRecord(
             id: row["id"],
             kind: MemoryKind(rawValue: row["kind"] as String) ?? .fact,
@@ -341,7 +447,8 @@ actor SQLiteMemoryStore {
             updatedAt: UInt64(row["updated_at"] as Int64),
             importanceScore: (row["importance_score"] as Double?).map { 
Float($0) },
             staleAfterSecs: (row["stale_after_secs"] as Int64?).map { 
UInt64($0) },
-            metadata: row["metadata"]
+            metadata: row["metadata"],
+            cachedEmbedding: cachedEmbedding
         )
     }
 
diff --git a/native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift 
b/native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift
index c0c9421..3d3f641 100644
--- a/native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift
+++ b/native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift
@@ -50,6 +50,7 @@ actor PipelineCoordinator {
     private let registry: ToolRegistry
     private let speakerEncoder: CoreMLSpeakerEncoder?
     private let speakerProfileStore: SpeakerProfileStore?
+    private let toolAnalytics: ToolAnalytics?
 
     // MARK: - Pipeline State
 
@@ -88,6 +89,7 @@ actor PipelineCoordinator {
 
     private var pipelineStartedAt: Date?
     private var firstAudioLatencyEmitted: Bool = false
+    private let instrumentation = PipelineInstrumentation()
 
     struct PendingBargeIn {
         var capturedAt: Date
@@ -115,7 +117,8 @@ actor PipelineCoordinator {
         approvalManager: ApprovalManager? = nil,
         registry: ToolRegistry,
         speakerEncoder: CoreMLSpeakerEncoder? = nil,
-        speakerProfileStore: SpeakerProfileStore? = nil
+        speakerProfileStore: SpeakerProfileStore? = nil,
+        toolAnalytics: ToolAnalytics? = nil
     ) {
         self.eventBus = eventBus
         self.capture = capture
@@ -130,6 +133,7 @@ actor PipelineCoordinator {
         self.registry = registry
         self.speakerEncoder = speakerEncoder
         self.speakerProfileStore = speakerProfileStore
+        self.toolAnalytics = toolAnalytics
 
         // Configure VAD from config.
         vad.threshold = config.vad.threshold
@@ -566,8 +570,15 @@ actor PipelineCoordinator {
                 if roleplayActive {
                     let segments = voiceTagStripper.process(visible)
                     for segment in segments {
-                        let voice = await segment.character.asyncFlatMap {
-                            await 
RoleplaySessionStore.shared.voiceForCharacter($0)
+                        let voice: String?
+                        if let character = segment.character {
+                            let matched = await 
RoleplaySessionStore.shared.voiceForCharacter(character)
+                            if matched == nil {
+                                NSLog("PipelineCoordinator: unassigned 
character '%@' — using narrator voice", character)
+                            }
+                            voice = matched
+                        } else {
+                            voice = nil
                         }
                         let cleaned = 
TextProcessing.stripNonSpeechChars(segment.text)
                         if !cleaned.isEmpty {
@@ -624,8 +635,15 @@ actor PipelineCoordinator {
                 let voiceRemaining = voiceTagStripper.process(remaining) + 
voiceTagStripper.flush()
                 var spokeSomething = false
                 for segment in voiceRemaining {
-                    let voice = await segment.character.asyncFlatMap {
-                        await RoleplaySessionStore.shared.voiceForCharacter($0)
+                    let voice: String?
+                    if let character = segment.character {
+                        let matched = await 
RoleplaySessionStore.shared.voiceForCharacter(character)
+                        if matched == nil {
+                            NSLog("PipelineCoordinator: unassigned character 
'%@' — using narrator voice", character)
+                        }
+                        voice = matched
+                    } else {
+                        voice = nil
                     }
                     let cleaned = 
TextProcessing.stripNonSpeechChars(segment.text)
                     if !cleaned.isEmpty {
@@ -920,22 +938,53 @@ actor PipelineCoordinator {
             return .error("Unknown tool: \(call.name)")
         }
 
-        // Check approval if required.
-        if tool.requiresApproval {
+        let voiceDecision = VoiceIdentityPolicy.evaluateSensitiveAction(
+            config: config.speaker,
+            isOwner: currentSpeakerIsOwner,
+            risk: tool.riskLevel,
+            toolName: call.name
+        )
+
+        switch voiceDecision {
+        case .allow:
+            break
+        case .requireStepUp(let message):
             if let manager = approvalManager {
                 let approved = await manager.requestApproval(
                     toolName: call.name,
-                    description: "Execute \(call.name)"
+                    description: "Step-up: \(message)"
                 )
                 if !approved {
                     return .error("Tool execution denied by user.")
                 }
+            } else {
+                return .error(message)
             }
+        case .deny(let message):
+            return .error(message)
         }
 
-        // Execute with timeout.
+        // Risk policy + approval routing.
+        let decision = ToolRiskPolicy.decision(for: tool)
+        if case .requireApproval(let reason) = decision {
+            if let manager = approvalManager {
+                let approved = await manager.requestApproval(
+                    toolName: call.name,
+                    description: "Execute \(call.name) — \(reason)"
+                )
+                if !approved {
+                    return .error("Tool execution denied by user.")
+                }
+            } else {
+                return .error("Tool requires approval, but no approval manager 
is available.")
+            }
+        }
+
+        // Execute with timeout and analytics.
+        let startTime = Date()
+        let result: ToolResult
         do {
-            return try await withThrowingTaskGroup(of: ToolResult.self) { group
in
+            result = try await withThrowingTaskGroup(of: ToolResult.self) { 
group in
                 group.addTask {
                     try await tool.execute(input: call.arguments)
                 }
@@ -943,13 +992,33 @@ actor PipelineCoordinator {
                     try await Task.sleep(nanoseconds: 
UInt64(Self.toolTimeoutSeconds * 1_000_000_000))
                     return .error("Tool timed out after 
\(Int(Self.toolTimeoutSeconds))s")
                 }
-                let result = try await group.next()!
+                let r = try await group.next()!
                 group.cancelAll()
-                return result
+                return r
             }
         } catch {
+            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
+            if let analytics = toolAnalytics {
+                await analytics.record(
+                    toolName: call.name, success: false, latencyMs: latencyMs,
+                    approved: true, error: error.localizedDescription
+                )
+            }
             return .error("Tool error: \(error.localizedDescription)")
         }
+
+        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
+        if let analytics = toolAnalytics {
+            await analytics.record(
+                toolName: call.name,
+                success: !result.isError,
+                latencyMs: latencyMs,
+                approved: true,
+                error: result.isError ? result.output : nil
+            )
+        }
+
+        return result
     }
 
     // MARK: - Helpers
diff --git a/native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift 
b/native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift
index fe46cfc..219c98a 100644
--- a/native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift
+++ b/native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift
@@ -10,8 +10,17 @@ actor FaeScheduler {
     private let eventBus: FaeEventBus
     private let memoryOrchestrator: MemoryOrchestrator?
     private let memoryStore: SQLiteMemoryStore?
+    private var config: FaeConfig.SchedulerConfig
     private var timers: [String: DispatchSourceTimer] = [:]
     private var isRunning = false
+    private var disabledTaskIDs: Set<String> = []
+    private var runHistory: [String: [Date]] = [:]
+
+    /// Persistence store for scheduler state (optional, injected by FaeCore).
+    private var persistenceStore: SchedulerPersistenceStore?
+
+    /// Task run ledger for idempotency and retry tracking.
+    private(set) var taskRunLedger: TaskRunLedger = TaskRunLedger()
 
     /// Closure to make Fae speak — set by FaeCore after pipeline is ready.
     var speakHandler: (@Sendable (String) async -> Void)?
@@ -19,14 +28,19 @@ actor FaeScheduler {
     /// Daily proactive interjection counter, reset at midnight.
     private var proactiveInterjectionCount: Int = 0
 
+    /// Tracks which interests have already had skill proposals surfaced.
+    private var suggestedInterestIDs: Set<String> = []
+
     init(
         eventBus: FaeEventBus,
         memoryOrchestrator: MemoryOrchestrator? = nil,
-        memoryStore: SQLiteMemoryStore? = nil
+        memoryStore: SQLiteMemoryStore? = nil,
+        config: FaeConfig.SchedulerConfig = FaeConfig.SchedulerConfig()
     ) {
         self.eventBus = eventBus
         self.memoryOrchestrator = memoryOrchestrator
         self.memoryStore = memoryStore
+        self.config = config
     }
 
     /// Set the speak handler (must be called before start for morning 
briefings to work).
@@ -34,6 +48,23 @@ actor FaeScheduler {
         speakHandler = handler
     }
 
+    /// Configure persistence — creates a persistence-backed ledger and loads 
saved state.
+    func configurePersistence(store: SchedulerPersistenceStore) async {
+        self.persistenceStore = store
+        self.taskRunLedger = TaskRunLedger(store: store)
+
+        // Load persisted disabled task IDs.
+        do {
+            let saved = try await store.loadDisabledTaskIDs()
+            disabledTaskIDs = saved
+            if !saved.isEmpty {
+                NSLog("FaeScheduler: loaded %d disabled tasks from 
persistence", saved.count)
+            }
+        } catch {
+            NSLog("FaeScheduler: failed to load disabled tasks: %@", 
error.localizedDescription)
+        }
+    }
+
     // MARK: - Lifecycle
 
     func start() {
@@ -81,30 +112,78 @@ actor FaeScheduler {
         NSLog("FaeScheduler: memory_reflect — running")
         guard let store = memoryStore else { return }
         do {
-            // Query recent active records and look for near-duplicates by text
overlap.
             let records = try await store.recentRecords(limit: 100)
             var mergedCount = 0
-            var seen: Set<String> = []
-
-            for record in records where record.status == .active && record.kind
!= .episode {
-                let key = 
record.text.lowercased().prefix(80).trimmingCharacters(in: .whitespaces)
-                if seen.contains(key) {
-                    // Duplicate found — soft-forget the older one.
-                    try await store.forgetSoftRecord(id: record.id, note: 
"memory_reflect: duplicate")
-                    mergedCount += 1
-                } else {
-                    seen.insert(key)
+
+            // Group non-episode active records by kind for pairwise 
comparison.
+            let durable = records.filter { $0.status == .active && $0.kind != 
.episode }
+            let grouped = Dictionary(grouping: durable) { $0.kind }
+
+            for (_, group) in grouped where group.count > 1 {
+                var superseded: Set<String> = []
+                for i in 0 ..< group.count {
+                    guard !superseded.contains(group.id) else { continue }
+                    for j in (i + 1) ..< group.count {
+                        guard !superseded.contains(group.id) else { continue }
+
+                        // Use cached embeddings if available, fall back to 
text prefix match.
+                        let similar: Bool
+                        if let embA = group.cachedEmbedding, !embA.isEmpty,
+                           let embB = group.cachedEmbedding, !embB.isEmpty
+                        {
+                            similar = cosineSimilarity(embA, embB) > 0.92
+                        } else {
+                            let keyA = group.text.lowercased().prefix(80)
+                                .trimmingCharacters(in: .whitespaces)
+                            let keyB = group.text.lowercased().prefix(80)
+                                .trimmingCharacters(in: .whitespaces)
+                            similar = keyA == keyB
+                        }
+
+                        if similar {
+                            // Keep the higher-confidence record, supersede the
other.
+                            let (keep, drop) = group.confidence >= 
group.confidence
+                                ? (group, group)
+                                : (group, group)
+                            try await store.forgetSoftRecord(
+                                id: drop.id,
+                                note: "memory_reflect: semantic duplicate of 
\(keep.id)"
+                            )
+                            superseded.insert(drop.id)
+                            mergedCount += 1
+                        }
+                    }
                 }
             }
 
             if mergedCount > 0 {
-                NSLog("FaeScheduler: memory_reflect — cleaned %d duplicates", 
mergedCount)
+                NSLog("FaeScheduler: memory_reflect — cleaned %d semantic 
duplicates", mergedCount)
             }
         } catch {
             NSLog("FaeScheduler: memory_reflect — error: %@", 
error.localizedDescription)
         }
     }
 
+    /// Cosine similarity between two float vectors.
+    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
+        let length = min(lhs.count, rhs.count)
+        guard length > 0 else { return 0 }
+
+        var dot: Float = 0
+        var lhsSq: Float = 0
+        var rhsSq: Float = 0
+
+        for i in 0 ..< length {
+            dot += lhs * rhs
+            lhsSq += lhs * lhs
+            rhsSq += rhs * rhs
+        }
+
+        let denom = sqrt(lhsSq) * sqrt(rhsSq)
+        guard denom > 0 else { return 0 }
+        return dot / denom
+    }
+
     private func runMemoryReindex() async {
         NSLog("FaeScheduler: memory_reindex — running")
         do {
@@ -149,51 +228,130 @@ actor FaeScheduler {
 
     private func runMorningBriefing() async {
         NSLog("FaeScheduler: morning_briefing — running")
-        guard let orchestrator = memoryOrchestrator else { return }
+        guard let store = memoryStore else { return }
 
-        // 1. Gather recent memories (commitments, events, people).
-        let commitmentContext = await orchestrator.recall(query: "upcoming 
deadlines and commitments")
-        let eventContext = await orchestrator.recall(query: "upcoming events 
and dates")
-        let peopleContext = await orchestrator.recall(query: "people to check 
in with")
+        do {
+            var items: [String] = []
+
+            // 1. Query commitments — extract actual text.
+            let commitments = try await store.findActiveByKind(.commitment, 
limit: 5)
+            for record in commitments {
+                let text = record.text
+                    .replacingOccurrences(of: "User commitment: ", with: "")
+                    .trimmingCharacters(in: .whitespacesAndNewlines)
+                if !text.isEmpty {
+                    items.append("you mentioned \(text)")
+                }
+            }
 
-        // 2. Compile a brief summary.
-        var items: [String] = []
-        if let ctx = commitmentContext, !ctx.isEmpty {
-            items.append("You have some upcoming commitments I recall.")
-        }
-        if let ctx = eventContext, !ctx.isEmpty {
-            items.append("There are events coming up worth noting.")
-        }
-        if let ctx = peopleContext, !ctx.isEmpty {
-            items.append("There are people you might want to check in with.")
-        }
+            // 2. Query events — include details.
+            let events = try await store.findActiveByKind(.event, limit: 3)
+            for record in events {
+                let text = record.text
+                    .replacingOccurrences(of: "User event: ", with: "")
+                    .trimmingCharacters(in: .whitespacesAndNewlines)
+                if !text.isEmpty {
+                    items.append(text)
+                }
+            }
 
-        guard !items.isEmpty else {
-            NSLog("FaeScheduler: morning_briefing — nothing to report")
-            return
-        }
+            // 3. Query people — mention specific names.
+            let people = try await store.findActiveByKind(.person, limit: 2)
+            let now = UInt64(Date().timeIntervalSince1970)
+            let sevenDays: UInt64 = 7 * 24 * 3600
+            for record in people where record.updatedAt > 0 && (now - 
record.updatedAt) > sevenDays {
+                let name = extractPersonName(from: record.text)
+                if !name.isEmpty {
+                    items.append("it's been a while since you mentioned 
\(name)")
+                }
+            }
+
+            guard !items.isEmpty else {
+                NSLog("FaeScheduler: morning_briefing — nothing meaningful to 
report")
+                return
+            }
+
+            // Limit to 3 items max.
+            let selected = Array(items.prefix(3))
+            let briefing: String
+            if selected.count == 1 {
+                briefing = "Good morning! Just a heads up — \(selected[0])."
+            } else {
+                let joined = selected.dropLast().joined(separator: ", ")
+                briefing = "Good morning! Just a heads up — \(joined), and 
\(selected.last ?? "")."
+            }
 
-        let briefing = "Good morning! " + items.joined(separator: " ") + " Want
me to go into detail on any of these?"
-        NSLog("FaeScheduler: morning_briefing — delivering %d items", 
items.count)
+            NSLog("FaeScheduler: morning_briefing — delivering %d items", 
selected.count)
+            if let speak = speakHandler {
+                await speak(briefing)
+            }
+        } catch {
+            NSLog("FaeScheduler: morning_briefing — error: %@", 
error.localizedDescription)
+        }
+    }
 
-        // 3. Speak the briefing if the handler is wired.
-        if let speak = speakHandler {
-            await speak(briefing)
+    /// Extract a person's name from memory text like "User knows: my sister 
Sarah works at..."
+    private func extractPersonName(from text: String) -> String {
+        let cleaned = text
+            .replacingOccurrences(of: "User knows: ", with: "")
+            .trimmingCharacters(in: .whitespacesAndNewlines)
+
+        // Try to find a capitalized name word after the relationship prefix.
+        let relationshipPrefixes = [
+            "my wife ", "my husband ", "my partner ",
+            "my sister ", "my brother ", "my mom ", "my mum ", "my dad ",
+            "my daughter ", "my son ", "my friend ", "my colleague ",
+            "my boss ", "my manager ", "my girlfriend ", "my boyfriend ",
+        ]
+        let lower = cleaned.lowercased()
+        for prefix in relationshipPrefixes {
+            if lower.hasPrefix(prefix) {
+                let afterPrefix = String(cleaned.dropFirst(prefix.count))
+                let firstWord = afterPrefix.prefix(while: { $0.isLetter || $0 
== "-" })
+                    .trimmingCharacters(in: .whitespaces)
+                if !firstWord.isEmpty {
+                    return firstWord
+                }
+            }
         }
+
+        // Fall back to first 30 chars.
+        return String(cleaned.prefix(30))
     }
 
     private func runSkillProposals() async {
         NSLog("FaeScheduler: skill_proposals — running")
         guard let store = memoryStore else { return }
         do {
-            // Look for interest-type memories that might benefit from a 
dedicated skill.
             let interests = try await store.findActiveByTag("interest")
-            let preferences = try await store.findActiveByTag("preference")
 
-            let total = interests.count + preferences.count
-            if total > 3 {
-                NSLog("FaeScheduler: skill_proposals — %d interests/preferences
found, may suggest skills", total)
-                // Future: surface suggestion via eventBus or speakHandler.
+            // Find an interest we haven't suggested yet.
+            let unsuggestedInterest = interests.first { 
!suggestedInterestIDs.contains($0.id) }
+            guard let interest = unsuggestedInterest else {
+                NSLog("FaeScheduler: skill_proposals — no unsurfaced 
interests")
+                return
+            }
+
+            // Extract the topic from the interest text.
+            let topic = interest.text
+                .replacingOccurrences(of: "User is interested in: ", with: "")
+                .trimmingCharacters(in: .whitespacesAndNewlines)
+
+            guard !topic.isEmpty else { return }
+
+            // Mark as suggested so we don't repeat.
+            suggestedInterestIDs.insert(interest.id)
+
+            let phrases = [
+                "I noticed you're into \(topic). I could write a quick script 
to track updates on that. Want me to?",
+                "Hey, since you're interested in \(topic), I could build a 
little skill to help with that. Shall I?",
+                "By the way, I could create a Python skill around \(topic) to 
keep you updated. Interested?",
+            ]
+            let suggestion = phrases[Int.random(in: 0 ..< phrases.count)]
+
+            NSLog("FaeScheduler: skill_proposals — suggesting skill for '%@'", 
topic)
+            if let speak = speakHandler {
+                await speak(suggestion)
             }
         } catch {
             NSLog("FaeScheduler: skill_proposals — error: %@", 
error.localizedDescription)
@@ -208,16 +366,32 @@ actor FaeScheduler {
             let now = UInt64(Date().timeIntervalSince1970)
             let thirtyDays: UInt64 = 30 * 24 * 3600
 
-            var staleNames: [String] = []
+            // Find stale contacts (not mentioned in 30+ days).
+            var staleRecords: [MemoryRecord] = []
             for record in personRecords {
                 if record.updatedAt > 0, (now - record.updatedAt) > thirtyDays 
{
-                    staleNames.append(record.text)
+                    staleRecords.append(record)
                 }
             }
 
-            if !staleNames.isEmpty {
-                NSLog("FaeScheduler: stale_relationships — %d stale contacts 
found", staleNames.count)
-                // Future: surface as gentle briefing item.
+            guard let staleRecord = staleRecords.first else {
+                NSLog("FaeScheduler: stale_relationships — no stale contacts")
+                return
+            }
+
+            let name = extractPersonName(from: staleRecord.text)
+            guard !name.isEmpty else { return }
+
+            let phrases = [
+                "By the way, you haven't mentioned \(name) in a while. 
Everything good?",
+                "Just a thought — it's been a while since \(name) came up. 
Might be worth reaching out.",
+                "Hey, I noticed you haven't talked about \(name) recently. Hope
all is well.",
+            ]
+            let reminder = phrases[Int.random(in: 0 ..< phrases.count)]
+
+            NSLog("FaeScheduler: stale_relationships — reminding about '%@'", 
name)
+            if let speak = speakHandler {
+                await speak(reminder)
             }
         } catch {
             NSLog("FaeScheduler: stale_relationships — error: %@", 
error.localizedDescription)
@@ -231,7 +405,56 @@ actor FaeScheduler {
     }
 
     private func runSkillHealthCheck() async {
-        // Silent unless issues found — don't log every 5min
+        // Scan skills directory for .py files and verify PEP 723 metadata.
+        let appSupport = FileManager.default.urls(
+            for: .applicationSupportDirectory, in: .userDomainMask
+        ).first
+        guard let skillsDir = appSupport?.appendingPathComponent("fae/skills") 
else { return }
+
+        let fm = FileManager.default
+        guard fm.fileExists(atPath: skillsDir.path) else { return }
+
+        do {
+            let contents = try fm.contentsOfDirectory(
+                at: skillsDir,
+                includingPropertiesForKeys: nil
+            )
+            let pyFiles = contents.filter { $0.pathExtension == "py" }
+            guard !pyFiles.isEmpty else { return }
+
+            var brokenSkills: [String] = []
+            for file in pyFiles {
+                let text = try String(contentsOf: file, encoding: .utf8)
+                // Check for PEP 723 inline metadata header.
+                if !text.contains("# /// script") {
+                    brokenSkills.append(file.lastPathComponent)
+                }
+            }
+
+            if !brokenSkills.isEmpty {
+                NSLog(
+                    "FaeScheduler: skill_health_check — %d skills missing PEP 
723 metadata: %@",
+                    brokenSkills.count,
+                    brokenSkills.joined(separator: ", ")
+                )
+            }
+
+            // Check if uv is available on PATH.
+            let uvProcess = Process()
+            uvProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
+            uvProcess.arguments = ["uv"]
+            let pipe = Pipe()
+            uvProcess.standardOutput = pipe
+            uvProcess.standardError = pipe
+            try uvProcess.run()
+            uvProcess.waitUntilExit()
+            if uvProcess.terminationStatus != 0 {
+                NSLog("FaeScheduler: skill_health_check — uv not found on 
PATH")
+            }
+        } catch {
+            // Silent on errors — this runs every 5 minutes.
+            NSLog("FaeScheduler: skill_health_check — error: %@", 
error.localizedDescription)
+        }
     }
 
     // MARK: - Daily Schedule Checks
@@ -251,10 +474,14 @@ actor FaeScheduler {
         if hour == 3, minute >= 30, minute < 32 { await 
runDailyIfNeeded("memory_gc") { await runMemoryGC() } }
         // noise_budget_reset: daily 00:00
         if hour == 0, minute < 2 { await runDailyIfNeeded("noise_budget_reset")
{ await runNoiseBudgetReset() } }
-        // morning_briefing: daily 08:00
-        if hour == 8, minute < 2 { await runDailyIfNeeded("morning_briefing") {
await runMorningBriefing() } }
-        // skill_proposals: daily 11:00
-        if hour == 11, minute < 2 { await runDailyIfNeeded("skill_proposals") {
await runSkillProposals() } }
+        // morning_briefing: configurable hour (default 08:00)
+        if hour == config.morningBriefingHour, minute < 2 {
+            await runDailyIfNeeded("morning_briefing") { await 
runMorningBriefing() }
+        }
+        // skill_proposals: configurable hour (default 11:00)
+        if hour == config.skillProposalsHour, minute < 2 {
+            await runDailyIfNeeded("skill_proposals") { await 
runSkillProposals() }
+        }
     }
 
     private func runDailyIfNeeded(_ name: String, _ action: () async -> Void) 
async {
@@ -271,6 +498,10 @@ actor FaeScheduler {
     /// Trigger a named task to run immediately (from FaeCore command or 
SchedulerTriggerTool).
     func triggerTask(id: String) async {
         NSLog("FaeScheduler: manual trigger for '%@'", id)
+        if disabledTaskIDs.contains(id) {
+            NSLog("FaeScheduler: task '%@' is disabled", id)
+            return
+        }
         switch id {
         case "memory_reflect":    await runMemoryReflect()
         case "memory_reindex":    await runMemoryReindex()
@@ -286,6 +517,21 @@ actor FaeScheduler {
         default:
             NSLog("FaeScheduler: unknown task id '%@'", id)
         }
+        runHistory[id, default: []].append(Date())
+
+        // Persist the run to the store
+        if let store = persistenceStore {
+            let record = TaskRunRecord(
+                taskID: id, idempotencyKey: 
"trigger:\(id):\(Int(Date().timeIntervalSince1970))",
+                state: .success, attempt: 0,
+                updatedAt: Date(), lastError: nil
+            )
+            do {
+                try await store.insertRun(record)
+            } catch {
+                NSLog("FaeScheduler: failed to persist trigger run: %@", 
error.localizedDescription)
+            }
+        }
     }
 
     /// Delete a user-created scheduled task (builtin tasks cannot be deleted).
@@ -295,6 +541,82 @@ actor FaeScheduler {
         NSLog("FaeScheduler: deleteUserTask '%@' — delegated to 
SchedulerDeleteTool", id)
     }
 
+    func setTaskEnabled(id: String, enabled: Bool) async {
+        if enabled {
+            disabledTaskIDs.remove(id)
+        } else {
+            disabledTaskIDs.insert(id)
+        }
+
+        // Persist to store
+        if let store = persistenceStore {
+            do {
+                try await store.setTaskEnabled(id: id, enabled: enabled)
+            } catch {
+                NSLog("FaeScheduler: failed to persist enabled state: %@", 
error.localizedDescription)
+            }
+        }
+    }
+
+    func isTaskEnabled(id: String) async -> Bool {
+        !disabledTaskIDs.contains(id)
+    }
+
+    func status(taskID: String) async -> [String: Any] {
+        // Check persistence store for last run time if not in memory
+        var lastRunAt: TimeInterval?
+        if let memoryRun = runHistory?.last {
+            lastRunAt = memoryRun.timeIntervalSince1970
+        } else if let store = persistenceStore {
+            do {
+                let history = try await store.runHistory(taskID: taskID, limit:
1)
+                lastRunAt = history.first?.timeIntervalSince1970
+            } catch {
+                NSLog("FaeScheduler: failed to query run history: %@", 
error.localizedDescription)
+            }
+        }
+
+        return [
+            "id": taskID,
+            "enabled": !disabledTaskIDs.contains(taskID),
+            "last_run_at": lastRunAt as Any,
+        ]
+    }
+
+    func history(taskID: String, limit: Int = 20) async -> [Date] {
+        // Prefer persistence store if available
+        if let store = persistenceStore {
+            do {
+                return try await store.runHistory(taskID: taskID, limit: limit)
+            } catch {
+                NSLog("FaeScheduler: failed to query history: %@", 
error.localizedDescription)
+            }
+        }
+        let runs = runHistory ?? []
+        return Array(runs.suffix(max(1, limit)))
+    }
+
+    func statusAll() async -> [[String: Any]] {
+        var ids = Set(runHistory.keys).union(disabledTaskIDs)
+
+        // Include all known task IDs from the builtin list
+        let builtinIDs = [
+            "memory_reflect", "memory_reindex", "memory_migrate",
+            "memory_gc", "memory_backup", "check_fae_update",
+            "morning_briefing", "noise_budget_reset", "skill_proposals",
+            "stale_relationships", "skill_health_check",
+        ]
+        ids.formUnion(builtinIDs)
+
+        return ids.sorted().map { id in
+            [
+                "id": id,
+                "enabled": !disabledTaskIDs.contains(id),
+                "last_run_at": runHistory?.last?.timeIntervalSince1970 as Any,
+            ]
+        }
+    }
+
     // MARK: - Timer Helpers
 
     private func scheduleRepeating(
diff --git a/native/macos/Fae/Sources/Fae/Search/Engines/DuckDuckGoEngine.swift 
b/native/macos/Fae/Sources/Fae/Search/Engines/DuckDuckGoEngine.swift
index 959b62a..56ddf17 100644
--- a/native/macos/Fae/Sources/Fae/Search/Engines/DuckDuckGoEngine.swift
+++ b/native/macos/Fae/Sources/Fae/Search/Engines/DuckDuckGoEngine.swift
@@ -51,8 +51,12 @@ struct DuckDuckGoEngine: SearchEngineProtocol {
             guard let range = Range(match.range(at: 1), in: html) else { 
continue }
             let block = String(html)
 
-            // Skip ads.
-            if block.contains("result--ad") { continue }
+            // Skip ads — check the full match (including the opening div tag)
+            // because result--ad is in the class attribute, not the inner 
content.
+            if let fullRange = Range(match.range(at: 0), in: html) {
+                let fullMatch = String(html)
+                if fullMatch.contains("result--ad") { continue }
+            }
 
             // Extract title and URL from result__a link.
             guard let (title, href) = extractResultLink(from: block) else { 
continue }
diff --git a/native/macos/Fae/Sources/Fae/Tools/AppleTools.swift 
b/native/macos/Fae/Sources/Fae/Tools/AppleTools.swift
index 0f8ccf3..f99bc62 100644
--- a/native/macos/Fae/Sources/Fae/Tools/AppleTools.swift
+++ b/native/macos/Fae/Sources/Fae/Tools/AppleTools.swift
@@ -28,6 +28,8 @@ struct CalendarTool: Tool {
         "end_date": "string ISO8601 (for create)"}
         """
     var requiresApproval: Bool { false }
+    var riskLevel: ToolRiskLevel { .low }
+    let example = 
#"<tool_call>{"name":"calendar","arguments":{"action":"list_today"}}</tool_call>
"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         let store = EKEventStore()
@@ -140,6 +142,8 @@ struct RemindersTool: Tool {
         "reminder_id": "string (for complete)"}
         """
     var requiresApproval: Bool { false }
+    var riskLevel: ToolRiskLevel { .low }
+    let example = 
#"<tool_call>{"name":"reminders","arguments":{"action":"list_incomplete"}}</tool
_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         let store = EKEventStore()
@@ -238,6 +242,8 @@ struct ContactsTool: Tool {
         "query": "string (required)"}
         """
     let requiresApproval = false
+    let riskLevel: ToolRiskLevel = .low
+    let example = 
#"<tool_call>{"name":"contacts","arguments":{"action":"search","query":"Sarah"}}
</tool_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard CNContactStore.authorizationStatus(for: .contacts) == .authorized
else {
@@ -322,6 +328,8 @@ struct MailTool: Tool {
         "count": "int (optional, default 5)"}
         """
     let requiresApproval = false
+    let riskLevel: ToolRiskLevel = .low
+    let example = 
#"<tool_call>{"name":"mail","arguments":{"action":"check_inbox","count":5}}</too
l_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let action = input["action"] as? String else {
@@ -384,6 +392,8 @@ struct NotesTool: Tool {
         "count": "int (optional, default 5)"}
         """
     let requiresApproval = false
+    let riskLevel: ToolRiskLevel = .low
+    let example = 
#"<tool_call>{"name":"notes","arguments":{"action":"search","query":"meeting 
notes"}}</tool_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let action = input["action"] as? String else {
diff --git a/native/macos/Fae/Sources/Fae/Tools/BuiltinTools.swift 
b/native/macos/Fae/Sources/Fae/Tools/BuiltinTools.swift
index ebb8518..ca1906b 100644
--- a/native/macos/Fae/Sources/Fae/Tools/BuiltinTools.swift
+++ b/native/macos/Fae/Sources/Fae/Tools/BuiltinTools.swift
@@ -7,6 +7,8 @@ struct ReadTool: Tool {
     let description = "Read the contents of a file at the given path."
     let parametersSchema = #"{"path": "string (required)"}"#
     let requiresApproval = false
+    let riskLevel: ToolRiskLevel = .low
+    let example = 
#"<tool_call>{"name":"read","arguments":{"path":"~/Documents/notes.txt"}}</tool_
call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let path = input["path"] as? String else {
@@ -35,6 +37,8 @@ struct WriteTool: Tool {
     let description = "Write content to a file at the given path."
     let parametersSchema = #"{"path": "string (required)", "content": "string 
(required)"}"#
     let requiresApproval = true
+    let riskLevel: ToolRiskLevel = .high
+    let example = 
#"<tool_call>{"name":"write","arguments":{"path":"~/notes.txt","content":"Hello 
world"}}</tool_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let path = input["path"] as? String,
@@ -63,6 +67,8 @@ struct EditTool: Tool {
     let description = "Replace a string in a file. The old_string must match 
exactly."
     let parametersSchema = #"{"path": "string", "old_string": "string", 
"new_string": "string"}"#
     let requiresApproval = true
+    let riskLevel: ToolRiskLevel = .high
+    let example = 
#"<tool_call>{"name":"edit","arguments":{"path":"~/config.toml","old_string":"ti
meout = 30","new_string":"timeout = 60"}}</tool_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let path = input["path"] as? String,
@@ -93,6 +99,8 @@ struct BashTool: Tool {
     let description = "Execute a shell command and return its output."
     let parametersSchema = #"{"command": "string (required)"}"#
     let requiresApproval = true
+    let riskLevel: ToolRiskLevel = .high
+    let example = #"<tool_call>{"name":"bash","arguments":{"command":"ls -la 
~/Documents"}}</tool_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let command = input["command"] as? String else {
@@ -154,6 +162,7 @@ struct SelfConfigTool: Tool {
         {"action": "string (required: 
get_instructions|set_instructions|append_instructions|clear_instructions)", 
"value": "string (required for set/append)"}
         """#
     let requiresApproval = false
+    let example = 
#"<tool_call>{"name":"self_config","arguments":{"action":"append_instructions","
value":"Be more concise"}}</tool_call>"#
 
     private static var filePath: URL {
         let appSupport = FileManager.default.urls(
@@ -227,10 +236,78 @@ struct WebSearchTool: Tool {
     let description = "Search the web using multiple engines (DuckDuckGo, 
Brave, Google, Bing). Results are deduplicated and ranked across engines for 
quality."
     let parametersSchema = #"{"query": "string (required)", "max_results": 
"integer (optional, default 10)"}"#
     let requiresApproval = false
+    let example = 
#"<tool_call>{"name":"web_search","arguments":{"query":"latest Swift concurrency
features"}}</tool_call>"#
 
     private static let maxOutputChars = 100_000
     private static let orchestrator = SearchOrchestrator()
 
+    /// Categorize a URL's domain for quality indication.
+    private static func domainCategory(for urlString: String) -> String {
+        guard let url = URL(string: urlString),
+              let host = url.host?.lowercased()
+        else { return "" }
+
+        // Strip www. prefix for matching.
+        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
+
+        // News domains.
+        let newsDomains: Set<String> = [
+            "reuters.com", "apnews.com", "bbc.com", "bbc.co.uk", "nytimes.com",
+            "theguardian.com", "washingtonpost.com", "cnn.com", "npr.org",
+            "arstechnica.com", "theverge.com", "techcrunch.com", "wired.com",
+            "bloomberg.com", "ft.com", "economist.com", "9to5mac.com",
+            "macrumors.com", "engadget.com",
+        ]
+        if newsDomains.contains(domain) { return "[News]" }
+
+        // Reference / documentation.
+        let refDomains: Set<String> = [
+            "wikipedia.org", "en.wikipedia.org", "developer.apple.com",
+            "docs.swift.org", "docs.python.org", "docs.rs", 
"doc.rust-lang.org",
+            "developer.mozilla.org", "w3.org", "rfc-editor.org",
+        ]
+        if refDomains.contains(domain) { return "[Reference]" }
+
+        // Code / developer.
+        let codeDomains: Set<String> = [
+            "github.com", "gitlab.com", "bitbucket.org", "stackoverflow.com",
+            "stackexchange.com", "npmjs.com", "pypi.org", "crates.io",
+            "pkg.go.dev", "swiftpackageindex.com", "cocoapods.org",
+        ]
+        if codeDomains.contains(domain) { return "[Code]" }
+
+        // Forums / community.
+        let forumDomains: Set<String> = [
+            "reddit.com", "old.reddit.com", "news.ycombinator.com",
+            "lobste.rs", "discourse.org", "forums.swift.org",
+            "discuss.python.org", "quora.com",
+        ]
+        if forumDomains.contains(domain) { return "[Forum]" }
+
+        // Academic.
+        let academicDomains: Set<String> = [
+            "arxiv.org", "scholar.google.com", "ieee.org", "acm.org",
+            "nature.com", "science.org", "pnas.org", "researchgate.net",
+        ]
+        if academicDomains.contains(domain) { return "[Academic]" }
+
+        // Social media.
+        let socialDomains: Set<String> = [
+            "twitter.com", "x.com", "mastodon.social", "linkedin.com",
+            "facebook.com", "youtube.com", "medium.com", "substack.com",
+        ]
+        if socialDomains.contains(domain) { return "[Social]" }
+
+        return ""
+    }
+
+    /// Extract the display domain from a URL string.
+    private static func displayDomain(for urlString: String) -> String {
+        guard let url = URL(string: urlString), let host = url.host else { 
return "" }
+        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
+        return domain
+    }
+
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let query = input["query"] as? String, 
!query.trimmingCharacters(in: .whitespaces).isEmpty else {
             return .error("Missing required parameter: query")
@@ -248,7 +325,10 @@ struct WebSearchTool: Tool {
 
             var output = "## Search Results for \"\(query)\"\n\n"
             for (i, result) in results.enumerated() {
-                output += "\(i + 1). **\(result.title)**\n   URL: 
\(result.url)\n   \(result.snippet)\n\n"
+                let category = Self.domainCategory(for: result.url)
+                let domain = Self.displayDomain(for: result.url)
+                let tag = category.isEmpty ? domain : "\(category) \(domain)"
+                output += "\(i + 1). **\(result.title)** (\(tag))\n   URL: 
\(result.url)\n   \(result.snippet)\n\n"
             }
 
             if output.count > Self.maxOutputChars {
@@ -272,6 +352,7 @@ struct FetchURLTool: Tool {
     let description = "Fetch a web page and extract its readable text content."
     let parametersSchema = #"{"url": "string (required, must start with http://
or https://)"}"#
     let requiresApproval = false
+    let example = 
#"<tool_call>{"name":"fetch_url","arguments":{"url":"https://example.com/article
"}}</tool_call>"#
 
     private static let orchestrator = SearchOrchestrator()
 
diff --git a/native/macos/Fae/Sources/Fae/Tools/RoleplayTool.swift 
b/native/macos/Fae/Sources/Fae/Tools/RoleplayTool.swift
index 8703408..edb66e1 100644
--- a/native/macos/Fae/Sources/Fae/Tools/RoleplayTool.swift
+++ b/native/macos/Fae/Sources/Fae/Tools/RoleplayTool.swift
@@ -1,6 +1,10 @@
 import Foundation
 
 /// Manages roleplay session state: active flag, title, and character-to-voice 
mappings.
+///
+/// Voice assignments are persisted to `roleplay_voices.json` keyed by session
+/// title so that resuming a session with the same title restores previously
+/// assigned character voices.
 actor RoleplaySessionStore {
     static let shared = RoleplaySessionStore()
 
@@ -8,19 +12,34 @@ actor RoleplaySessionStore {
     private(set) var title: String?
     private(set) var characterVoices: [String: String] = [:]
 
-    /// Start a new roleplay session, clearing any previous state.
+    private let persistence = RoleplayVoicePersistence()
+
+    /// Start a new roleplay session.
+    ///
+    /// If a session with the same title was previously used, saved voice
+    /// assignments are automatically restored.
     func start(title: String?) -> String {
         self.isActive = true
         self.title = title
-        self.characterVoices = [:]
+        // Restore saved voices for this title (if any).
+        if let title {
+            self.characterVoices = persistence.load(forTitle: title)
+        } else {
+            self.characterVoices = [:]
+        }
         let label = title ?? "untitled"
-        return "Roleplay session started: \(label). Assign character voices 
with assign_voice."
+        let restoredNote = characterVoices.isEmpty ? "" : " Restored 
\(characterVoices.count) saved voice(s)."
+        return "Roleplay session started: \(label). Assign character voices 
with assign_voice.\(restoredNote)"
     }
 
     /// Assign a voice description to a character name.
     func assignVoice(character: String, description: String) -> String {
         let key = character.lowercased()
         characterVoices = description
+        // Persist updated voice assignments.
+        if let title {
+            persistence.save(voices: characterVoices, forTitle: title)
+        }
         return "Voice assigned: \(character) → \(description)"
     }
 
@@ -48,6 +67,90 @@ actor RoleplaySessionStore {
     }
 }
 
+// MARK: - Voice Persistence
+
+/// Handles reading and writing roleplay voice assignments to disk.
+///
+/// Voice assignments are stored in a JSON file at:
+/// `~/Library/Application Support/fae/roleplay_voices.json`
+///
+/// Structure:
+/// ```json
+/// {
+///   "Session Title": {
+///     "hamlet": "deep male voice, brooding, Shakespearean",
+///     "narrator": "calm, measured, storytelling"
+///   }
+/// }
+/// ```
+private struct RoleplayVoicePersistence {
+
+    private var fileURL: URL? {
+        guard let appSupport = FileManager.default.urls(
+            for: .applicationSupportDirectory,
+            in: .userDomainMask
+        ).first else {
+            return nil
+        }
+        return appSupport
+            .appendingPathComponent("fae")
+            .appendingPathComponent("roleplay_voices.json")
+    }
+
+    /// Load saved voice assignments for a given session title.
+    ///
+    /// Returns an empty dictionary if no saved data exists or the file is 
corrupt.
+    func load(forTitle title: String) -> [String: String] {
+        guard let url = fileURL else { return [:] }
+
+        do {
+            let data = try Data(contentsOf: url)
+            let all = try JSONDecoder().decode([String: [String: String]].self,
from: data)
+            return all ?? [:]
+        } catch {
+            // Missing file or corrupt data — start fresh (don't log missing 
file).
+            if !((error as NSError).domain == NSCocoaErrorDomain
+                && (error as NSError).code == NSFileReadNoSuchFileError)
+            {
+                NSLog("RoleplayVoicePersistence: load error: %@", 
error.localizedDescription)
+            }
+            return [:]
+        }
+    }
+
+    /// Save voice assignments for a given session title.
+    ///
+    /// Merges with existing sessions on disk so other sessions are preserved.
+    func save(voices: [String: String], forTitle title: String) {
+        guard let url = fileURL else { return }
+
+        // Load existing sessions first.
+        var all: [String: [String: String]] = [:]
+        if let data = try? Data(contentsOf: url),
+           let decoded = try? JSONDecoder().decode([String: [String: 
String]].self, from: data)
+        {
+            all = decoded
+        }
+
+        // Update this session.
+        all = voices
+
+        // Ensure directory exists.
+        do {
+            try FileManager.default.createDirectory(
+                at: url.deletingLastPathComponent(),
+                withIntermediateDirectories: true
+            )
+            let encoder = JSONEncoder()
+            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
+            let data = try encoder.encode(all)
+            try data.write(to: url, options: .atomic)
+        } catch {
+            NSLog("RoleplayVoicePersistence: save error: %@", 
error.localizedDescription)
+        }
+    }
+}
+
 // MARK: - Roleplay Tool
 
 /// Tool for managing multi-voice roleplay reading sessions.
@@ -70,6 +173,7 @@ struct RoleplayTool: Tool {
         "voice_description": "string (required for assign_voice, under 50 
words: gender, age, accent, style)"}
         """
     let requiresApproval = false
+    let example = 
#"<tool_call>{"name":"roleplay","arguments":{"action":"start","title":"Hamlet 
Act 3"}}</tool_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let action = input["action"] as? String else {
diff --git a/native/macos/Fae/Sources/Fae/Tools/SchedulerTools.swift 
b/native/macos/Fae/Sources/Fae/Tools/SchedulerTools.swift
index 0a0d12c..6b191f3 100644
--- a/native/macos/Fae/Sources/Fae/Tools/SchedulerTools.swift
+++ b/native/macos/Fae/Sources/Fae/Tools/SchedulerTools.swift
@@ -68,6 +68,8 @@ struct SchedulerListTool: Tool {
     let description = "List all scheduled tasks with their schedule and 
status."
     let parametersSchema = #"{}"#
     let requiresApproval = false
+    let riskLevel: ToolRiskLevel = .low
+    let example = 
#"<tool_call>{"name":"scheduler_list","arguments":{}}</tool_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         let tasks = readSchedulerTasks()
@@ -111,6 +113,8 @@ struct SchedulerCreateTool: Tool {
         "action": "string (required: description of what to do)"}
         """
     let requiresApproval = true
+    let riskLevel: ToolRiskLevel = .high
+    let example = 
#"<tool_call>{"name":"scheduler_create","arguments":{"name":"Weather 
Check","schedule_type":"daily","schedule_params":{"hour":"7","minute":"0"},"acti
on":"Check weather forecast"}}</tool_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let taskName = input["name"] as? String, !taskName.isEmpty else {
@@ -160,6 +164,8 @@ struct SchedulerUpdateTool: Tool {
         "schedule_params": "object (optional)"}
         """
     let requiresApproval = true
+    let riskLevel: ToolRiskLevel = .high
+    let example = 
#"<tool_call>{"name":"scheduler_update","arguments":{"id":"morning_briefing","en
abled":false}}</tool_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let taskId = input["id"] as? String else {
@@ -173,6 +179,15 @@ struct SchedulerUpdateTool: Tool {
 
         if let enabled = input["enabled"] as? Bool {
             tasks.enabled = enabled
+
+            // Route enabled/disabled state change through FaeScheduler (single
source of truth).
+            await MainActor.run {
+                NotificationCenter.default.post(
+                    name: .faeSchedulerUpdate,
+                    object: nil,
+                    userInfo: ["id": taskId, "enabled": enabled]
+                )
+            }
         }
         if let scheduleType = input["schedule_type"] as? String {
             tasks.scheduleType = scheduleType
@@ -197,6 +212,8 @@ struct SchedulerDeleteTool: Tool {
     let description = "Delete a user-created scheduled task. Cannot delete 
builtin tasks."
     let parametersSchema = #"{"id": "string (required)"}"#
     let requiresApproval = true
+    let riskLevel: ToolRiskLevel = .high
+    let example = 
#"<tool_call>{"name":"scheduler_delete","arguments":{"id":"user_abc12345"}}</too
l_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let taskId = input["id"] as? String else {
@@ -231,6 +248,8 @@ struct SchedulerTriggerTool: Tool {
     let description = "Trigger a scheduled task to run immediately."
     let parametersSchema = #"{"id": "string (required)"}"#
     let requiresApproval = false
+    let riskLevel: ToolRiskLevel = .low
+    let example = 
#"<tool_call>{"name":"scheduler_trigger","arguments":{"id":"morning_briefing"}}<
/tool_call>"#
 
     func execute(input: [String: Any]) async throws -> ToolResult {
         guard let taskId = input["id"] as? String else {
@@ -257,4 +276,5 @@ struct SchedulerTriggerTool: Tool {
 
 extension Notification.Name {
     static let faeSchedulerTrigger = Notification.Name("faeSchedulerTrigger")
+    static let faeSchedulerUpdate = Notification.Name("faeSchedulerUpdate")
 }
diff --git a/native/macos/Fae/Sources/Fae/Tools/Tool.swift 
b/native/macos/Fae/Sources/Fae/Tools/Tool.swift
index afb0e19..8d1f5e2 100644
--- a/native/macos/Fae/Sources/Fae/Tools/Tool.swift
+++ b/native/macos/Fae/Sources/Fae/Tools/Tool.swift
@@ -27,9 +27,14 @@ protocol Tool: Sendable {
     var description: String { get }
     var parametersSchema: String { get }
     var requiresApproval: Bool { get }
+    var riskLevel: ToolRiskLevel { get }
+    /// A concrete `<tool_call>` example for the LLM to follow.
+    var example: String { get }
     func execute(input: [String: Any]) async throws -> ToolResult
 }
 
 extension Tool {
     var requiresApproval: Bool { false }
+    var riskLevel: ToolRiskLevel { .medium }
+    var example: String { "" }
 }
diff --git a/native/macos/Fae/Sources/Fae/Tools/ToolRegistry.swift 
b/native/macos/Fae/Sources/Fae/Tools/ToolRegistry.swift
index a773e53..d7ac612 100644
--- a/native/macos/Fae/Sources/Fae/Tools/ToolRegistry.swift
+++ b/native/macos/Fae/Sources/Fae/Tools/ToolRegistry.swift
@@ -60,11 +60,17 @@ final class ToolRegistry: Sendable {
         Array(tools.keys).sorted()
     }
 
-    /// JSON schema descriptions for all registered tools.
+    /// JSON schema descriptions for all registered tools, with examples when 
available.
     var toolSchemas: String {
         tools.values
             .sorted { $0.name < $1.name }
-            .map { "## \($0.name)\n\($0.description)\nParameters: 
\($0.parametersSchema)" }
+            .map { tool in
+                var schema = "## \(tool.name)\n\(tool.description)\nRisk: 
\(tool.riskLevel.rawValue)\nParameters: \(tool.parametersSchema)"
+                if !tool.example.isEmpty {
+                    schema += "\nExample: \(tool.example)"
+                }
+                return schema
+            }
             .joined(separator: "\n\n")
     }
 }
TurnBegin(
    user_input='Review this Swift macOS codebase git diff for:\n1. Security 
issues (keychain access, data exposure, privilege escalation)\n2. Error handling
problems (force unwraps, missing guards)\n3. Code quality (performance, 
maintainability, Swift idioms)\n4. Architectural concerns (state management, 
concurrency, threading)\n5. Memory safety issues (retain cycles, 
leaks)\n\nFormat each finding as:\n[SEVERITY: A-F] file:line - category - 
description\n\nShow all findings, sorted by severity.\n\nDIFF:\ndiff --git 
a/native/macos/Fae/Sources/Fae/Core/FaeConfig.swift 
b/native/macos/Fae/Sources/Fae/Core/FaeConfig.swift\nindex 2e382f8..164334f 
100644\n--- a/native/macos/Fae/Sources/Fae/Core/FaeConfig.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Core/FaeConfig.swift\n@@ -14,6 +14,7 @@ struct 
FaeConfig: Codable {\n     var bargeIn: BargeInConfig = BargeInConfig()\n     
var memory: MemoryConfig = MemoryConfig()\n     var speaker: SpeakerConfig = 
SpeakerConfig()\n+    var scheduler: SchedulerConfig = SchedulerConfig()\n     
var userName: String?\n     var onboarded: Bool = false\n     var 
licenseAccepted: Bool = false\n@@ -113,6 +114,13 @@ struct FaeConfig: Codable 
{\n         var maxEnrollments: Int = 50\n     }\n \n+    // MARK: - 
Scheduler\n+\n+    struct SchedulerConfig: Codable {\n+        var 
morningBriefingHour: Int = 8\n+        var skillProposalsHour: Int = 11\n+    
}\n+\n     // MARK: - Model Selection\n \n     /// Select the appropriate LLM 
model based on system RAM and preset.\n@@ -125,6 +133,8 @@ struct FaeConfig: 
Codable {\n         let totalGB = (totalMemoryBytes ?? 
ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)\n \n         
switch preset.lowercased() {\n+        case "qwen3_5_27b":\n+            return 
("mlx-community/Qwen3.5-27B-4bit", 65_536)\n         case "qwen3_5_35b_a3b":\n  
return ("mlx-community/Qwen3.5-35B-A3B-4bit", 65_536)\n         case 
"qwen3_8b":\n@@ -441,6 +451,16 @@ struct FaeConfig: Codable {\n                 
config.memory.maxRecallResults = v\n                 default: break\n           
}\n+            case "scheduler":\n+                switch key {\n+             
case "morningBriefingHour":\n+                    guard let v = 
parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: 
rawValue) }\n+                    config.scheduler.morningBriefingHour = v\n+   
case "skillProposalsHour":\n+                    guard let v = 
parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: 
rawValue) }\n+                    config.scheduler.skillProposalsHour = v\n+    
default: break\n+                }\n             case "speaker":\n              
switch key {\n                 case "enabled":\n@@ -541,6 +561,11 @@ struct 
FaeConfig: Codable {\n         lines.append("maxRecallResults = 
\\(memory.maxRecallResults)")\n         lines.append("")\n \n+        
lines.append("[scheduler]")\n+        lines.append("morningBriefingHour = 
\\(scheduler.morningBriefingHour)")\n+        lines.append("skillProposalsHour =
\\(scheduler.skillProposalsHour)")\n+        lines.append("")\n+\n         
lines.append("[speaker]")\n         lines.append("enabled = \\(speaker.enabled ?
"true" : "false")")\n         lines.append("threshold = 
\\(formatFloat(speaker.threshold))")\ndiff --git 
a/native/macos/Fae/Sources/Fae/Core/FaeCore.swift 
b/native/macos/Fae/Sources/Fae/Core/FaeCore.swift\nindex d191483..1d30c9c 
100644\n--- a/native/macos/Fae/Sources/Fae/Core/FaeCore.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Core/FaeCore.swift\n@@ -109,12 +109,21 @@ final 
class FaeCore: ObservableObject, HostCommandSender {\n                     
memoryOrchestrator: orchestrator,\n                     memoryStore: 
memoryStore\n                 )\n+\n+                // Wire persistence store 
for scheduler state.\n+                if let schedulerStore = try? 
Self.createSchedulerPersistenceStore() {\n+                    await 
sched.configurePersistence(store: schedulerStore)\n+                }\n+\n      
await sched.setSpeakHandler { [weak coordinator] text in\n                     
await coordinator?.speakDirect(text)\n                 }\n                 await
sched.start()\n                 self.scheduler = sched\n \n+                // 
Observe scheduler update notifications from SchedulerUpdateTool.\n+             
self.observeSchedulerUpdates()\n+\n                 pipelineState = .running\n  
eventBus.send(.runtimeState(.started))\n                 NSLog("FaeCore: 
pipeline started")\n@@ -250,6 +259,39 @@ final class FaeCore: ObservableObject, 
HostCommandSender {\n                 Task { await scheduler?.triggerTask(id: 
taskId) }\n             }\n \n+        case "scheduler.enable":\n+            if
let taskId = payload["id"] as? String {\n+                Task { await 
scheduler?.setTaskEnabled(id: taskId, enabled: true) }\n+            }\n+\n+    
case "scheduler.disable":\n+            if let taskId = payload["id"] as? String
{\n+                Task { await scheduler?.setTaskEnabled(id: taskId, enabled: 
false) }\n+            }\n+\n+        case "scheduler.set_enabled":\n+          
if let taskId = payload["id"] as? String,\n+               let enabled = 
payload["enabled"] as? Bool\n+            {\n+                Task { await 
scheduler?.setTaskEnabled(id: taskId, enabled: enabled) }\n+            }\n+\n+ 
case "scheduler.status":\n+            if let taskId = payload["id"] as? String 
{\n+                Task {\n+                    let status = await 
scheduler?.status(taskID: taskId) ?? [:]\n+                    NSLog("FaeCore: 
scheduler.status %@", String(describing: status))\n+                }\n+        
}\n+\n+        case "scheduler.history":\n+            if let taskId = 
payload["id"] as? String {\n+                Task {\n+                    let 
history = await scheduler?.history(taskID: taskId, limit: 20) ?? []\n+          
NSLog("FaeCore: scheduler.history %@ count=%d", taskId, history.count)\n+       
}\n+            }\n+\n         case "data.delete_all":\n             
NSLog("FaeCore: data.delete_all — stub")\n \n@@ -368,6 +410,32 @@ final class 
FaeCore: ObservableObject, HostCommandSender {\n         return try 
SQLiteMemoryStore(path: dbPath)\n     }\n \n+    /// Scheduler persistence 
database path.\n+    private static func createSchedulerPersistenceStore() 
throws -> SchedulerPersistenceStore {\n+        let appSupport = 
FileManager.default.urls(\n+            for: .applicationSupportDirectory, in: 
.userDomainMask\n+        ).first!\n+        let faeDir = 
appSupport.appendingPathComponent("fae")\n+        let dbPath = 
faeDir.appendingPathComponent("scheduler.db").path\n+        return try 
SchedulerPersistenceStore(path: dbPath)\n+    }\n+\n+    /// Observe scheduler 
update notifications from SchedulerUpdateTool.\n+    private func 
observeSchedulerUpdates() {\n+        NotificationCenter.default.addObserver(\n+
forName: .faeSchedulerUpdate,\n+            object: nil,\n+            queue: 
.main\n+        ) { [weak self] notification in\n+            guard let self,\n+
let userInfo = notification.userInfo,\n+                  let taskId = 
userInfo["id"] as? String,\n+                  let enabled = userInfo["enabled"]
as? Bool\n+            else { return }\n+            Task { await 
self.scheduler?.setTaskEnabled(id: taskId, enabled: enabled) }\n+        }\n+   
}\n+\n     private func configGetResponse(key: String) -> [String: Any] {\n     
switch key {\n         case "voice_identity":\ndiff --git 
a/native/macos/Fae/Sources/Fae/Core/MLProtocols.swift 
b/native/macos/Fae/Sources/Fae/Core/MLProtocols.swift\nindex afd3627..b88bac5 
100644\n--- a/native/macos/Fae/Sources/Fae/Core/MLProtocols.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Core/MLProtocols.swift\n@@ -63,6 +63,11 @@ 
extension TTSEngine {\n     /// Default no-op for engines that don\'t support 
voice cloning.\n     func loadVoice(referenceAudioURL: URL, referenceText: 
String?) async throws {}\n     var isVoiceLoaded: Bool { false }\n+\n+    /// 
Default implementation delegates to `synthesize(text:)` ignoring 
voiceInstruct.\n+    func synthesize(text: String, voiceInstruct: String?) -> 
AsyncThrowingStream<AVAudioPCMBuffer, Error> {\n+        synthesize(text: 
text)\n+    }\n }\n \n /// Text embedding engine protocol for semantic memory 
search.\ndiff --git a/native/macos/Fae/Sources/Fae/Core/PersonalityManager.swift
b/native/macos/Fae/Sources/Fae/Core/PersonalityManager.swift\nindex 
ad4fce8..4563e6a 100644\n--- 
a/native/macos/Fae/Sources/Fae/Core/PersonalityManager.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Core/PersonalityManager.swift\n@@ -273,6 +273,12 
@@ enum PersonalityManager {\n                 """)\n         }\n \n+        // 
5b. Current date/time.\n+        let dateFormatter = DateFormatter()\n+        
dateFormatter.dateFormat = "EEEE, MMMM d, yyyy \'at\' h:mm a"\n+        
dateFormatter.locale = Locale(identifier: "en_US_POSIX")\n+        
parts.append("Current date and time: \\(dateFormatter.string(from: 
Date()))")\n+\n         // 6. Permission context.\n         
parts.append(PermissionStatusProvider.promptFragment())\n \ndiff --git 
a/native/macos/Fae/Sources/Fae/ML/CoreMLSpeakerEncoder.swift 
b/native/macos/Fae/Sources/Fae/ML/CoreMLSpeakerEncoder.swift\nindex 
e8e118a..56d61b7 100644\n--- 
a/native/macos/Fae/Sources/Fae/ML/CoreMLSpeakerEncoder.swift\n+++ 
b/native/macos/Fae/Sources/Fae/ML/CoreMLSpeakerEncoder.swift\n@@ -107,6 +107,13 
@@ actor CoreMLSpeakerEncoder: SpeakerEmbeddingEngine {\n             throw 
MLEngineError.notLoaded("SpeakerEncoder: audio too short for mel spectrogram")\n
}\n \n+        // Liveness check (non-blocking — log only).\n+        let 
liveness = Self.checkLiveness(mel: mel, numFrames: numFrames)\n+        if 
liveness.isSuspicious {\n+            NSLog("CoreMLSpeakerEncoder: liveness 
warning — low spectral variance (%.4f) and low high-freq ratio (%.4f), possible 
replay",\n+                  liveness.spectralVariance, 
liveness.highFreqRatio)\n+        }\n+\n         // Mel-spectral fallback: mean 
+ std of each mel band → 256-dim vector.\n         if usingMelFallback {\n      
return Self.melSpectralEmbed(mel: mel, numFrames: numFrames)\n@@ -402,6 +409,80 
@@ actor CoreMLSpeakerEncoder: SpeakerEmbeddingEngine {\n         throw 
MLEngineError.notLoaded("SpeakerEncoder: no valid output tensor found")\n     
}\n \n+    // MARK: - Liveness Heuristics\n+\n+    /// Result of basic 
replay/liveness checks on audio.\n+    struct LivenessCheck: Sendable {\n+      
/// Variance of mel-band energy across frames (low = potential replay).\n+      
let spectralVariance: Float\n+        /// Ratio of high-frequency energy to 
total (low = codec compression artifacts).\n+        let highFreqRatio: Float\n+
/// Whether the audio looks suspicious (not blocking — informational only).\n+  
let isSuspicious: Bool\n+    }\n+\n+    /// Run lightweight liveness heuristics 
on a log-mel spectrogram.\n+    ///\n+    /// Checks for two replay 
indicators:\n+    /// 1. **Spectral variance**: Real speech has dynamic formant 
variation across frames.\n+    ///    Recordings played through speakers tend to
be spectrally flatter.\n+    /// 2. **High-frequency energy**: Codec compression
(MP3, AAC, Opus) attenuates\n+    ///    energy above ~16 kHz. Raw microphone 
input preserves full bandwidth.\n+    ///\n+    /// Returns a `LivenessCheck` 
with findings. Does NOT block embedding —\n+    /// suspicion is logged for 
diagnostics only.\n+    static func checkLiveness(mel: [Float], numFrames: Int) 
-> LivenessCheck {\n+        guard numFrames > 1 else {\n+            return 
LivenessCheck(spectralVariance: 0, highFreqRatio: 0, isSuspicious: false)\n+    
}\n+\n+        // 1. Spectral variance: compute per-frame energy, then variance 
across frames.\n+        var frameEnergies = [Float](repeating: 0, count: 
numFrames)\n+        for f in 0..<numFrames {\n+            var energy: Float = 
0\n+            for m in 0..<numMels {\n+                energy += mel[m * 
numFrames + f]\n+            }\n+            frameEnergies[f] = energy / 
Float(numMels)\n+        }\n+\n+        var meanEnergy: Float = 0\n+        
vDSP_meanv(frameEnergies, 1, &meanEnergy, vDSP_Length(numFrames))\n+\n+        
var sumSqDiff: Float = 0\n+        for e in frameEnergies {\n+            let 
diff = e - meanEnergy\n+            sumSqDiff += diff * diff\n+        }\n+     
let spectralVariance = sumSqDiff / Float(numFrames)\n+\n+        // 2. 
High-frequency energy ratio: compare top 1/4 mel bands vs total.\n+        let 
highBandStart = numMels * 3 / 4  // top 32 of 128 bands\n+        var 
totalEnergy: Float = 0\n+        var highEnergy: Float = 0\n+        for m in 
0..<numMels {\n+            var bandSum: Float = 0\n+            let base = m * 
numFrames\n+            vDSP_sve(Array(mel[base..<(base + numFrames)]), 1, 
&bandSum, vDSP_Length(numFrames))\n+            totalEnergy += abs(bandSum)\n+  
if m >= highBandStart {\n+                highEnergy += abs(bandSum)\n+         
}\n+        }\n+        let highFreqRatio = totalEnergy > 1e-10 ? highEnergy / 
totalEnergy : 0\n+\n+        // Thresholds (empirically tuned — conservative to 
minimize false positives).\n+        let lowVariance = spectralVariance < 
0.05\n+        let lowHighFreq = highFreqRatio < 0.02\n+        let isSuspicious
= lowVariance && lowHighFreq\n+\n+        return LivenessCheck(\n+            
spectralVariance: spectralVariance,\n+            highFreqRatio: 
highFreqRatio,\n+            isSuspicious: isSuspicious\n+        )\n+    }\n+\n
// MARK: - L2 Normalization\n \n     private static func l2Normalize(_ vec: 
[Float]) -> [Float] {\ndiff --git 
a/native/macos/Fae/Sources/Fae/ML/SpeakerProfileStore.swift 
b/native/macos/Fae/Sources/Fae/ML/SpeakerProfileStore.swift\nindex 
42b846b..efba6d2 100644\n--- 
a/native/macos/Fae/Sources/Fae/ML/SpeakerProfileStore.swift\n+++ 
b/native/macos/Fae/Sources/Fae/ML/SpeakerProfileStore.swift\n@@ -16,6 +16,8 @@ 
actor SpeakerProfileStore {\n         let id: String\n         var label: 
String\n         var embeddings: [[Float]]\n+        /// Per-embedding 
timestamps (parallel to `embeddings`). Nil for legacy profiles.\n+        var 
embeddingDates: [Date]?\n         var centroid: [Float]\n         let 
enrolledAt: Date\n         var lastSeen: Date\n@@ -75,18 +77,23 @@ actor 
SpeakerProfileStore {\n \n     /// Enroll a new speaker or add an embedding to 
an existing profile.\n     func enroll(label: String, embedding: [Float]) {\n+  
let now = Date()\n         if let idx = profiles.firstIndex(where: { $0.label ==
label }) {\n             profiles[idx].embeddings.append(embedding)\n+          
var dates = profiles[idx].embeddingDates ?? []\n+            
dates.append(now)\n+            profiles[idx].embeddingDates = dates\n          
profiles[idx].centroid = Self.averageEmbeddings(profiles[idx].embeddings)\n-    
profiles[idx].lastSeen = Date()\n+            profiles[idx].lastSeen = now\n    
} else {\n             let profile = SpeakerProfile(\n                 id: 
UUID().uuidString,\n                 label: label,\n                 embeddings:
[embedding],\n+                embeddingDates: [now],\n                 
centroid: embedding,\n-                enrolledAt: Date(),\n-                
lastSeen: Date()\n+                enrolledAt: now,\n+                lastSeen: 
now\n             )\n             profiles.append(profile)\n         }\n@@ 
-100,9 +107,13 @@ actor SpeakerProfileStore {\n         guard let idx = 
profiles.firstIndex(where: { $0.label == label }) else { return }\n         
guard profiles[idx].embeddings.count < max else { return }\n \n+        let now 
= Date()\n         profiles[idx].embeddings.append(embedding)\n+        var 
dates = profiles[idx].embeddingDates ?? []\n+        dates.append(now)\n+       
profiles[idx].embeddingDates = dates\n         profiles[idx].centroid = 
Self.averageEmbeddings(profiles[idx].embeddings)\n-        
profiles[idx].lastSeen = Date()\n+        profiles[idx].lastSeen = now\n        
persist()\n     }\n \n@@ -112,6 +123,44 @@ actor SpeakerProfileStore {\n        
persist()\n     }\n \n+    /// Prune embeddings older than `maxAgeDays` from all
profiles.\n+    ///\n+    /// Prevents centroid drift as a speaker\'s voice 
changes over time.\n+    /// Profiles with no timestamps (legacy) are left 
untouched. Profiles\n+    /// are never deleted — only their oldest embeddings 
are removed.\n+    func pruneStaleEmbeddings(maxAgeDays: Int = 180) {\n+        
let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)\n+        
var changed = false\n+\n+        for idx in profiles.indices {\n+            
guard let dates = profiles[idx].embeddingDates,\n+                  dates.count 
== profiles[idx].embeddings.count\n+            else { continue }\n+\n+         
// Keep embeddings newer than cutoff, but always retain at least 1.\n+          
var keepIndices = [Int]()\n+            for (i, date) in dates.enumerated() 
where date >= cutoff {\n+                keepIndices.append(i)\n+            
}\n+            // Always keep the most recent embedding even if all are 
stale.\n+            if keepIndices.isEmpty, let lastIdx = dates.indices.last 
{\n+                keepIndices = [lastIdx]\n+            }\n+\n+            if 
keepIndices.count < profiles[idx].embeddings.count {\n+                let 
prunedCount = profiles[idx].embeddings.count - keepIndices.count\n+             
profiles[idx].embeddings = keepIndices.map { profiles[idx].embeddings[$0] }\n+  
profiles[idx].embeddingDates = keepIndices.map { dates[$0] }\n+                
profiles[idx].centroid = Self.averageEmbeddings(profiles[idx].embeddings)\n+    
changed = true\n+                NSLog("SpeakerProfileStore: pruned %d stale 
embeddings from \'%@\'",\n+                      prunedCount, 
profiles[idx].label)\n+            }\n+        }\n+\n+        if changed { 
persist() }\n+    }\n+\n     /// All enrolled profile labels.\n     var 
enrolledLabels: [String] {\n         profiles.map(\\.label)\ndiff --git 
a/native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift 
b/native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift\nindex 
b0e19cb..e9429c1 100644\n--- 
a/native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift\n@@ -32,12 +32,21
@@ actor MemoryOrchestrator {\n             guard !rerankedHits.isEmpty else { 
return nil }\n \n             let minConfidence: Float = 0.5\n+            let 
now = UInt64(Date().timeIntervalSince1970)\n+\n+            // Filter out stale 
records (past their staleAfterSecs expiry).\n+            let freshHits = 
rerankedHits.filter { hit in\n+                guard let staleSecs = 
hit.record.staleAfterSecs,\n+                      hit.record.createdAt > 0\n+  
else { return true }\n+                return (hit.record.createdAt + staleSecs)
> now\n+            }\n \n             // Split durable vs episode hits.\n-     
let durableHits = rerankedHits.filter {\n+            let durableHits = 
freshHits.filter {\n                 $0.record.kind != .episode && 
$0.record.confidence >= minConfidence\n             }\n-            let 
episodeHits = rerankedHits.filter {\n+            let episodeHits = 
freshHits.filter {\n                 $0.record.kind == .episode\n               
&& $0.score >= MemoryConstants.episodeThresholdLexical\n             }\n@@ -94,7
+103,9 @@ actor MemoryOrchestrator {\n                 text: episodeText,\n     
confidence: MemoryConstants.episodeConfidence,\n                 sourceTurnId: 
turnId,\n-                tags: ["turn"]\n+                tags: ["turn"],\n+   
importanceScore: 0.30,\n+                staleAfterSecs: 7_776_000  // 90 days\n
)\n             report.episodeId = episode.id\n \n@@ -116,7 +127,8 @@ actor 
MemoryOrchestrator {\n                         text: fact,\n                    
confidence: MemoryConstants.factRememberConfidence,\n                         
sourceTurnId: turnId,\n-                        tags: ["remembered"]\n+         
tags: ["remembered"],\n+                        importanceScore: 0.80\n         
)\n                     report.extractedCount += 1\n                 }\n@@ 
-136,12 +148,17 @@ actor MemoryOrchestrator {\n \n             // 5. Parse 
preference statements.\n             if let pref = extractPreference(from: 
lower, fullText: userText) {\n+                // Check for contradiction with 
existing preferences.\n+                try await supersedeContradiction(\n+    
tag: "preference", newText: pref, sourceTurnId: turnId\n+                )\n    
_ = try await store.insertRecord(\n                     kind: .profile,\n       
text: pref,\n                     confidence: 
MemoryConstants.profilePreferenceConfidence,\n                     sourceTurnId:
turnId,\n-                    tags: ["preference"]\n+                    tags: 
["preference"],\n+                    importanceScore: 0.85\n                 
)\n                 report.extractedCount += 1\n             }\n@@ -153,7 +170,8
@@ actor MemoryOrchestrator {\n                     text: interest,\n           
confidence: MemoryConstants.profilePreferenceConfidence,\n                     
sourceTurnId: turnId,\n-                    tags: ["interest"]\n+               
tags: ["interest"],\n+                    importanceScore: 0.70\n               
)\n                 report.extractedCount += 1\n             }\n@@ -165,7 +183,9
@@ actor MemoryOrchestrator {\n                     text: commitment,\n         
confidence: MemoryConstants.factConversationalConfidence,\n                     
sourceTurnId: turnId,\n-                    tags: ["commitment"]\n+             
tags: ["commitment"],\n+                    importanceScore: 0.90,\n+           
staleAfterSecs: 2_592_000  // 30 days\n                 )\n                 
report.extractedCount += 1\n             }\n@@ -177,7 +197,9 @@ actor 
MemoryOrchestrator {\n                     text: event,\n                     
confidence: MemoryConstants.factConversationalConfidence,\n                     
sourceTurnId: turnId,\n-                    tags: ["event"]\n+                  
tags: ["event"],\n+                    importanceScore: 0.85,\n+                
staleAfterSecs: 604_800  // 7 days\n                 )\n                 
report.extractedCount += 1\n             }\n@@ -189,7 +211,8 @@ actor 
MemoryOrchestrator {\n                     text: person,\n                     
confidence: MemoryConstants.factConversationalConfidence,\n                     
sourceTurnId: turnId,\n-                    tags: ["person"]\n+                 
tags: ["person"],\n+                    importanceScore: 0.75\n                 
)\n                 report.extractedCount += 1\n             }\n@@ -216,6 +239,7
@@ actor MemoryOrchestrator {\n     // MARK: - Private Helpers\n \n     /// 
Blend lexical and semantic ranking, with safe fallback to lexical ordering.\n+  
/// Uses cached embeddings when available to avoid recomputation.\n     private 
func rerankHitsIfPossible(query: String, hits: [MemorySearchHit]) async -> 
[MemorySearchHit] {\n         guard !hits.isEmpty else { return [] }\n \n@@ 
-235,7 +259,13 @@ actor MemoryOrchestrator {\n             
reranked.reserveCapacity(hits.count)\n \n             for hit in hits {\n-      
let recordEmbedding = try await embeddingEngine.embed(text: hit.record.text)\n+ 
// Use cached embedding if available, otherwise compute.\n+                let 
recordEmbedding: [Float]\n+                if let cached = 
hit.record.cachedEmbedding, !cached.isEmpty {\n+                    
recordEmbedding = cached\n+                } else {\n+                    
recordEmbedding = try await embeddingEngine.embed(text: hit.record.text)\n+     
}\n                 let semantic = cosineSimilarity(queryEmbedding, 
recordEmbedding)\n                 let blended = (lexicalWeight * hit.score) + 
(semanticWeight * semantic)\n                 
reranked.append(MemorySearchHit(record: hit.record, score: blended))\n@@ -274,6 
+304,44 @@ actor MemoryOrchestrator {\n         sqrt(vector.reduce(Float(0)) { 
$0 + ($1 * $1) })\n     }\n \n+    /// Supersede contradicting records for a 
given tag when new text diverges semantically.\n+    private func 
supersedeContradiction(tag: String, newText: String, sourceTurnId: String) async
throws {\n+        let existing = try await store.findActiveByTag(tag)\n+       
guard !existing.isEmpty else { return }\n+\n+        do {\n+            if 
!(await embeddingEngine.isLoaded) {\n+                try await 
embeddingEngine.load(modelID: "foundation-hash-384")\n+            }\n+         
let newEmbedding = try await embeddingEngine.embed(text: newText)\n+\n+         
for old in existing {\n+                let oldEmbedding: [Float]\n+            
if let cached = old.cachedEmbedding, !cached.isEmpty {\n+                    
oldEmbedding = cached\n+                } else {\n+                    
oldEmbedding = try await embeddingEngine.embed(text: old.text)\n+               
}\n+                let similarity = cosineSimilarity(newEmbedding, 
oldEmbedding)\n+                if similarity < 0.5 {\n+                    // 
Low similarity with same tag = contradiction → supersede.\n+                    
_ = try await store.supersedeRecord(\n+                        oldId: old.id,\n+
newText: newText,\n+                        confidence: old.confidence,\n+      
sourceTurnId: sourceTurnId,\n+                        tags: old.tags,\n+        
note: "contradiction detected (cosine=\\(String(format: "%.2f", 
similarity)))"\n+                    )\n+                    
NSLog("MemoryOrchestrator: superseded contradicting record %@ (tag=%@, 
cos=%.2f)",\n+                          old.id, tag, similarity)\n+             
}\n+            }\n+        } catch {\n+            NSLog("MemoryOrchestrator: 
contradiction check error: %@", error.localizedDescription)\n+        }\n+    
}\n+\n     /// Forget records matching a query.\n     private func 
forgetMatching(query: String) async throws -> Int {\n         let hits = try 
await store.search(query: query, limit: 5)\n@@ -292,7 +360,8 @@ actor 
MemoryOrchestrator {\n         confidence: Float,\n         sourceTurnId: 
String,\n         allTags: [String],\n-        report: inout 
MemoryCaptureReport\n+        report: inout MemoryCaptureReport,\n+        
importanceScore: Float = 1.0\n     ) async throws {\n         let existing = try
await store.findActiveByTag(tag)\n \n@@ -312,7 +381,8 @@ actor 
MemoryOrchestrator {\n                 text: text,\n                 confidence:
confidence,\n                 sourceTurnId: sourceTurnId,\n-                
tags: allTags\n+                tags: allTags,\n+                
importanceScore: importanceScore\n             )\n             
report.extractedCount += 1\n         }\ndiff --git 
a/native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift 
b/native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift\nindex b60edf8..ea3a130 
100644\n--- a/native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift\n@@ -48,6 +48,7 @@ 
struct MemoryRecord: Sendable {\n     var importanceScore: Float?\n     var 
staleAfterSecs: UInt64?\n     var metadata: String?\n+    var cachedEmbedding: 
[Float]?\n }\n \n struct MemoryAuditEntry: Sendable {\n@@ -73,7 +74,7 @@ struct 
MemoryCaptureReport: Sendable {\n // MARK: - Constants\n \n enum MemoryConstants
{\n-    static let schemaVersion: UInt32 = 3\n+    static let schemaVersion: 
UInt32 = 4\n     static let maxRecordTextLen: Int = 32_768\n     static let 
truncationSuffix: String = " [truncated]"\n \n@@ -87,6 +88,7 @@ enum 
MemoryConstants {\n     // Lexical scoring\n     static let 
scoreEmptyQueryBaseline: Float = 0.20\n     static let scoreConfidenceWeight: 
Float = 0.20\n+    static let scoreImportanceWeight: Float = 0.15\n     static 
let scoreFreshnessWeight: Float = 0.10\n     static let scoreKindBonusProfile: 
Float = 0.05\n     static let scoreKindBonusFact: Float = 0.03\n@@ -140,10 
+142,22 @@ func scoreRecord(_ record: MemoryRecord, queryTokens: [String]) -> 
Float {\n \n     score += MemoryConstants.scoreConfidenceWeight * 
min(max(record.confidence, 0), 1)\n \n+    // Importance scoring — use stored 
importanceScore when available.\n+    if let importance = record.importanceScore
{\n+        score += MemoryConstants.scoreImportanceWeight * min(max(importance,
0), 1)\n+    }\n+\n+    // Exponential temporal decay with kind-gated 
half-lives.\n     let now = UInt64(Date().timeIntervalSince1970)\n     if 
record.updatedAt > 0, record.updatedAt <= now {\n         let ageDays = 
Float(now - record.updatedAt) / MemoryConstants.secsPerDay\n-        let 
freshness = 1.0 / (1.0 + ageDays)\n+        let halfLife: Float = switch 
record.kind {\n+        case .episode: 30\n+        case .fact, .interest, 
.commitment, .event, .person: 180\n+        case .profile: 365\n+        }\n+   
let decay = exp(-0.693 * ageDays / halfLife)\n+        let freshness = 0.7 + 0.3
* decay  // floors at 0.7 so old memories still surface\n         score += 
MemoryConstants.scoreFreshnessWeight * freshness\n     }\n \ndiff --git 
a/native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift 
b/native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift\nindex 
420ccd0..d9769d4 100644\n--- 
a/native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift\n@@ -53,9 +53,42 
@@ actor SQLiteMemoryStore {\n                 updated_at       INTEGER NOT NULL
DEFAULT 0,\n                 importance_score REAL,\n                 
stale_after_secs INTEGER,\n-                metadata         TEXT\n+            
metadata         TEXT,\n+                embedding        BLOB\n             )\n
""")\n+\n+        // Migration: add embedding column if missing (v3 → v4).\n+   
let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(memory_records)")\n+ 
let columnNames = Set(columns.map { $0["name"] as String })\n+        if 
!columnNames.contains("embedding") {\n+            try db.execute(sql: "ALTER 
TABLE memory_records ADD COLUMN embedding BLOB")\n+        }\n+\n+        // 
FTS5 full-text index for fast candidate selection.\n+        try db.execute(sql:
"""\n+            CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(\n+  
text, content=\'memory_records\', content_rowid=\'rowid\'\n+            )\n+    
""")\n+\n+        // Triggers to keep FTS in sync.\n+        try db.execute(sql:
"""\n+            CREATE TRIGGER IF NOT EXISTS memory_fts_insert AFTER INSERT ON
memory_records BEGIN\n+                INSERT INTO memory_fts(rowid, text) 
VALUES (new.rowid, new.text);\n+            END\n+            """)\n+        try
db.execute(sql: """\n+            CREATE TRIGGER IF NOT EXISTS memory_fts_delete
AFTER DELETE ON memory_records BEGIN\n+                INSERT INTO 
memory_fts(memory_fts, rowid, text) VALUES(\'delete\', old.rowid, old.text);\n+ 
END\n+            """)\n+        try db.execute(sql: """\n+            CREATE 
TRIGGER IF NOT EXISTS memory_fts_update AFTER UPDATE OF text ON memory_records 
BEGIN\n+                INSERT INTO memory_fts(memory_fts, rowid, text) 
VALUES(\'delete\', old.rowid, old.text);\n+                INSERT INTO 
memory_fts(rowid, text) VALUES (new.rowid, new.text);\n+            END\n+      
""")\n         try db.execute(sql: "CREATE INDEX IF NOT EXISTS 
idx_records_status ON memory_records(status)")\n         try db.execute(sql: 
"CREATE INDEX IF NOT EXISTS idx_records_kind ON memory_records(kind)")\n        
try db.execute(\n@@ -95,7 +128,10 @@ actor SQLiteMemoryStore {\n         text: 
String,\n         confidence: Float,\n         sourceTurnId: String?,\n-        
tags: [String]\n+        tags: [String],\n+        importanceScore: Float? = 
nil,\n+        staleAfterSecs: UInt64? = nil,\n+        embedding: [Float]? = 
nil\n     ) throws -> MemoryRecord {\n         let now = 
UInt64(Date().timeIntervalSince1970)\n         let record = MemoryRecord(\n@@ 
-107,17 +143,23 @@ actor SQLiteMemoryStore {\n             sourceTurnId: 
sourceTurnId,\n             tags: tags,\n             createdAt: now,\n-        
updatedAt: now\n+            updatedAt: now,\n+            importanceScore: 
importanceScore,\n+            staleAfterSecs: staleAfterSecs\n         )\n \n+ 
let embeddingData: Data? = embedding.map { floats in\n+            
floats.withUnsafeBufferPointer { Data(buffer: $0) }\n+        }\n+\n         try
dbQueue.write { db in\n             let tagsJSON = Self.encodeTags(tags)\n      
try db.execute(\n                 sql: """\n                     INSERT INTO 
memory_records\n                         (id, kind, status, text, confidence, 
source_turn_id, tags, supersedes,\n-                         created_at, 
updated_at, importance_score, stale_after_secs, metadata)\n-                    
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)\n+                         
created_at, updated_at, importance_score, stale_after_secs, metadata, 
embedding)\n+                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 
?)\n                     """,\n                 arguments: [\n                  
record.id, record.kind.rawValue, record.status.rawValue,\n@@ -126,6 +168,7 @@ 
actor SQLiteMemoryStore {\n                     record.createdAt, 
record.updatedAt,\n                     record.importanceScore.map { Double($0) 
},\n                     record.staleAfterSecs, record.metadata,\n+             
embeddingData,\n                 ]\n             )\n \n@@ -225,12 +268,27 @@ 
actor SQLiteMemoryStore {\n         }\n     }\n \n-    // MARK: - Search 
(Lexical)\n+    // MARK: - Search (FTS5 + Lexical Scoring)\n \n     func 
search(query: String, limit: Int, includeInactive: Bool = false) throws -> 
[MemorySearchHit] {\n-        let records = try listRecords(includeInactive: 
includeInactive)\n         let queryTokens = tokenizeForSearch(query)\n \n+     
// Try FTS5 candidate selection first for efficiency.\n+        let candidates: 
[MemoryRecord]\n+        if !queryTokens.isEmpty {\n+            candidates = 
try ftsSearch(query: query, limit: max(limit * 5, 50), includeInactive: 
includeInactive)\n+        } else {\n+            candidates = []\n+        
}\n+\n+        // Fall back to full scan if FTS returned too few results or 
query is empty.\n+        let records: [MemoryRecord]\n+        if 
candidates.count < limit {\n+            records = try 
listRecords(includeInactive: includeInactive)\n+        } else {\n+            
records = candidates\n+        }\n+\n         var hits = records.map { record 
in\n             MemorySearchHit(record: record, score: scoreRecord(record, 
queryTokens: queryTokens))\n         }\n@@ -238,6 +296,27 @@ actor 
SQLiteMemoryStore {\n         return Array(hits.prefix(limit))\n     }\n \n+    
/// FTS5-based candidate selection — returns records matching the query text.\n+
private func ftsSearch(query: String, limit: Int, includeInactive: Bool) throws 
-> [MemoryRecord] {\n+        try dbQueue.read { db in\n+            // Escape 
FTS5 special characters and form a simple query.\n+            let ftsQuery = 
tokenizeForSearch(query).joined(separator: " OR ")\n+            guard 
!ftsQuery.isEmpty else { return [] }\n+\n+            let statusFilter = 
includeInactive ? "" : "AND r.status = \'active\'"\n+            let sql = 
"""\n+                SELECT r.* FROM memory_records r\n+                INNER 
JOIN memory_fts f ON f.rowid = r.rowid\n+                WHERE memory_fts MATCH 
?\n+                \\(statusFilter)\n+                ORDER BY rank\n+         
LIMIT ?\n+                """\n+            let rows = try Row.fetchAll(db, sql:
sql, arguments: [ftsQuery, limit])\n+            return rows.map { 
Self.recordFromRow($0) }\n+        }\n+    }\n+\n     // MARK: - List\n \n     
func listRecords(includeInactive: Bool = false) throws -> [MemoryRecord] {\n@@ 
-269,6 +348,23 @@ actor SQLiteMemoryStore {\n         }\n     }\n \n+    /// 
Find active records of a specific kind.\n+    func findActiveByKind(_ kind: 
MemoryKind, limit: Int = 20) throws -> [MemoryRecord] {\n+        try 
dbQueue.read { db in\n+            let rows = try Row.fetchAll(\n+              
db,\n+                sql: """\n+                    SELECT * FROM 
memory_records\n+                    WHERE status = \'active\' AND kind = ?\n+  
ORDER BY updated_at DESC\n+                    LIMIT ?\n+                    
""",\n+                arguments: [kind.rawValue, limit]\n+            )\n+     
return rows.map { Self.recordFromRow($0) }\n+        }\n+    }\n+\n     /// 
Fetch the most recent active records, ordered by updated_at descending.\n     
func recentRecords(limit: Int) throws -> [MemoryRecord] {\n         try 
dbQueue.read { db in\n@@ -328,6 +424,16 @@ actor SQLiteMemoryStore {\n         
let tagsStr: String = row["tags"]\n         let tags = decodeTags(tagsStr)\n \n+
var cachedEmbedding: [Float]?\n+        if let data = row["embedding"] as? Data,
!data.isEmpty {\n+            cachedEmbedding = data.withUnsafeBytes { buffer 
in\n+                guard let baseAddress = buffer.baseAddress else { return 
nil }\n+                let count = data.count / MemoryLayout<Float>.size\n+    
let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)\n+            
return Array(UnsafeBufferPointer(start: floatBuffer, count: count))\n+          
}\n+        }\n+\n         return MemoryRecord(\n             id: row["id"],\n  
kind: MemoryKind(rawValue: row["kind"] as String) ?? .fact,\n@@ -341,7 +447,8 @@
actor SQLiteMemoryStore {\n             updatedAt: UInt64(row["updated_at"] as 
Int64),\n             importanceScore: (row["importance_score"] as Double?).map 
{ Float($0) },\n             staleAfterSecs: (row["stale_after_secs"] as 
Int64?).map { UInt64($0) },\n-            metadata: row["metadata"]\n+          
metadata: row["metadata"],\n+            cachedEmbedding: cachedEmbedding\n     
)\n     }\n \ndiff --git 
a/native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift 
b/native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift\nindex 
c0c9421..3d3f641 100644\n--- 
a/native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift\n@@ -50,6 
+50,7 @@ actor PipelineCoordinator {\n     private let registry: ToolRegistry\n 
private let speakerEncoder: CoreMLSpeakerEncoder?\n     private let 
speakerProfileStore: SpeakerProfileStore?\n+    private let toolAnalytics: 
ToolAnalytics?\n \n     // MARK: - Pipeline State\n \n@@ -88,6 +89,7 @@ actor 
PipelineCoordinator {\n \n     private var pipelineStartedAt: Date?\n     
private var firstAudioLatencyEmitted: Bool = false\n+    private let 
instrumentation = PipelineInstrumentation()\n \n     struct PendingBargeIn {\n  
var capturedAt: Date\n@@ -115,7 +117,8 @@ actor PipelineCoordinator {\n         
approvalManager: ApprovalManager? = nil,\n         registry: ToolRegistry,\n    
speakerEncoder: CoreMLSpeakerEncoder? = nil,\n-        speakerProfileStore: 
SpeakerProfileStore? = nil\n+        speakerProfileStore: SpeakerProfileStore? =
nil,\n+        toolAnalytics: ToolAnalytics? = nil\n     ) {\n         
self.eventBus = eventBus\n         self.capture = capture\n@@ -130,6 +133,7 @@ 
actor PipelineCoordinator {\n         self.registry = registry\n         
self.speakerEncoder = speakerEncoder\n         self.speakerProfileStore = 
speakerProfileStore\n+        self.toolAnalytics = toolAnalytics\n \n         //
Configure VAD from config.\n         vad.threshold = config.vad.threshold\n@@ 
-566,8 +570,15 @@ actor PipelineCoordinator {\n                 if 
roleplayActive {\n                     let segments = 
voiceTagStripper.process(visible)\n                     for segment in segments 
{\n-                        let voice = await segment.character.asyncFlatMap 
{\n-                            await 
RoleplaySessionStore.shared.voiceForCharacter($0)\n+                        let 
voice: String?\n+                        if let character = segment.character 
{\n+                            let matched = await 
RoleplaySessionStore.shared.voiceForCharacter(character)\n+                     
if matched == nil {\n+                                
NSLog("PipelineCoordinator: unassigned character \'%@\' — using narrator voice",
character)\n+                            }\n+                            voice =
matched\n+                        } else {\n+                            voice =
nil\n                         }\n                         let cleaned = 
TextProcessing.stripNonSpeechChars(segment.text)\n                         if 
!cleaned.isEmpty {\n@@ -624,8 +635,15 @@ actor PipelineCoordinator {\n          
let voiceRemaining = voiceTagStripper.process(remaining) + 
voiceTagStripper.flush()\n                 var spokeSomething = false\n         
for segment in voiceRemaining {\n-                    let voice = await 
segment.character.asyncFlatMap {\n-                        await 
RoleplaySessionStore.shared.voiceForCharacter($0)\n+                    let 
voice: String?\n+                    if let character = segment.character {\n+  
let matched = await RoleplaySessionStore.shared.voiceForCharacter(character)\n+ 
if matched == nil {\n+                            NSLog("PipelineCoordinator: 
unassigned character \'%@\' — using narrator voice", character)\n+              
}\n+                        voice = matched\n+                    } else {\n+   
voice = nil\n                     }\n                     let cleaned = 
TextProcessing.stripNonSpeechChars(segment.text)\n                     if 
!cleaned.isEmpty {\n@@ -920,22 +938,53 @@ actor PipelineCoordinator {\n         
return .error("Unknown tool: \\(call.name)")\n         }\n \n-        // Check 
approval if required.\n-        if tool.requiresApproval {\n+        let 
voiceDecision = VoiceIdentityPolicy.evaluateSensitiveAction(\n+            
config: config.speaker,\n+            isOwner: currentSpeakerIsOwner,\n+        
risk: tool.riskLevel,\n+            toolName: call.name\n+        )\n+\n+       
switch voiceDecision {\n+        case .allow:\n+            break\n+        case
.requireStepUp(let message):\n             if let manager = approvalManager {\n 
let approved = await manager.requestApproval(\n                     toolName: 
call.name,\n-                    description: "Execute \\(call.name)"\n+        
description: "Step-up: \\(message)"\n                 )\n                 if 
!approved {\n                     return .error("Tool execution denied by 
user.")\n                 }\n+            } else {\n+                return 
.error(message)\n             }\n+        case .deny(let message):\n+           
return .error(message)\n         }\n \n-        // Execute with timeout.\n+     
// Risk policy + approval routing.\n+        let decision = 
ToolRiskPolicy.decision(for: tool)\n+        if case .requireApproval(let 
reason) = decision {\n+            if let manager = approvalManager {\n+        
let approved = await manager.requestApproval(\n+                    toolName: 
call.name,\n+                    description: "Execute \\(call.name) — 
\\(reason)"\n+                )\n+                if !approved {\n+             
return .error("Tool execution denied by user.")\n+                }\n+          
} else {\n+                return .error("Tool requires approval, but no 
approval manager is available.")\n+            }\n+        }\n+\n+        // 
Execute with timeout and analytics.\n+        let startTime = Date()\n+        
let result: ToolResult\n         do {\n-            return try await 
withThrowingTaskGroup(of: ToolResult.self) { group in\n+            result = try
await withThrowingTaskGroup(of: ToolResult.self) { group in\n                 
group.addTask {\n                     try await tool.execute(input: 
call.arguments)\n                 }\n@@ -943,13 +992,33 @@ actor 
PipelineCoordinator {\n                     try await Task.sleep(nanoseconds: 
UInt64(Self.toolTimeoutSeconds * 1_000_000_000))\n                     return 
.error("Tool timed out after \\(Int(Self.toolTimeoutSeconds))s")\n              
}\n-                let result = try await group.next()!\n+                let r
= try await group.next()!\n                 group.cancelAll()\n-                
return result\n+                return r\n             }\n         } catch {\n+ 
let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)\n+            if
let analytics = toolAnalytics {\n+                await analytics.record(\n+    
toolName: call.name, success: false, latencyMs: latencyMs,\n+                   
approved: true, error: error.localizedDescription\n+                )\n+        
}\n             return .error("Tool error: \\(error.localizedDescription)")\n   
}\n+\n+        let latencyMs = Int(Date().timeIntervalSince(startTime) * 
1000)\n+        if let analytics = toolAnalytics {\n+            await 
analytics.record(\n+                toolName: call.name,\n+                
success: !result.isError,\n+                latencyMs: latencyMs,\n+            
approved: true,\n+                error: result.isError ? result.output : nil\n+
)\n+        }\n+\n+        return result\n     }\n \n     // MARK: - 
Helpers\ndiff --git a/native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift 
b/native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift\nindex 
fe46cfc..219c98a 100644\n--- 
a/native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift\n@@ -10,8 +10,17 @@ 
actor FaeScheduler {\n     private let eventBus: FaeEventBus\n     private let 
memoryOrchestrator: MemoryOrchestrator?\n     private let memoryStore: 
SQLiteMemoryStore?\n+    private var config: FaeConfig.SchedulerConfig\n     
private var timers: [String: DispatchSourceTimer] = [:]\n     private var 
isRunning = false\n+    private var disabledTaskIDs: Set<String> = []\n+    
private var runHistory: [String: [Date]] = [:]\n+\n+    /// Persistence store 
for scheduler state (optional, injected by FaeCore).\n+    private var 
persistenceStore: SchedulerPersistenceStore?\n+\n+    /// Task run ledger for 
idempotency and retry tracking.\n+    private(set) var taskRunLedger: 
TaskRunLedger = TaskRunLedger()\n \n     /// Closure to make Fae speak — set by 
FaeCore after pipeline is ready.\n     var speakHandler: (@Sendable (String) 
async -> Void)?\n@@ -19,14 +28,19 @@ actor FaeScheduler {\n     /// Daily 
proactive interjection counter, reset at midnight.\n     private var 
proactiveInterjectionCount: Int = 0\n \n+    /// Tracks which interests have 
already had skill proposals surfaced.\n+    private var suggestedInterestIDs: 
Set<String> = []\n+\n     init(\n         eventBus: FaeEventBus,\n         
memoryOrchestrator: MemoryOrchestrator? = nil,\n-        memoryStore: 
SQLiteMemoryStore? = nil\n+        memoryStore: SQLiteMemoryStore? = nil,\n+    
config: FaeConfig.SchedulerConfig = FaeConfig.SchedulerConfig()\n     ) {\n     
self.eventBus = eventBus\n         self.memoryOrchestrator = 
memoryOrchestrator\n         self.memoryStore = memoryStore\n+        
self.config = config\n     }\n \n     /// Set the speak handler (must be called 
before start for morning briefings to work).\n@@ -34,6 +48,23 @@ actor 
FaeScheduler {\n         speakHandler = handler\n     }\n \n+    /// Configure 
persistence — creates a persistence-backed ledger and loads saved state.\n+    
func configurePersistence(store: SchedulerPersistenceStore) async {\n+        
self.persistenceStore = store\n+        self.taskRunLedger = 
TaskRunLedger(store: store)\n+\n+        // Load persisted disabled task IDs.\n+
do {\n+            let saved = try await store.loadDisabledTaskIDs()\n+         
disabledTaskIDs = saved\n+            if !saved.isEmpty {\n+                
NSLog("FaeScheduler: loaded %d disabled tasks from persistence", saved.count)\n+
}\n+        } catch {\n+            NSLog("FaeScheduler: failed to load disabled
tasks: %@", error.localizedDescription)\n+        }\n+    }\n+\n     // MARK: - 
Lifecycle\n \n     func start() {\n@@ -81,30 +112,78 @@ actor FaeScheduler {\n  
NSLog("FaeScheduler: memory_reflect — running")\n         guard let store = 
memoryStore else { return }\n         do {\n-            // Query recent active 
records and look for near-duplicates by text overlap.\n             let records 
= try await store.recentRecords(limit: 100)\n             var mergedCount = 0\n-
var seen: Set<String> = []\n-\n-            for record in records where 
record.status == .active && record.kind != .episode {\n-                let key 
= record.text.lowercased().prefix(80).trimmingCharacters(in: .whitespaces)\n-   
if seen.contains(key) {\n-                    // Duplicate found — soft-forget 
the older one.\n-                    try await store.forgetSoftRecord(id: 
record.id, note: "memory_reflect: duplicate")\n-                    mergedCount 
+= 1\n-                } else {\n-                    seen.insert(key)\n+\n+    
// Group non-episode active records by kind for pairwise comparison.\n+         
let durable = records.filter { $0.status == .active && $0.kind != .episode }\n+ 
let grouped = Dictionary(grouping: durable) { $0.kind }\n+\n+            for (_,
group) in grouped where group.count > 1 {\n+                var superseded: 
Set<String> = []\n+                for i in 0 ..< group.count {\n+              
guard !superseded.contains(group[i].id) else { continue }\n+                    
for j in (i + 1) ..< group.count {\n+                        guard 
!superseded.contains(group[j].id) else { continue }\n+\n+                       
// Use cached embeddings if available, fall back to text prefix match.\n+       
let similar: Bool\n+                        if let embA = 
group[i].cachedEmbedding, !embA.isEmpty,\n+                           let embB =
group[j].cachedEmbedding, !embB.isEmpty\n+                        {\n+          
similar = cosineSimilarity(embA, embB) > 0.92\n+                        } else 
{\n+                            let keyA = 
group[i].text.lowercased().prefix(80)\n+                                
.trimmingCharacters(in: .whitespaces)\n+                            let keyB = 
group[j].text.lowercased().prefix(80)\n+                                
.trimmingCharacters(in: .whitespaces)\n+                            similar = 
keyA == keyB\n+                        }\n+\n+                        if similar
{\n+                            // Keep the higher-confidence record, supersede 
the other.\n+                            let (keep, drop) = group[i].confidence 
>= group[j].confidence\n+                                ? (group[i], 
group[j])\n+                                : (group[j], group[i])\n+           
try await store.forgetSoftRecord(\n+                                id: 
drop.id,\n+                                note: "memory_reflect: semantic 
duplicate of \\(keep.id)"\n+                            )\n+                    
superseded.insert(drop.id)\n+                            mergedCount += 1\n+    
}\n+                    }\n                 }\n             }\n \n             
if mergedCount > 0 {\n-                NSLog("FaeScheduler: memory_reflect — 
cleaned %d duplicates", mergedCount)\n+                NSLog("FaeScheduler: 
memory_reflect — cleaned %d semantic duplicates", mergedCount)\n             }\n
} catch {\n             NSLog("FaeScheduler: memory_reflect — error: %@", 
error.localizedDescription)\n         }\n     }\n \n+    /// Cosine similarity 
between two float vectors.\n+    private func cosineSimilarity(_ lhs: [Float], _
rhs: [Float]) -> Float {\n+        let length = min(lhs.count, rhs.count)\n+    
guard length > 0 else { return 0 }\n+\n+        var dot: Float = 0\n+        var
lhsSq: Float = 0\n+        var rhsSq: Float = 0\n+\n+        for i in 0 ..< 
length {\n+            dot += lhs[i] * rhs[i]\n+            lhsSq += lhs[i] * 
lhs[i]\n+            rhsSq += rhs[i] * rhs[i]\n+        }\n+\n+        let denom
= sqrt(lhsSq) * sqrt(rhsSq)\n+        guard denom > 0 else { return 0 }\n+      
return dot / denom\n+    }\n+\n     private func runMemoryReindex() async {\n   
NSLog("FaeScheduler: memory_reindex — running")\n         do {\n@@ -149,51 
+228,130 @@ actor FaeScheduler {\n \n     private func runMorningBriefing() 
async {\n         NSLog("FaeScheduler: morning_briefing — running")\n-        
guard let orchestrator = memoryOrchestrator else { return }\n+        guard let 
store = memoryStore else { return }\n \n-        // 1. Gather recent memories 
(commitments, events, people).\n-        let commitmentContext = await 
orchestrator.recall(query: "upcoming deadlines and commitments")\n-        let 
eventContext = await orchestrator.recall(query: "upcoming events and dates")\n- 
let peopleContext = await orchestrator.recall(query: "people to check in 
with")\n+        do {\n+            var items: [String] = []\n+\n+            //
1. Query commitments — extract actual text.\n+            let commitments = try 
await store.findActiveByKind(.commitment, limit: 5)\n+            for record in 
commitments {\n+                let text = record.text\n+                    
.replacingOccurrences(of: "User commitment: ", with: "")\n+                    
.trimmingCharacters(in: .whitespacesAndNewlines)\n+                if 
!text.isEmpty {\n+                    items.append("you mentioned \\(text)")\n+ 
}\n+            }\n \n-        // 2. Compile a brief summary.\n-        var 
items: [String] = []\n-        if let ctx = commitmentContext, !ctx.isEmpty {\n-
items.append("You have some upcoming commitments I recall.")\n-        }\n-     
if let ctx = eventContext, !ctx.isEmpty {\n-            items.append("There are 
events coming up worth noting.")\n-        }\n-        if let ctx = 
peopleContext, !ctx.isEmpty {\n-            items.append("There are people you 
might want to check in with.")\n-        }\n+            // 2. Query events — 
include details.\n+            let events = try await 
store.findActiveByKind(.event, limit: 3)\n+            for record in events {\n+
let text = record.text\n+                    .replacingOccurrences(of: "User 
event: ", with: "")\n+                    .trimmingCharacters(in: 
.whitespacesAndNewlines)\n+                if !text.isEmpty {\n+                
items.append(text)\n+                }\n+            }\n \n-        guard 
!items.isEmpty else {\n-            NSLog("FaeScheduler: morning_briefing — 
nothing to report")\n-            return\n-        }\n+            // 3. Query 
people — mention specific names.\n+            let people = try await 
store.findActiveByKind(.person, limit: 2)\n+            let now = 
UInt64(Date().timeIntervalSince1970)\n+            let sevenDays: UInt64 = 7 * 
24 * 3600\n+            for record in people where record.updatedAt > 0 && (now 
- record.updatedAt) > sevenDays {\n+                let name = 
extractPersonName(from: record.text)\n+                if !name.isEmpty {\n+    
items.append("it\'s been a while since you mentioned \\(name)")\n+              
}\n+            }\n+\n+            guard !items.isEmpty else {\n+               
NSLog("FaeScheduler: morning_briefing — nothing meaningful to report")\n+       
return\n+            }\n+\n+            // Limit to 3 items max.\n+            
let selected = Array(items.prefix(3))\n+            let briefing: String\n+     
if selected.count == 1 {\n+                briefing = "Good morning! Just a 
heads up — \\(selected[0])."\n+            } else {\n+                let joined
= selected.dropLast().joined(separator: ", ")\n+                briefing = "Good
morning! Just a heads up — \\(joined), and \\(selected.last ?? "")."\n+         
}\n \n-        let briefing = "Good morning! " + items.joined(separator: " ") + 
" Want me to go into detail on any of these?"\n-        NSLog("FaeScheduler: 
morning_briefing — delivering %d items", items.count)\n+            
NSLog("FaeScheduler: morning_briefing — delivering %d items", selected.count)\n+
if let speak = speakHandler {\n+                await speak(briefing)\n+        
}\n+        } catch {\n+            NSLog("FaeScheduler: morning_briefing — 
error: %@", error.localizedDescription)\n+        }\n+    }\n \n-        // 3. 
Speak the briefing if the handler is wired.\n-        if let speak = 
speakHandler {\n-            await speak(briefing)\n+    /// Extract a person\'s
name from memory text like "User knows: my sister Sarah works at..."\n+    
private func extractPersonName(from text: String) -> String {\n+        let 
cleaned = text\n+            .replacingOccurrences(of: "User knows: ", with: 
"")\n+            .trimmingCharacters(in: .whitespacesAndNewlines)\n+\n+        
// Try to find a capitalized name word after the relationship prefix.\n+        
let relationshipPrefixes = [\n+            "my wife ", "my husband ", "my 
partner ",\n+            "my sister ", "my brother ", "my mom ", "my mum ", "my 
dad ",\n+            "my daughter ", "my son ", "my friend ", "my colleague 
",\n+            "my boss ", "my manager ", "my girlfriend ", "my boyfriend 
",\n+        ]\n+        let lower = cleaned.lowercased()\n+        for prefix 
in relationshipPrefixes {\n+            if lower.hasPrefix(prefix) {\n+         
let afterPrefix = String(cleaned.dropFirst(prefix.count))\n+                let 
firstWord = afterPrefix.prefix(while: { $0.isLetter || $0 == "-" })\n+          
.trimmingCharacters(in: .whitespaces)\n+                if !firstWord.isEmpty 
{\n+                    return firstWord\n+                }\n+            }\n  
}\n+\n+        // Fall back to first 30 chars.\n+        return 
String(cleaned.prefix(30))\n     }\n \n     private func runSkillProposals() 
async {\n         NSLog("FaeScheduler: skill_proposals — running")\n         
guard let store = memoryStore else { return }\n         do {\n-            // 
Look for interest-type memories that might benefit from a dedicated skill.\n    
let interests = try await store.findActiveByTag("interest")\n-            let 
preferences = try await store.findActiveByTag("preference")\n \n-            let
total = interests.count + preferences.count\n-            if total > 3 {\n-     
NSLog("FaeScheduler: skill_proposals — %d interests/preferences found, may 
suggest skills", total)\n-                // Future: surface suggestion via 
eventBus or speakHandler.\n+            // Find an interest we haven\'t 
suggested yet.\n+            let unsuggestedInterest = interests.first { 
!suggestedInterestIDs.contains($0.id) }\n+            guard let interest = 
unsuggestedInterest else {\n+                NSLog("FaeScheduler: 
skill_proposals — no unsurfaced interests")\n+                return\n+         
}\n+\n+            // Extract the topic from the interest text.\n+            
let topic = interest.text\n+                .replacingOccurrences(of: "User is 
interested in: ", with: "")\n+                .trimmingCharacters(in: 
.whitespacesAndNewlines)\n+\n+            guard !topic.isEmpty else { return 
}\n+\n+            // Mark as suggested so we don\'t repeat.\n+            
suggestedInterestIDs.insert(interest.id)\n+\n+            let phrases = [\n+    
"I noticed you\'re into \\(topic). I could write a quick script to track updates
on that. Want me to?",\n+                "Hey, since you\'re interested in 
\\(topic), I could build a little skill to help with that. Shall I?",\n+        
"By the way, I could create a Python skill around \\(topic) to keep you updated.
Interested?",\n+            ]\n+            let suggestion = 
phrases[Int.random(in: 0 ..< phrases.count)]\n+\n+            
NSLog("FaeScheduler: skill_proposals — suggesting skill for \'%@\'", topic)\n+  
if let speak = speakHandler {\n+                await speak(suggestion)\n       
}\n         } catch {\n             NSLog("FaeScheduler: skill_proposals — 
error: %@", error.localizedDescription)\n@@ -208,16 +366,32 @@ actor 
FaeScheduler {\n             let now = UInt64(Date().timeIntervalSince1970)\n   
let thirtyDays: UInt64 = 30 * 24 * 3600\n \n-            var staleNames: 
[String] = []\n+            // Find stale contacts (not mentioned in 30+ 
days).\n+            var staleRecords: [MemoryRecord] = []\n             for 
record in personRecords {\n                 if record.updatedAt > 0, (now - 
record.updatedAt) > thirtyDays {\n-                    
staleNames.append(record.text)\n+                    
staleRecords.append(record)\n                 }\n             }\n \n-           
if !staleNames.isEmpty {\n-                NSLog("FaeScheduler: 
stale_relationships — %d stale contacts found", staleNames.count)\n-            
// Future: surface as gentle briefing item.\n+            guard let staleRecord 
= staleRecords.first else {\n+                NSLog("FaeScheduler: 
stale_relationships — no stale contacts")\n+                return\n+           
}\n+\n+            let name = extractPersonName(from: staleRecord.text)\n+      
guard !name.isEmpty else { return }\n+\n+            let phrases = [\n+         
"By the way, you haven\'t mentioned \\(name) in a while. Everything good?",\n+  
"Just a thought — it\'s been a while since \\(name) came up. Might be worth 
reaching out.",\n+                "Hey, I noticed you haven\'t talked about 
\\(name) recently. Hope all is well.",\n+            ]\n+            let 
reminder = phrases[Int.random(in: 0 ..< phrases.count)]\n+\n+            
NSLog("FaeScheduler: stale_relationships — reminding about \'%@\'", name)\n+    
if let speak = speakHandler {\n+                await speak(reminder)\n         
}\n         } catch {\n             NSLog("FaeScheduler: stale_relationships — 
error: %@", error.localizedDescription)\n@@ -231,7 +405,56 @@ actor FaeScheduler
{\n     }\n \n     private func runSkillHealthCheck() async {\n-        // 
Silent unless issues found — don\'t log every 5min\n+        // Scan skills 
directory for .py files and verify PEP 723 metadata.\n+        let appSupport = 
FileManager.default.urls(\n+            for: .applicationSupportDirectory, in: 
.userDomainMask\n+        ).first\n+        guard let skillsDir = 
appSupport?.appendingPathComponent("fae/skills") else { return }\n+\n+        
let fm = FileManager.default\n+        guard fm.fileExists(atPath: 
skillsDir.path) else { return }\n+\n+        do {\n+            let contents = 
try fm.contentsOfDirectory(\n+                at: skillsDir,\n+                
includingPropertiesForKeys: nil\n+            )\n+            let pyFiles = 
contents.filter { $0.pathExtension == "py" }\n+            guard 
!pyFiles.isEmpty else { return }\n+\n+            var brokenSkills: [String] = 
[]\n+            for file in pyFiles {\n+                let text = try 
String(contentsOf: file, encoding: .utf8)\n+                // Check for PEP 723
inline metadata header.\n+                if !text.contains("# /// script") {\n+
brokenSkills.append(file.lastPathComponent)\n+                }\n+            
}\n+\n+            if !brokenSkills.isEmpty {\n+                NSLog(\n+       
"FaeScheduler: skill_health_check — %d skills missing PEP 723 metadata: %@",\n+ 
brokenSkills.count,\n+                    brokenSkills.joined(separator: ", 
")\n+                )\n+            }\n+\n+            // Check if uv is 
available on PATH.\n+            let uvProcess = Process()\n+            
uvProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")\n+            
uvProcess.arguments = ["uv"]\n+            let pipe = Pipe()\n+            
uvProcess.standardOutput = pipe\n+            uvProcess.standardError = pipe\n+ 
try uvProcess.run()\n+            uvProcess.waitUntilExit()\n+            if 
uvProcess.terminationStatus != 0 {\n+                NSLog("FaeScheduler: 
skill_health_check — uv not found on PATH")\n+            }\n+        } catch 
{\n+            // Silent on errors — this runs every 5 minutes.\n+            
NSLog("FaeScheduler: skill_health_check — error: %@", 
error.localizedDescription)\n+        }\n     }\n \n     // MARK: - Daily 
Schedule Checks\n@@ -251,10 +474,14 @@ actor FaeScheduler {\n         if hour ==
3, minute >= 30, minute < 32 { await runDailyIfNeeded("memory_gc") { await 
runMemoryGC() } }\n         // noise_budget_reset: daily 00:00\n         if hour
== 0, minute < 2 { await runDailyIfNeeded("noise_budget_reset") { await 
runNoiseBudgetReset() } }\n-        // morning_briefing: daily 08:00\n-        
if hour == 8, minute < 2 { await runDailyIfNeeded("morning_briefing") { await 
runMorningBriefing() } }\n-        // skill_proposals: daily 11:00\n-        if 
hour == 11, minute < 2 { await runDailyIfNeeded("skill_proposals") { await 
runSkillProposals() } }\n+        // morning_briefing: configurable hour 
(default 08:00)\n+        if hour == config.morningBriefingHour, minute < 2 {\n+
await runDailyIfNeeded("morning_briefing") { await runMorningBriefing() }\n+    
}\n+        // skill_proposals: configurable hour (default 11:00)\n+        if 
hour == config.skillProposalsHour, minute < 2 {\n+            await 
runDailyIfNeeded("skill_proposals") { await runSkillProposals() }\n+        }\n 
}\n \n     private func runDailyIfNeeded(_ name: String, _ action: () async -> 
Void) async {\n@@ -271,6 +498,10 @@ actor FaeScheduler {\n     /// Trigger a 
named task to run immediately (from FaeCore command or SchedulerTriggerTool).\n 
func triggerTask(id: String) async {\n         NSLog("FaeScheduler: manual 
trigger for \'%@\'", id)\n+        if disabledTaskIDs.contains(id) {\n+         
NSLog("FaeScheduler: task \'%@\' is disabled", id)\n+            return\n+      
}\n         switch id {\n         case "memory_reflect":    await 
runMemoryReflect()\n         case "memory_reindex":    await 
runMemoryReindex()\n@@ -286,6 +517,21 @@ actor FaeScheduler {\n         
default:\n             NSLog("FaeScheduler: unknown task id \'%@\'", id)\n      
}\n+        runHistory[id, default: []].append(Date())\n+\n+        // Persist 
the run to the store\n+        if let store = persistenceStore {\n+            
let record = TaskRunRecord(\n+                taskID: id, idempotencyKey: 
"trigger:\\(id):\\(Int(Date().timeIntervalSince1970))",\n+                state:
.success, attempt: 0,\n+                updatedAt: Date(), lastError: nil\n+    
)\n+            do {\n+                try await store.insertRun(record)\n+     
} catch {\n+                NSLog("FaeScheduler: failed to persist trigger run: 
%@", error.localizedDescription)\n+            }\n+        }\n     }\n \n     
/// Delete a user-created scheduled task (builtin tasks cannot be deleted).\n@@ 
-295,6 +541,82 @@ actor FaeScheduler {\n         NSLog("FaeScheduler: 
deleteUserTask \'%@\' — delegated to SchedulerDeleteTool", id)\n     }\n \n+    
func setTaskEnabled(id: String, enabled: Bool) async {\n+        if enabled {\n+
disabledTaskIDs.remove(id)\n+        } else {\n+            
disabledTaskIDs.insert(id)\n+        }\n+\n+        // Persist to store\n+      
if let store = persistenceStore {\n+            do {\n+                try await
store.setTaskEnabled(id: id, enabled: enabled)\n+            } catch {\n+       
NSLog("FaeScheduler: failed to persist enabled state: %@", 
error.localizedDescription)\n+            }\n+        }\n+    }\n+\n+    func 
isTaskEnabled(id: String) async -> Bool {\n+        
!disabledTaskIDs.contains(id)\n+    }\n+\n+    func status(taskID: String) async
-> [String: Any] {\n+        // Check persistence store for last run time if not
in memory\n+        var lastRunAt: TimeInterval?\n+        if let memoryRun = 
runHistory[taskID]?.last {\n+            lastRunAt = 
memoryRun.timeIntervalSince1970\n+        } else if let store = persistenceStore
{\n+            do {\n+                let history = try await 
store.runHistory(taskID: taskID, limit: 1)\n+                lastRunAt = 
history.first?.timeIntervalSince1970\n+            } catch {\n+                
NSLog("FaeScheduler: failed to query run history: %@", 
error.localizedDescription)\n+            }\n+        }\n+\n+        return [\n+
"id": taskID,\n+            "enabled": !disabledTaskIDs.contains(taskID),\n+    
"last_run_at": lastRunAt as Any,\n+        ]\n+    }\n+\n+    func 
history(taskID: String, limit: Int = 20) async -> [Date] {\n+        // Prefer 
persistence store if available\n+        if let store = persistenceStore {\n+   
do {\n+                return try await store.runHistory(taskID: taskID, limit: 
limit)\n+            } catch {\n+                NSLog("FaeScheduler: failed to 
query history: %@", error.localizedDescription)\n+            }\n+        }\n+  
let runs = runHistory[taskID] ?? []\n+        return Array(runs.suffix(max(1, 
limit)))\n+    }\n+\n+    func statusAll() async -> [[String: Any]] {\n+        
var ids = Set(runHistory.keys).union(disabledTaskIDs)\n+\n+        // Include 
all known task IDs from the builtin list\n+        let builtinIDs = [\n+        
"memory_reflect", "memory_reindex", "memory_migrate",\n+            "memory_gc",
"memory_backup", "check_fae_update",\n+            "morning_briefing", 
"noise_budget_reset", "skill_proposals",\n+            "stale_relationships", 
"skill_health_check",\n+        ]\n+        ids.formUnion(builtinIDs)\n+\n+     
return ids.sorted().map { id in\n+            [\n+                "id": id,\n+  
"enabled": !disabledTaskIDs.contains(id),\n+                "last_run_at": 
runHistory[id]?.last?.timeIntervalSince1970 as Any,\n+            ]\n+        
}\n+    }\n+\n     // MARK: - Timer Helpers\n \n     private func 
scheduleRepeating(\ndiff --git 
a/native/macos/Fae/Sources/Fae/Search/Engines/DuckDuckGoEngine.swift 
b/native/macos/Fae/Sources/Fae/Search/Engines/DuckDuckGoEngine.swift\nindex 
959b62a..56ddf17 100644\n--- 
a/native/macos/Fae/Sources/Fae/Search/Engines/DuckDuckGoEngine.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Search/Engines/DuckDuckGoEngine.swift\n@@ -51,8 
+51,12 @@ struct DuckDuckGoEngine: SearchEngineProtocol {\n             guard 
let range = Range(match.range(at: 1), in: html) else { continue }\n             
let block = String(html[range])\n \n-            // Skip ads.\n-            if 
block.contains("result--ad") { continue }\n+            // Skip ads — check the 
full match (including the opening div tag)\n+            // because result--ad 
is in the class attribute, not the inner content.\n+            if let fullRange
= Range(match.range(at: 0), in: html) {\n+                let fullMatch = 
String(html[fullRange])\n+                if fullMatch.contains("result--ad") { 
continue }\n+            }\n \n             // Extract title and URL from 
result__a link.\n             guard let (title, href) = extractResultLink(from: 
block) else { continue }\ndiff --git 
a/native/macos/Fae/Sources/Fae/Tools/AppleTools.swift 
b/native/macos/Fae/Sources/Fae/Tools/AppleTools.swift\nindex 0f8ccf3..f99bc62 
100644\n--- a/native/macos/Fae/Sources/Fae/Tools/AppleTools.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Tools/AppleTools.swift\n@@ -28,6 +28,8 @@ struct 
CalendarTool: Tool {\n         "end_date": "string ISO8601 (for create)"}\n     
"""\n     var requiresApproval: Bool { false }\n+    var riskLevel: 
ToolRiskLevel { .low }\n+    let example = 
#"<tool_call>{"name":"calendar","arguments":{"action":"list_today"}}</tool_call>
"#\n \n     func execute(input: [String: Any]) async throws -> ToolResult {\n   
let store = EKEventStore()\n@@ -140,6 +142,8 @@ struct RemindersTool: Tool {\n  
"reminder_id": "string (for complete)"}\n         """\n     var 
requiresApproval: Bool { false }\n+    var riskLevel: ToolRiskLevel { .low }\n+ 
let example = 
#"<tool_call>{"name":"reminders","arguments":{"action":"list_incomplete"}}</tool
_call>"#\n \n     func execute(input: [String: Any]) async throws -> ToolResult 
{\n         let store = EKEventStore()\n@@ -238,6 +242,8 @@ struct ContactsTool:
Tool {\n         "query": "string (required)"}\n         """\n     let 
requiresApproval = false\n+    let riskLevel: ToolRiskLevel = .low\n+    let 
example = 
#"<tool_call>{"name":"contacts","arguments":{"action":"search","query":"Sarah"}}
</tool_call>"#\n \n     func execute(input: [String: Any]) async throws -> 
ToolResult {\n         guard CNContactStore.authorizationStatus(for: .contacts) 
== .authorized else {\n@@ -322,6 +328,8 @@ struct MailTool: Tool {\n         
"count": "int (optional, default 5)"}\n         """\n     let requiresApproval =
false\n+    let riskLevel: ToolRiskLevel = .low\n+    let example = 
#"<tool_call>{"name":"mail","arguments":{"action":"check_inbox","count":5}}</too
l_call>"#\n \n     func execute(input: [String: Any]) async throws -> ToolResult
{\n         guard let action = input["action"] as? String else {\n@@ -384,6 
+392,8 @@ struct NotesTool: Tool {\n         "count": "int (optional, default 
5)"}\n         """\n     let requiresApproval = false\n+    let riskLevel: 
ToolRiskLevel = .low\n+    let example = 
#"<tool_call>{"name":"notes","arguments":{"action":"search","query":"meeting 
notes"}}</tool_call>"#\n \n     func execute(input: [String: Any]) async throws 
-> ToolResult {\n         guard let action = input["action"] as? String else 
{\ndiff --git a/native/macos/Fae/Sources/Fae/Tools/BuiltinTools.swift 
b/native/macos/Fae/Sources/Fae/Tools/BuiltinTools.swift\nindex ebb8518..ca1906b 
100644\n--- a/native/macos/Fae/Sources/Fae/Tools/BuiltinTools.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Tools/BuiltinTools.swift\n@@ -7,6 +7,8 @@ struct 
ReadTool: Tool {\n     let description = "Read the contents of a file at the 
given path."\n     let parametersSchema = #"{"path": "string (required)"}"#\n   
let requiresApproval = false\n+    let riskLevel: ToolRiskLevel = .low\n+    let
example = 
#"<tool_call>{"name":"read","arguments":{"path":"~/Documents/notes.txt"}}</tool_
call>"#\n \n     func execute(input: [String: Any]) async throws -> ToolResult 
{\n         guard let path = input["path"] as? String else {\n@@ -35,6 +37,8 @@ 
struct WriteTool: Tool {\n     let description = "Write content to a file at the
given path."\n     let parametersSchema = #"{"path": "string (required)", 
"content": "string (required)"}"#\n     let requiresApproval = true\n+    let 
riskLevel: ToolRiskLevel = .high\n+    let example = 
#"<tool_call>{"name":"write","arguments":{"path":"~/notes.txt","content":"Hello 
world"}}</tool_call>"#\n \n     func execute(input: [String: Any]) async throws 
-> ToolResult {\n         guard let path = input["path"] as? String,\n@@ -63,6 
+67,8 @@ struct EditTool: Tool {\n     let description = "Replace a string in a 
file. The old_string must match exactly."\n     let parametersSchema = 
#"{"path": "string", "old_string": "string", "new_string": "string"}"#\n     let
requiresApproval = true\n+    let riskLevel: ToolRiskLevel = .high\n+    let 
example = 
#"<tool_call>{"name":"edit","arguments":{"path":"~/config.toml","old_string":"ti
meout = 30","new_string":"timeout = 60"}}</tool_call>"#\n \n     func 
execute(input: [String: Any]) async throws -> ToolResult {\n         guard let 
path = input["path"] as? String,\n@@ -93,6 +99,8 @@ struct BashTool: Tool {\n   
let description = "Execute a shell command and return its output."\n     let 
parametersSchema = #"{"command": "string (required)"}"#\n     let 
requiresApproval = true\n+    let riskLevel: ToolRiskLevel = .high\n+    let 
example = #"<tool_call>{"name":"bash","arguments":{"command":"ls -la 
~/Documents"}}</tool_call>"#\n \n     func execute(input: [String: Any]) async 
throws -> ToolResult {\n         guard let command = input["command"] as? String
else {\n@@ -154,6 +162,7 @@ struct SelfConfigTool: Tool {\n         {"action": 
"string (required: 
get_instructions|set_instructions|append_instructions|clear_instructions)", 
"value": "string (required for set/append)"}\n         """#\n     let 
requiresApproval = false\n+    let example = 
#"<tool_call>{"name":"self_config","arguments":{"action":"append_instructions","
value":"Be more concise"}}</tool_call>"#\n \n     private static var filePath: 
URL {\n         let appSupport = FileManager.default.urls(\n@@ -227,10 +236,78 
@@ struct WebSearchTool: Tool {\n     let description = "Search the web using 
multiple engines (DuckDuckGo, Brave, Google, Bing). Results are deduplicated and
ranked across engines for quality."\n     let parametersSchema = #"{"query": 
"string (required)", "max_results": "integer (optional, default 10)"}"#\n     
let requiresApproval = false\n+    let example = 
#"<tool_call>{"name":"web_search","arguments":{"query":"latest Swift concurrency
features"}}</tool_call>"#\n \n     private static let maxOutputChars = 100_000\n
private static let orchestrator = SearchOrchestrator()\n \n+    /// Categorize a
URL\'s domain for quality indication.\n+    private static func 
domainCategory(for urlString: String) -> String {\n+        guard let url = 
URL(string: urlString),\n+              let host = url.host?.lowercased()\n+    
else { return "" }\n+\n+        // Strip www. prefix for matching.\n+        let
domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host\n+\n+        
// News domains.\n+        let newsDomains: Set<String> = [\n+            
"reuters.com", "apnews.com", "bbc.com", "bbc.co.uk", "nytimes.com",\n+          
"theguardian.com", "washingtonpost.com", "cnn.com", "npr.org",\n+            
"arstechnica.com", "theverge.com", "techcrunch.com", "wired.com",\n+            
"bloomberg.com", "ft.com", "economist.com", "9to5mac.com",\n+            
"macrumors.com", "engadget.com",\n+        ]\n+        if 
newsDomains.contains(domain) { return "[News]" }\n+\n+        // Reference / 
documentation.\n+        let refDomains: Set<String> = [\n+            
"wikipedia.org", "en.wikipedia.org", "developer.apple.com",\n+            
"docs.swift.org", "docs.python.org", "docs.rs", "doc.rust-lang.org",\n+         
"developer.mozilla.org", "w3.org", "rfc-editor.org",\n+        ]\n+        if 
refDomains.contains(domain) { return "[Reference]" }\n+\n+        // Code / 
developer.\n+        let codeDomains: Set<String> = [\n+            
"github.com", "gitlab.com", "bitbucket.org", "stackoverflow.com",\n+            
"stackexchange.com", "npmjs.com", "pypi.org", "crates.io",\n+            
"pkg.go.dev", "swiftpackageindex.com", "cocoapods.org",\n+        ]\n+        if
codeDomains.contains(domain) { return "[Code]" }\n+\n+        // Forums / 
community.\n+        let forumDomains: Set<String> = [\n+            
"reddit.com", "old.reddit.com", "news.ycombinator.com",\n+            
"lobste.rs", "discourse.org", "forums.swift.org",\n+            
"discuss.python.org", "quora.com",\n+        ]\n+        if 
forumDomains.contains(domain) { return "[Forum]" }\n+\n+        // Academic.\n+ 
let academicDomains: Set<String> = [\n+            "arxiv.org", 
"scholar.google.com", "ieee.org", "acm.org",\n+            "nature.com", 
"science.org", "pnas.org", "researchgate.net",\n+        ]\n+        if 
academicDomains.contains(domain) { return "[Academic]" }\n+\n+        // Social 
media.\n+        let socialDomains: Set<String> = [\n+            "twitter.com",
"x.com", "mastodon.social", "linkedin.com",\n+            "facebook.com", 
"youtube.com", "medium.com", "substack.com",\n+        ]\n+        if 
socialDomains.contains(domain) { return "[Social]" }\n+\n+        return ""\n+  
}\n+\n+    /// Extract the display domain from a URL string.\n+    private 
static func displayDomain(for urlString: String) -> String {\n+        guard let
url = URL(string: urlString), let host = url.host else { return "" }\n+        
let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host\n+       
return domain\n+    }\n+\n     func execute(input: [String: Any]) async throws 
-> ToolResult {\n         guard let query = input["query"] as? String, 
!query.trimmingCharacters(in: .whitespaces).isEmpty else {\n             return 
.error("Missing required parameter: query")\n@@ -248,7 +325,10 @@ struct 
WebSearchTool: Tool {\n \n             var output = "## Search Results for 
\\"\\(query)\\"\\n\\n"\n             for (i, result) in results.enumerated() 
{\n-                output += "\\(i + 1). **\\(result.title)**\\n   URL: 
\\(result.url)\\n   \\(result.snippet)\\n\\n"\n+                let category = 
Self.domainCategory(for: result.url)\n+                let domain = 
Self.displayDomain(for: result.url)\n+                let tag = category.isEmpty
? domain : "\\(category) \\(domain)"\n+                output += "\\(i + 1). 
**\\(result.title)** (\\(tag))\\n   URL: \\(result.url)\\n   
\\(result.snippet)\\n\\n"\n             }\n \n             if output.count > 
Self.maxOutputChars {\n@@ -272,6 +352,7 @@ struct FetchURLTool: Tool {\n     let
description = "Fetch a web page and extract its readable text content."\n     
let parametersSchema = #"{"url": "string (required, must start with http:// or 
https://)"}"#\n     let requiresApproval = false\n+    let example = 
#"<tool_call>{"name":"fetch_url","arguments":{"url":"https://example.com/article
"}}</tool_call>"#\n \n     private static let orchestrator = 
SearchOrchestrator()\n \ndiff --git 
a/native/macos/Fae/Sources/Fae/Tools/RoleplayTool.swift 
b/native/macos/Fae/Sources/Fae/Tools/RoleplayTool.swift\nindex 8703408..edb66e1 
100644\n--- a/native/macos/Fae/Sources/Fae/Tools/RoleplayTool.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Tools/RoleplayTool.swift\n@@ -1,6 +1,10 @@\n 
import Foundation\n \n /// Manages roleplay session state: active flag, title, 
and character-to-voice mappings.\n+///\n+/// Voice assignments are persisted to 
`roleplay_voices.json` keyed by session\n+/// title so that resuming a session 
with the same title restores previously\n+/// assigned character voices.\n actor
RoleplaySessionStore {\n     static let shared = RoleplaySessionStore()\n \n@@ 
-8,19 +12,34 @@ actor RoleplaySessionStore {\n     private(set) var title: 
String?\n     private(set) var characterVoices: [String: String] = [:]\n \n-    
/// Start a new roleplay session, clearing any previous state.\n+    private let
persistence = RoleplayVoicePersistence()\n+\n+    /// Start a new roleplay 
session.\n+    ///\n+    /// If a session with the same title was previously 
used, saved voice\n+    /// assignments are automatically restored.\n     func 
start(title: String?) -> String {\n         self.isActive = true\n         
self.title = title\n-        self.characterVoices = [:]\n+        // Restore 
saved voices for this title (if any).\n+        if let title {\n+            
self.characterVoices = persistence.load(forTitle: title)\n+        } else {\n+  
self.characterVoices = [:]\n+        }\n         let label = title ?? 
"untitled"\n-        return "Roleplay session started: \\(label). Assign 
character voices with assign_voice."\n+        let restoredNote = 
characterVoices.isEmpty ? "" : " Restored \\(characterVoices.count) saved 
voice(s)."\n+        return "Roleplay session started: \\(label). Assign 
character voices with assign_voice.\\(restoredNote)"\n     }\n \n     /// Assign
a voice description to a character name.\n     func assignVoice(character: 
String, description: String) -> String {\n         let key = 
character.lowercased()\n         characterVoices[key] = description\n+        //
Persist updated voice assignments.\n+        if let title {\n+            
persistence.save(voices: characterVoices, forTitle: title)\n+        }\n        
return "Voice assigned: \\(character) → \\(description)"\n     }\n \n@@ -48,6 
+67,90 @@ actor RoleplaySessionStore {\n     }\n }\n \n+// MARK: - Voice 
Persistence\n+\n+/// Handles reading and writing roleplay voice assignments to 
disk.\n+///\n+/// Voice assignments are stored in a JSON file at:\n+/// 
`~/Library/Application Support/fae/roleplay_voices.json`\n+///\n+/// 
Structure:\n+/// ```json\n+/// {\n+///   "Session Title": {\n+///     "hamlet": 
"deep male voice, brooding, Shakespearean",\n+///     "narrator": "calm, 
measured, storytelling"\n+///   }\n+/// }\n+/// ```\n+private struct 
RoleplayVoicePersistence {\n+\n+    private var fileURL: URL? {\n+        guard 
let appSupport = FileManager.default.urls(\n+            for: 
.applicationSupportDirectory,\n+            in: .userDomainMask\n+        
).first else {\n+            return nil\n+        }\n+        return 
appSupport\n+            .appendingPathComponent("fae")\n+            
.appendingPathComponent("roleplay_voices.json")\n+    }\n+\n+    /// Load saved 
voice assignments for a given session title.\n+    ///\n+    /// Returns an 
empty dictionary if no saved data exists or the file is corrupt.\n+    func 
load(forTitle title: String) -> [String: String] {\n+        guard let url = 
fileURL else { return [:] }\n+\n+        do {\n+            let data = try 
Data(contentsOf: url)\n+            let all = try JSONDecoder().decode([String: 
[String: String]].self, from: data)\n+            return all[title] ?? [:]\n+   
} catch {\n+            // Missing file or corrupt data — start fresh (don\'t 
log missing file).\n+            if !((error as NSError).domain == 
NSCocoaErrorDomain\n+                && (error as NSError).code == 
NSFileReadNoSuchFileError)\n+            {\n+                
NSLog("RoleplayVoicePersistence: load error: %@", error.localizedDescription)\n+
}\n+            return [:]\n+        }\n+    }\n+\n+    /// Save voice 
assignments for a given session title.\n+    ///\n+    /// Merges with existing 
sessions on disk so other sessions are preserved.\n+    func save(voices: 
[String: String], forTitle title: String) {\n+        guard let url = fileURL 
else { return }\n+\n+        // Load existing sessions first.\n+        var all:
[String: [String: String]] = [:]\n+        if let data = try? Data(contentsOf: 
url),\n+           let decoded = try? JSONDecoder().decode([String: [String: 
String]].self, from: data)\n+        {\n+            all = decoded\n+        
}\n+\n+        // Update this session.\n+        all[title] = voices\n+\n+      
// Ensure directory exists.\n+        do {\n+            try 
FileManager.default.createDirectory(\n+                at: 
url.deletingLastPathComponent(),\n+                withIntermediateDirectories: 
true\n+            )\n+            let encoder = JSONEncoder()\n+            
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]\n+            let data 
= try encoder.encode(all)\n+            try data.write(to: url, options: 
.atomic)\n+        } catch {\n+            NSLog("RoleplayVoicePersistence: save
error: %@", error.localizedDescription)\n+        }\n+    }\n+}\n+\n // MARK: - 
Roleplay Tool\n \n /// Tool for managing multi-voice roleplay reading 
sessions.\n@@ -70,6 +173,7 @@ struct RoleplayTool: Tool {\n         
"voice_description": "string (required for assign_voice, under 50 words: gender,
age, accent, style)"}\n         """\n     let requiresApproval = false\n+    let
example = 
#"<tool_call>{"name":"roleplay","arguments":{"action":"start","title":"Hamlet 
Act 3"}}</tool_call>"#\n \n     func execute(input: [String: Any]) async throws 
-> ToolResult {\n         guard let action = input["action"] as? String else 
{\ndiff --git a/native/macos/Fae/Sources/Fae/Tools/SchedulerTools.swift 
b/native/macos/Fae/Sources/Fae/Tools/SchedulerTools.swift\nindex 
0a0d12c..6b191f3 100644\n--- 
a/native/macos/Fae/Sources/Fae/Tools/SchedulerTools.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Tools/SchedulerTools.swift\n@@ -68,6 +68,8 @@ 
struct SchedulerListTool: Tool {\n     let description = "List all scheduled 
tasks with their schedule and status."\n     let parametersSchema = #"{}"#\n    
let requiresApproval = false\n+    let riskLevel: ToolRiskLevel = .low\n+    let
example = #"<tool_call>{"name":"scheduler_list","arguments":{}}</tool_call>"#\n 
\n     func execute(input: [String: Any]) async throws -> ToolResult {\n        
let tasks = readSchedulerTasks()\n@@ -111,6 +113,8 @@ struct 
SchedulerCreateTool: Tool {\n         "action": "string (required: description 
of what to do)"}\n         """\n     let requiresApproval = true\n+    let 
riskLevel: ToolRiskLevel = .high\n+    let example = 
#"<tool_call>{"name":"scheduler_create","arguments":{"name":"Weather 
Check","schedule_type":"daily","schedule_params":{"hour":"7","minute":"0"},"acti
on":"Check weather forecast"}}</tool_call>"#\n \n     func execute(input: 
[String: Any]) async throws -> ToolResult {\n         guard let taskName = 
input["name"] as? String, !taskName.isEmpty else {\n@@ -160,6 +164,8 @@ struct 
SchedulerUpdateTool: Tool {\n         "schedule_params": "object (optional)"}\n 
"""\n     let requiresApproval = true\n+    let riskLevel: ToolRiskLevel = 
.high\n+    let example = 
#"<tool_call>{"name":"scheduler_update","arguments":{"id":"morning_briefing","en
abled":false}}</tool_call>"#\n \n     func execute(input: [String: Any]) async 
throws -> ToolResult {\n         guard let taskId = input["id"] as? String else 
{\n@@ -173,6 +179,15 @@ struct SchedulerUpdateTool: Tool {\n \n         if let 
enabled = input["enabled"] as? Bool {\n             tasks[index].enabled = 
enabled\n+\n+            // Route enabled/disabled state change through 
FaeScheduler (single source of truth).\n+            await MainActor.run {\n+   
NotificationCenter.default.post(\n+                    name: 
.faeSchedulerUpdate,\n+                    object: nil,\n+                    
userInfo: ["id": taskId, "enabled": enabled]\n+                )\n+            
}\n         }\n         if let scheduleType = input["schedule_type"] as? String 
{\n             tasks[index].scheduleType = scheduleType\n@@ -197,6 +212,8 @@ 
struct SchedulerDeleteTool: Tool {\n     let description = "Delete a 
user-created scheduled task. Cannot delete builtin tasks."\n     let 
parametersSchema = #"{"id": "string (required)"}"#\n     let requiresApproval = 
true\n+    let riskLevel: ToolRiskLevel = .high\n+    let example = 
#"<tool_call>{"name":"scheduler_delete","arguments":{"id":"user_abc12345"}}</too
l_call>"#\n \n     func execute(input: [String: Any]) async throws -> ToolResult
{\n         guard let taskId = input["id"] as? String else {\n@@ -231,6 +248,8 
@@ struct SchedulerTriggerTool: Tool {\n     let description = "Trigger a 
scheduled task to run immediately."\n     let parametersSchema = #"{"id": 
"string (required)"}"#\n     let requiresApproval = false\n+    let riskLevel: 
ToolRiskLevel = .low\n+    let example = 
#"<tool_call>{"name":"scheduler_trigger","arguments":{"id":"morning_briefing"}}<
/tool_call>"#\n \n     func execute(input: [String: Any]) async throws -> 
ToolResult {\n         guard let taskId = input["id"] as? String else {\n@@ 
-257,4 +276,5 @@ struct SchedulerTriggerTool: Tool {\n \n extension 
Notification.Name {\n     static let faeSchedulerTrigger = 
Notification.Name("faeSchedulerTrigger")\n+    static let faeSchedulerUpdate = 
Notification.Name("faeSchedulerUpdate")\n }\ndiff --git 
a/native/macos/Fae/Sources/Fae/Tools/Tool.swift 
b/native/macos/Fae/Sources/Fae/Tools/Tool.swift\nindex afb0e19..8d1f5e2 
100644\n--- a/native/macos/Fae/Sources/Fae/Tools/Tool.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Tools/Tool.swift\n@@ -27,9 +27,14 @@ protocol 
Tool: Sendable {\n     var description: String { get }\n     var 
parametersSchema: String { get }\n     var requiresApproval: Bool { get }\n+    
var riskLevel: ToolRiskLevel { get }\n+    /// A concrete `<tool_call>` example 
for the LLM to follow.\n+    var example: String { get }\n     func 
execute(input: [String: Any]) async throws -> ToolResult\n }\n \n extension Tool
{\n     var requiresApproval: Bool { false }\n+    var riskLevel: ToolRiskLevel 
{ .medium }\n+    var example: String { "" }\n }\ndiff --git 
a/native/macos/Fae/Sources/Fae/Tools/ToolRegistry.swift 
b/native/macos/Fae/Sources/Fae/Tools/ToolRegistry.swift\nindex a773e53..d7ac612 
100644\n--- a/native/macos/Fae/Sources/Fae/Tools/ToolRegistry.swift\n+++ 
b/native/macos/Fae/Sources/Fae/Tools/ToolRegistry.swift\n@@ -60,11 +60,17 @@ 
final class ToolRegistry: Sendable {\n         Array(tools.keys).sorted()\n     
}\n \n-    /// JSON schema descriptions for all registered tools.\n+    /// JSON
schema descriptions for all registered tools, with examples when available.\n   
var toolSchemas: String {\n         tools.values\n             .sorted { $0.name
< $1.name }\n-            .map { "## 
\\($0.name)\\n\\($0.description)\\nParameters: \\($0.parametersSchema)" }\n+    
.map { tool in\n+                var schema = "## 
\\(tool.name)\\n\\(tool.description)\\nRisk: 
\\(tool.riskLevel.rawValue)\\nParameters: \\(tool.parametersSchema)"\n+         
if !tool.example.isEmpty {\n+                    schema += "\\nExample: 
\\(tool.example)"\n+                }\n+                return schema\n+        
}\n             .joined(separator: "\\n\\n")\n     }\n }'
)
StepBegin(n=1)
ThinkPart(
    type='think',
    think="Looking at this Swift macOS codebase diff, I need to analyze it for 
security issues, error handling problems, code quality, architectural concerns, 
and memory safety issues.\n\nLet me go through the changes systematically:\n\n1.
**FaeConfig.swift** - Adding scheduler config and new model preset\n2. 
**FaeCore.swift** - Adding scheduler persistence and notification 
observation\n3. **MLProtocols.swift** - Default TTS implementation\n4. 
**PersonalityManager.swift** - Adding date/time to prompt\n5. 
**CoreMLSpeakerEncoder.swift** - Liveness detection\n6. 
**SpeakerProfileStore.swift** - Embedding timestamps and pruning\n7. 
**MemoryOrchestrator.swift** - Stale record filtering, contradiction 
detection\n8. **MemoryTypes.swift** - Schema version bump, importance 
scoring\n9. **SQLiteMemoryStore.swift** - FTS5 indexing, embedding caching\n10. 
**PipelineCoordinator.swift** - Tool risk policy, analytics, voice identity\n11.
**FaeScheduler.swift** - Major scheduler enhancements, persistence\n12. 
**DuckDuckGoEngine.swift** - Ad filtering fix\n13. **AppleTools.swift** - Risk 
levels and examples\n14. **BuiltinTools.swift** - Risk levels, examples, search 
categorization\n15. **RoleplayTool.swift** - Voice persistence\n16. 
**SchedulerTools.swift** - Risk levels, examples, notifications\n17. 
**Tool.swift** - Risk level and example properties\n18. **ToolRegistry.swift** -
Schema formatting\n\nLet me analyze each file for issues:\n\n### Security 
Issues\n\n1. **FaeCore.swift:410-416** - File path construction uses `.first!` 
which could crash\n\n\n2. **FaeScheduler.swift:431-444** - Running a process 
with `/usr/bin/which` and checking `uv` on PATH. The process execution and error
handling look mostly okay, but I should verify the path handling is safe.\n\n3. 
**SQLiteMemoryStore.swift:220-230** - The migration section uses `try 
Row.fetchAll` and checks for column existence. The force unwrap patterns here 
need closer inspection to ensure they're not introducing crashes.\n\n4. 
**MemoryTypes.swift:147-152** - The exponential decay calculation uses a switch 
statement with a default case, which appears to be exhaustive over the enum 
variants, so this should be fine.\n\n5. **CoreMLSpeakerEncoder.swift:75-82** - 
Array bounds checking on mel spectrogram operations. The indexing logic needs 
verification to ensure it doesn't go out of bounds, particularly around the 
frame calculations and energy accumulation loops.\n\n. The vDSP operations also 
need careful review to confirm the strides and counts are correct.\n\n6. 
**SpeakerProfileStore.swift:31-37** - The array operations during enrollment 
need bounds checking. When appending embeddings and dates, the code should 
ensure the arrays stay in sync and don't grow beyond expected limits.\n\n7. 
**MemoryOrchestrator.swift:246-257** - The reranking logic with cached 
embeddings needs validation. The cosine similarity calculation and comparison 
thresholds should be verified to ensure the semantic matching works as 
intended.\n\n8. **FaeScheduler.swift:458-467** - The task scheduling window 
logic appears sound, but the time interval calculations and date comparisons 
need to be checked for edge cases like midnight boundaries.\n\n9. 
**SQLiteMemoryStore.swift:389-397** - The embedding serialization and 
deserialization from BLOB data needs careful review. The unsafe pointer 
operations and data buffer handling must be validated to prevent memory 
corruption or incorrect byte ordering.\n\n10. 
**PipelineCoordinator.swift:938-953** - The tool risk policy evaluation and 
voice decision routing logic should be examined. The switch statement handling 
different risk levels and the fallback behavior when no approval manager is 
present need verification.\n\n11. **PersonalityManager.swift:278-280** - The 
date formatter locale and formatting string look correct, but should be verified
for thread safety since DateFormatter instances aren't inherently 
thread-safe.\n\n12. **FaeScheduler.swift:600-610** - The notification 
observation setup and the Task scheduling for scheduler updates need to be 
checked for potential retain cycles or thread safety issues when accessing the 
scheduler actor.\n\n13. **RoleplayTool.swift:115-123** - The JSON persistence 
logic and error handling for file operations should be reviewed. The atomic 
write options and directory creation are good practices, but the overall 
approach to data persistence needs validation.\n\n14. 
**PipelineCoordinator.swift:575-585** - The roleplay voice assignment logic and 
the async/await patterns used to fetch character voices need to be examined for 
potential race conditions or blocking issues.",
    encrypted=None
)
TextPart(
    type='text',
    text="I'll analyze this Swift macOS codebase diff for security, error 
handling, code quality, architectural, and memory safety issues."
)
ToolCall(
    type='function',
    id='tool_yOUGcB3o5yoJ90flylVpVXRW',
    function=FunctionBody(
        name='ReadFile',
        arguments='{"path": 
"/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Core
/FaeCore.swift", "line_offset": 400, "n_lines": 50}'
    ),
    extras=None
)
ToolCall(
    type='function',
    id='tool_4PQNblOi0uC3DznYJHJVfyVm',
    function=FunctionBody(name='ReadFile', arguments='{"path": "/Users'),
    extras=None
)
ToolResult(
    tool_call_id='tool_yOUGcB3o5yoJ90flylVpVXRW',
    return_value=ToolOk(
        is_error=False,
        output='   400\t        }\n   401\t    }\n   402\t\n   403\t    /// 
Memory database path: ~/Library/Application Support/fae/fae.db\n   404\t    
private static func createMemoryStore() throws -> SQLiteMemoryStore {\n   405\t 
let appSupport = FileManager.default.urls(\n   406\t            for: 
.applicationSupportDirectory, in: .userDomainMask\n   407\t        ).first!\n   
408\t        let faeDir = appSupport.appendingPathComponent("fae")\n   409\t    
let dbPath = faeDir.appendingPathComponent("fae.db").path\n   410\t        
return try SQLiteMemoryStore(path: dbPath)\n   411\t    }\n   412\t\n   413\t   
/// Scheduler persistence database path.\n   414\t    private static func 
createSchedulerPersistenceStore() throws -> SchedulerPersistenceStore {\n   
415\t        let appSupport = FileManager.default.urls(\n   416\t            
for: .applicationSupportDirectory, in: .userDomainMask\n   417\t        
).first!\n   418\t        let faeDir = 
appSupport.appendingPathComponent("fae")\n   419\t        let dbPath = 
faeDir.appendingPathComponent("scheduler.db").path\n   420\t        return try 
SchedulerPersistenceStore(path: dbPath)\n   421\t    }\n   422\t\n   423\t    
/// Observe scheduler update notifications from SchedulerUpdateTool.\n   424\t  
private func observeSchedulerUpdates() {\n   425\t        
NotificationCenter.default.addObserver(\n   426\t            forName: 
.faeSchedulerUpdate,\n   427\t            object: nil,\n   428\t            
queue: .main\n   429\t        ) { [weak self] notification in\n   430\t         
guard let self,\n   431\t                  let userInfo = 
notification.userInfo,\n   432\t                  let taskId = userInfo["id"] 
as? String,\n   433\t                  let enabled = userInfo["enabled"] as? 
Bool\n   434\t            else { return }\n   435\t            Task { await 
self.scheduler?.setTaskEnabled(id: taskId, enabled: enabled) }\n   436\t        
}\n   437\t    }\n   438\t\n   439\t    private func configGetResponse(key: 
String) -> [String: Any] {\n   440\t        switch key {\n   441\t        case 
"voice_identity":\n   442\t            return [\n   443\t                
"payload": [\n   444\t                    "voice_identity": [\n   445\t         
"enabled": false,\n   446\t                        "mode": "assist",\n   447\t  
"approval_requires_match": true,\n   448\t                    ] as [String: 
Any],\n   449\t                ] as [String: Any],\n',
        message='50 lines read from file starting from line 400.',
        display=[],
        extras=None
    )
)
ToolCallPart(
    arguments_part='/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sou
rces/Fae/Scheduler/FaeScheduler.swift", "line_offset": 420, "n_lines": 50}'
)
ToolCall(
    type='function',
    id='tool_usHX7zlT83lSPJghHLjtBfyc',
    function=FunctionBody(name='ReadFile', arguments='{"path": "/Users/david'),
    extras=None
)
ToolResult(
    tool_call_id='tool_4PQNblOi0uC3DznYJHJVfyVm',
    return_value=ToolOk(
        is_error=False,
        output='   420\t                includingPropertiesForKeys: nil\n   
421\t            )\n   422\t            let pyFiles = contents.filter { 
$0.pathExtension == "py" }\n   423\t            guard !pyFiles.isEmpty else { 
return }\n   424\t\n   425\t            var brokenSkills: [String] = []\n   
426\t            for file in pyFiles {\n   427\t                let text = try 
String(contentsOf: file, encoding: .utf8)\n   428\t                // Check for 
PEP 723 inline metadata header.\n   429\t                if !text.contains("# 
/// script") {\n   430\t                    
brokenSkills.append(file.lastPathComponent)\n   431\t                }\n   432\t
}\n   433\t\n   434\t            if !brokenSkills.isEmpty {\n   435\t           
NSLog(\n   436\t                    "FaeScheduler: skill_health_check — %d 
skills missing PEP 723 metadata: %@",\n   437\t                    
brokenSkills.count,\n   438\t                    brokenSkills.joined(separator: 
", ")\n   439\t                )\n   440\t            }\n   441\t\n   442\t     
// Check if uv is available on PATH.\n   443\t            let uvProcess = 
Process()\n   444\t            uvProcess.executableURL = URL(fileURLWithPath: 
"/usr/bin/which")\n   445\t            uvProcess.arguments = ["uv"]\n   446\t   
let pipe = Pipe()\n   447\t            uvProcess.standardOutput = pipe\n   448\t
uvProcess.standardError = pipe\n   449\t            try uvProcess.run()\n   
450\t            uvProcess.waitUntilExit()\n   451\t            if 
uvProcess.terminationStatus != 0 {\n   452\t                NSLog("FaeScheduler:
skill_health_check — uv not found on PATH")\n   453\t            }\n   454\t    
} catch {\n   455\t            // Silent on errors — this runs every 5 
minutes.\n   456\t            NSLog("FaeScheduler: skill_health_check — error: 
%@", error.localizedDescription)\n   457\t        }\n   458\t    }\n   459\t\n  
460\t    // MARK: - Daily Schedule Checks\n   461\t\n   462\t    /// Track which
daily tasks have fired today.\n   463\t    private var lastDailyRun: [String: 
Date] = [:]\n   464\t\n   465\t    private func runDailyChecks() async {\n   
466\t        let cal = Calendar.current\n   467\t        let now = Date()\n   
468\t        let hour = cal.component(.hour, from: now)\n   469\t        let 
minute = cal.component(.minute, from: now)\n',
        message='50 lines read from file starting from line 420.',
        display=[],
        extras=None
    )
)
ToolCallPart(
    arguments_part='irvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/F
ae/Memory/SQLiteMemoryStore.swift", "line_offset": 380, "n_lines": 30}'
)
StatusUpdate(
    context_usage=0.11788177490234375,
    token_usage=TokenUsage(
        input_other=26038,
        output=1162,
        input_cache_read=4864,
        input_cache_creation=0
    ),
    message_id='chatcmpl-2r6YBOF3pLEbbwVRFntoRVxM'
)
ToolResult(
    tool_call_id='tool_usHX7zlT83lSPJghHLjtBfyc',
    return_value=ToolOk(
        is_error=False,
        output='   380\t            )\n   381\t            return rows.map { 
Self.recordFromRow($0) }\n   382\t        }\n   383\t    }\n   384\t\n   385\t  
// MARK: - Retention\n   386\t\n   387\t    func 
applyRetentionPolicy(retentionDays: UInt64) throws -> Int {\n   388\t        
guard retentionDays > 0 else { return 0 }\n   389\t        let cutoff = 
UInt64(Date().timeIntervalSince1970) - (retentionDays * 86_400)\n   390\t\n   
391\t        return try dbQueue.write { db in\n   392\t            try 
db.execute(\n   393\t                sql: """\n   394\t                    
UPDATE memory_records SET status = \'forgotten\'\n   395\t                    
WHERE kind = \'episode\' AND status = \'active\' AND updated_at < ?\n   396\t   
""",\n   397\t                arguments: [cutoff]\n   398\t            )\n   
399\t            return db.changesCount\n   400\t        }\n   401\t    }\n   
402\t\n   403\t    // MARK: - Record Count\n   404\t\n   405\t    func 
recordCount() throws -> Int {\n   406\t        try dbQueue.read { db in\n   
407\t            let row = try Row.fetchOne(\n   408\t                db,\n   
409\t                sql: "SELECT COUNT(*) FROM memory_records WHERE status = 
\'active\'"\n',
        message='30 lines read from file starting from line 380.',
        display=[],
        extras=None
    )
)
StepBegin(n=2)
ThinkPart(
    type='think',
    think='Let me continue reading more context for a complete analysis.',
    encrypted=None
)
ToolCall(
    type='function',
    id='tool_ARYg9fn7OsiVtiRuE0uyNVfJ',
    function=FunctionBody(
        name='ReadFile',
        arguments='{"path": 
"/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Memo
ry/SQLiteMemoryStore.swift", "line_offset": 50, "n_lines": 50}'
    ),
    extras=None
)
ToolCall(
    type='function',
    id='tool_R1SMH9zDXzTjkWQyJtoykhVT',
    function=FunctionBody(name='ReadFile', arguments='{"path": "/Users/david'),
    extras=None
)
ToolResult(
    tool_call_id='tool_ARYg9fn7OsiVtiRuE0uyNVfJ',
    return_value=ToolOk(
        is_error=False,
        output='    50\t                tags             TEXT NOT NULL DEFAULT 
\'[]\',\n    51\t                supersedes       TEXT,\n    52\t               
created_at       INTEGER NOT NULL DEFAULT 0,\n    53\t                updated_at
INTEGER NOT NULL DEFAULT 0,\n    54\t                importance_score REAL,\n   
55\t                stale_after_secs INTEGER,\n    56\t                metadata 
TEXT,\n    57\t                embedding        BLOB\n    58\t            )\n   
59\t            """)\n    60\t\n    61\t        // Migration: add embedding 
column if missing (v3 → v4).\n    62\t        let columns = try Row.fetchAll(db,
sql: "PRAGMA table_info(memory_records)")\n    63\t        let columnNames = 
Set(columns.map { $0["name"] as String })\n    64\t        if 
!columnNames.contains("embedding") {\n    65\t            try db.execute(sql: 
"ALTER TABLE memory_records ADD COLUMN embedding BLOB")\n    66\t        }\n    
67\t\n    68\t        // FTS5 full-text index for fast candidate selection.\n   
69\t        try db.execute(sql: """\n    70\t            CREATE VIRTUAL TABLE IF
NOT EXISTS memory_fts USING fts5(\n    71\t                text, 
content=\'memory_records\', content_rowid=\'rowid\'\n    72\t            )\n    
73\t            """)\n    74\t\n    75\t        // Triggers to keep FTS in 
sync.\n    76\t        try db.execute(sql: """\n    77\t            CREATE 
TRIGGER IF NOT EXISTS memory_fts_insert AFTER INSERT ON memory_records BEGIN\n  
78\t                INSERT INTO memory_fts(rowid, text) VALUES (new.rowid, 
new.text);\n    79\t            END\n    80\t            """)\n    81\t        
try db.execute(sql: """\n    82\t            CREATE TRIGGER IF NOT EXISTS 
memory_fts_delete AFTER DELETE ON memory_records BEGIN\n    83\t                
INSERT INTO memory_fts(memory_fts, rowid, text) VALUES(\'delete\', old.rowid, 
old.text);\n    84\t            END\n    85\t            """)\n    86\t        
try db.execute(sql: """\n    87\t            CREATE TRIGGER IF NOT EXISTS 
memory_fts_update AFTER UPDATE OF text ON memory_records BEGIN\n    88\t        
INSERT INTO memory_fts(memory_fts, rowid, text) VALUES(\'delete\', old.rowid, 
old.text);\n    89\t                INSERT INTO memory_fts(rowid, text) VALUES 
(new.rowid, new.text);\n    90\t            END\n    91\t            """)\n    
92\t        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_records_status 
ON memory_records(status)")\n    93\t        try db.execute(sql: "CREATE INDEX 
IF NOT EXISTS idx_records_kind ON memory_records(kind)")\n    94\t        try 
db.execute(\n    95\t            sql: "CREATE INDEX IF NOT EXISTS 
idx_records_updated_at ON memory_records(updated_at)"\n    96\t        )\n    
97\t\n    98\t        try db.execute(sql: """\n    99\t            CREATE TABLE 
IF NOT EXISTS memory_audit (\n',
        message='50 lines read from file starting from line 50.',
        display=[],
        extras=None
    )
)
ToolCallPart(
    arguments_part='irvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/F
ae/Pipeline/PipelineCoordinator.swift", "line_offset": 930, "n_lines": 80}'
)
StatusUpdate(
    context_usage=0.12807464599609375,
    token_usage=TokenUsage(
        input_other=2854,
        output=127,
        input_cache_read=30720,
        input_cache_creation=0
    ),
    message_id='chatcmpl-f2UklMPaIx7frGtHFgZt53LS'
)
ToolResult(
    tool_call_id='tool_R1SMH9zDXzTjkWQyJtoykhVT',
    return_value=ToolOk(
        is_error=False,
        output='   930\t    }\n   931\t\n   932\t    // MARK: - Tool Execution\n
933\t\n   934\t    private static let toolTimeoutSeconds: TimeInterval = 30\n   
935\t\n   936\t    private func executeTool(_ call: ToolCall) async -> 
ToolResult {\n   937\t        guard let tool = registry.tool(named: call.name) 
else {\n   938\t            return .error("Unknown tool: \\(call.name)")\n   
939\t        }\n   940\t\n   941\t        let voiceDecision = 
VoiceIdentityPolicy.evaluateSensitiveAction(\n   942\t            config: 
config.speaker,\n   943\t            isOwner: currentSpeakerIsOwner,\n   944\t  
risk: tool.riskLevel,\n   945\t            toolName: call.name\n   946\t        
)\n   947\t\n   948\t        switch voiceDecision {\n   949\t        case 
.allow:\n   950\t            break\n   951\t        case .requireStepUp(let 
message):\n   952\t            if let manager = approvalManager {\n   953\t     
let approved = await manager.requestApproval(\n   954\t                    
toolName: call.name,\n   955\t                    description: "Step-up: 
\\(message)"\n   956\t                )\n   957\t                if !approved 
{\n   958\t                    return .error("Tool execution denied by user.")\n
959\t                }\n   960\t            } else {\n   961\t                
return .error(message)\n   962\t            }\n   963\t        case .deny(let 
message):\n   964\t            return .error(message)\n   965\t        }\n   
966\t\n   967\t        // Risk policy + approval routing.\n   968\t        let 
decision = ToolRiskPolicy.decision(for: tool)\n   969\t        if case 
.requireApproval(let reason) = decision {\n   970\t            if let manager = 
approvalManager {\n   971\t                let approved = await 
manager.requestApproval(\n   972\t                    toolName: call.name,\n   
973\t                    description: "Execute \\(call.name) — \\(reason)"\n   
974\t                )\n   975\t                if !approved {\n   976\t        
return .error("Tool execution denied by user.")\n   977\t                }\n   
978\t            } else {\n   979\t                return .error("Tool requires 
approval, but no approval manager is available.")\n   980\t            }\n   
981\t        }\n   982\t\n   983\t        // Execute with timeout and 
analytics.\n   984\t        let startTime = Date()\n   985\t        let result: 
ToolResult\n   986\t        do {\n   987\t            result = try await 
withThrowingTaskGroup(of: ToolResult.self) { group in\n   988\t                
group.addTask {\n   989\t                    try await tool.execute(input: 
call.arguments)\n   990\t                }\n   991\t                
group.addTask {\n   992\t                    try await Task.sleep(nanoseconds: 
UInt64(Self.toolTimeoutSeconds * 1_000_000_000))\n   993\t                    
return .error("Tool timed out after \\(Int(Self.toolTimeoutSeconds))s")\n   
994\t                }\n   995\t                let r = try await 
group.next()!\n   996\t                group.cancelAll()\n   997\t              
return r\n   998\t            }\n   999\t        } catch {\n  1000\t            
let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)\n  1001\t       
if let analytics = toolAnalytics {\n  1002\t                await 
analytics.record(\n  1003\t                    toolName: call.name, success: 
false, latencyMs: latencyMs,\n  1004\t                    approved: true, error:
error.localizedDescription\n  1005\t                )\n  1006\t            }\n  
1007\t            return .error("Tool error: \\(error.localizedDescription)")\n 
1008\t        }\n  1009\t\n',
        message='80 lines read from file starting from line 930.',
        display=[],
        extras=None
    )
)
StepBegin(n=3)
ThinkPart(
    type='think',
    think='Let me look at a few more areas to complete the analysis.',
    encrypted=None
)
ToolCall(
    type='function',
    id='tool_nw6i4Bplxw2R2yfvt1IhDPVg',
    function=FunctionBody(
        name='ReadFile',
        arguments='{"path": 
"/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/ML/C
oreMLSpeakerEncoder.swift", "line_offset": 400, "n_lines": 100}'
    ),
    extras=None
)
ToolCall(
    type='function',
    id='tool_oEkVvLLR5NokIKnnMAbH5EOD',
    function=FunctionBody(name='ReadFile', arguments='{"path": "/Users/d'),
    extras=None
)
ToolResult(
    tool_call_id='tool_nw6i4Bplxw2R2yfvt1IhDPVg',
    return_value=ToolOk(
        is_error=False,
        output='   400\t\n   401\t                // Average.\n   402\t         
var divisor = Float(numFrames)\n   403\t                vDSP_vsdiv(embedding, 1,
&divisor, &embedding, 1, vDSP_Length(dim))\n   404\t\n   405\t                
return embedding\n   406\t            }\n   407\t        }\n   408\t\n   409\t  
throw MLEngineError.notLoaded("SpeakerEncoder: no valid output tensor found")\n 
410\t    }\n   411\t\n   412\t    // MARK: - Liveness Heuristics\n   413\t\n   
414\t    /// Result of basic replay/liveness checks on audio.\n   415\t    
struct LivenessCheck: Sendable {\n   416\t        /// Variance of mel-band 
energy across frames (low = potential replay).\n   417\t        let 
spectralVariance: Float\n   418\t        /// Ratio of high-frequency energy to 
total (low = codec compression artifacts).\n   419\t        let highFreqRatio: 
Float\n   420\t        /// Whether the audio looks suspicious (not blocking — 
informational only).\n   421\t        let isSuspicious: Bool\n   422\t    }\n   
423\t\n   424\t    /// Run lightweight liveness heuristics on a log-mel 
spectrogram.\n   425\t    ///\n   426\t    /// Checks for two replay 
indicators:\n   427\t    /// 1. **Spectral variance**: Real speech has dynamic 
formant variation across frames.\n   428\t    ///    Recordings played through 
speakers tend to be spectrally flatter.\n   429\t    /// 2. **High-frequency 
energy**: Codec compression (MP3, AAC, Opus) attenuates\n   430\t    ///    
energy above ~16 kHz. Raw microphone input preserves full bandwidth.\n   431\t  
///\n   432\t    /// Returns a `LivenessCheck` with findings. Does NOT block 
embedding —\n   433\t    /// suspicion is logged for diagnostics only.\n   434\t
static func checkLiveness(mel: [Float], numFrames: Int) -> LivenessCheck {\n   
435\t        guard numFrames > 1 else {\n   436\t            return 
LivenessCheck(spectralVariance: 0, highFreqRatio: 0, isSuspicious: false)\n   
437\t        }\n   438\t\n   439\t        // 1. Spectral variance: compute 
per-frame energy, then variance across frames.\n   440\t        var 
frameEnergies = [Float](repeating: 0, count: numFrames)\n   441\t        for f 
in 0..<numFrames {\n   442\t            var energy: Float = 0\n   443\t         
for m in 0..<numMels {\n   444\t                energy += mel[m * numFrames + 
f]\n   445\t            }\n   446\t            frameEnergies[f] = energy / 
Float(numMels)\n   447\t        }\n   448\t\n   449\t        var meanEnergy: 
Float = 0\n   450\t        vDSP_meanv(frameEnergies, 1, &meanEnergy, 
vDSP_Length(numFrames))\n   451\t\n   452\t        var sumSqDiff: Float = 0\n   
453\t        for e in frameEnergies {\n   454\t            let diff = e - 
meanEnergy\n   455\t            sumSqDiff += diff * diff\n   456\t        }\n   
457\t        let spectralVariance = sumSqDiff / Float(numFrames)\n   458\t\n   
459\t        // 2. High-frequency energy ratio: compare top 1/4 mel bands vs 
total.\n   460\t        let highBandStart = numMels * 3 / 4  // top 32 of 128 
bands\n   461\t        var totalEnergy: Float = 0\n   462\t        var 
highEnergy: Float = 0\n   463\t        for m in 0..<numMels {\n   464\t         
var bandSum: Float = 0\n   465\t            let base = m * numFrames\n   466\t  
vDSP_sve(Array(mel[base..<(base + numFrames)]), 1, &bandSum, 
vDSP_Length(numFrames))\n   467\t            totalEnergy += abs(bandSum)\n   
468\t            if m >= highBandStart {\n   469\t                highEnergy += 
abs(bandSum)\n   470\t            }\n   471\t        }\n   472\t        let 
highFreqRatio = totalEnergy > 1e-10 ? highEnergy / totalEnergy : 0\n   473\t\n  
474\t        // Thresholds (empirically tuned — conservative to minimize false 
positives).\n   475\t        let lowVariance = spectralVariance < 0.05\n   476\t
let lowHighFreq = highFreqRatio < 0.02\n   477\t        let isSuspicious = 
lowVariance && lowHighFreq\n   478\t\n   479\t        return LivenessCheck(\n   
480\t            spectralVariance: spectralVariance,\n   481\t            
highFreqRatio: highFreqRatio,\n   482\t            isSuspicious: isSuspicious\n 
483\t        )\n   484\t    }\n   485\t\n   486\t    // MARK: - L2 
Normalization\n   487\t\n   488\t    private static func l2Normalize(_ vec: 
[Float]) -> [Float] {\n   489\t        var sumSq: Float = 0\n   490\t        
vDSP_svesq(vec, 1, &sumSq, vDSP_Length(vec.count))\n   491\t        let norm = 
sqrtf(sumSq)\n   492\t        guard norm > 1e-10 else { return vec }\n   493\t\n
494\t        var result = [Float](repeating: 0, count: vec.count)\n   495\t     
var divisor = norm\n   496\t        vDSP_vsdiv(vec, 1, &divisor, &result, 1, 
vDSP_Length(vec.count))\n   497\t        return result\n   498\t    }\n   
499\t}\n',
        message='100 lines read from file starting from line 400.',
        display=[],
        extras=None
    )
)
ToolCallPart(
    arguments_part='avidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sourc
es/Fae/Tools/RoleplayTool.swift", "line_offset": 100, "n_lines": 80}'
)
StatusUpdate(
    context_usage=0.1342926025390625,
    token_usage=TokenUsage(
        input_other=1668,
        output=129,
        input_cache_read=33536,
        input_cache_creation=0
    ),
    message_id='chatcmpl-Wq5YmYmjjc90RAgpVbXGmu7i'
)
ToolResult(
    tool_call_id='tool_oEkVvLLR5NokIKnnMAbH5EOD',
    return_value=ToolOk(
        is_error=False,
        output='   100\t    /// Load saved voice assignments for a given session
title.\n   101\t    ///\n   102\t    /// Returns an empty dictionary if no saved
data exists or the file is corrupt.\n   103\t    func load(forTitle title: 
String) -> [String: String] {\n   104\t        guard let url = fileURL else { 
return [:] }\n   105\t\n   106\t        do {\n   107\t            let data = try
Data(contentsOf: url)\n   108\t            let all = try 
JSONDecoder().decode([String: [String: String]].self, from: data)\n   109\t     
return all[title] ?? [:]\n   110\t        } catch {\n   111\t            // 
Missing file or corrupt data — start fresh (don\'t log missing file).\n   112\t 
if !((error as NSError).domain == NSCocoaErrorDomain\n   113\t                &&
(error as NSError).code == NSFileReadNoSuchFileError)\n   114\t            {\n  
115\t                NSLog("RoleplayVoicePersistence: load error: %@", 
error.localizedDescription)\n   116\t            }\n   117\t            return 
[:]\n   118\t        }\n   119\t    }\n   120\t\n   121\t    /// Save voice 
assignments for a given session title.\n   122\t    ///\n   123\t    /// Merges 
with existing sessions on disk so other sessions are preserved.\n   124\t    
func save(voices: [String: String], forTitle title: String) {\n   125\t        
guard let url = fileURL else { return }\n   126\t\n   127\t        // Load 
existing sessions first.\n   128\t        var all: [String: [String: String]] = 
[:]\n   129\t        if let data = try? Data(contentsOf: url),\n   130\t        
let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: 
data)\n   131\t        {\n   132\t            all = decoded\n   133\t        }\n
134\t\n   135\t        // Update this session.\n   136\t        all[title] = 
voices\n   137\t\n   138\t        // Ensure directory exists.\n   139\t        
do {\n   140\t            try FileManager.default.createDirectory(\n   141\t    
at: url.deletingLastPathComponent(),\n   142\t                
withIntermediateDirectories: true\n   143\t            )\n   144\t            
let encoder = JSONEncoder()\n   145\t            encoder.outputFormatting = 
[.prettyPrinted, .sortedKeys]\n   146\t            let data = try 
encoder.encode(all)\n   147\t            try data.write(to: url, options: 
.atomic)\n   148\t        } catch {\n   149\t            
NSLog("RoleplayVoicePersistence: save error: %@", error.localizedDescription)\n 
150\t        }\n   151\t    }\n   152\t}\n   153\t\n   154\t// MARK: - Roleplay 
Tool\n   155\t\n   156\t/// Tool for managing multi-voice roleplay reading 
sessions.\n   157\t///\n   158\t/// When active, the LLM uses `<voice 
character="Name">dialog</voice>` tags\n   159\t/// inline during generation. The
pipeline\'s `VoiceTagStripper` parses these\n   160\t/// and routes each segment
to TTS with the appropriate voice description.\n   161\tstruct RoleplayTool: 
Tool {\n   162\t    let name = "roleplay"\n   163\t    let description = """\n  
164\t        Manage a roleplay reading session with distinct character voices. 
\\\n   165\t        Actions: start (begin session), assign_voice (map character 
to voice description), \\\n   166\t        list_characters (show mappings), stop
(end session). \\\n   167\t        When active, use <voice 
character="Name">dialog</voice> tags in your response.\n   168\t        """\n   
169\t    let parametersSchema = """\n   170\t        {"action": "string 
(start|assign_voice|list_characters|stop)", \\\n   171\t        "title": "string
(optional, for start)", \\\n   172\t        "character": "string (required for 
assign_voice)", \\\n   173\t        "voice_description": "string (required for 
assign_voice, under 50 words: gender, age, accent, style)"}\n   174\t        
"""\n   175\t    let requiresApproval = false\n   176\t    let example = 
#"<tool_call>{"name":"roleplay","arguments":{"action":"start","title":"Hamlet 
Act 3"}}</tool_call>"#\n   177\t\n   178\t    func execute(input: [String: Any])
async throws -> ToolResult {\n   179\t        guard let action = input["action"]
as? String else {\n',
        message='80 lines read from file starting from line 100.',
        display=[],
        extras=None
    )
)
StepBegin(n=4)
ThinkPart(
    type='think',
    think='Now let me check the scheduler persistence store to understand the 
database operations better.',
    encrypted=None
)
ToolCall(
    type='function',
    id='tool_XjjdKdIOuN4joPzQUzB22u3r',
    function=FunctionBody(
        name='Glob',
        arguments='{"pattern": 
"native/macos/Fae/Sources/Fae/Scheduler/*.swift"}'
    ),
    extras=None
)
StatusUpdate(
    context_usage=0.14369583129882812,
    token_usage=TokenUsage(
        input_other=2597,
        output=45,
        input_cache_read=35072,
        input_cache_creation=0
    ),
    message_id='chatcmpl-cjeR1pKSlNdQz4eYkkkFnOPH'
)
ToolResult(
    tool_call_id='tool_XjjdKdIOuN4joPzQUzB22u3r',
    return_value=ToolOk(
        is_error=False,
        output='native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler+Proactive.sw
ift\nnative/macos/Fae/Sources/Fae/Scheduler/FaeScheduler+Reliability.swift\nnati
ve/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift\nnative/macos/Fae/Sources/
Fae/Scheduler/ProactivePolicyEngine.swift\nnative/macos/Fae/Sources/Fae/Schedule
r/SchedulerPersistenceStore.swift\nnative/macos/Fae/Sources/Fae/Scheduler/TaskRu
nLedger.swift',
        message='Found 6 matches for pattern 
`native/macos/Fae/Sources/Fae/Scheduler/*.swift`.',
        display=[],
        extras=None
    )
)
StepBegin(n=5)
ThinkPart(
    type='think',
    think='Let me check the SchedulerPersistenceStore to understand the 
persistence layer.',
    encrypted=None
)
ToolCall(
    type='function',
    id='tool_RK6VaX3jZvp5AWGe9K74s3IG',
    function=FunctionBody(
        name='ReadFile',
        arguments='{"path": 
"/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Sche
duler/SchedulerPersistenceStore.swift"}'
    ),
    extras=None
)
StatusUpdate(
    context_usage=0.1444549560546875,
    token_usage=TokenUsage(
        input_other=236,
        output=59,
        input_cache_read=37632,
        input_cache_creation=0
    ),
    message_id='chatcmpl-gr46Ho1feH3ebveafqmtsQ7h'
)
ToolResult(
    tool_call_id='tool_RK6VaX3jZvp5AWGe9K74s3IG',
    return_value=ToolOk(
        is_error=False,
        output='     1\timport Foundation\n     2\timport GRDB\n     3\t\n     
4\t/// GRDB-backed SQLite persistence for scheduler state.\n     5\t///\n     
6\t/// Stores task run records (idempotency, retries, history) and\n     7\t/// 
task enabled/disabled state. Separate from `fae.db` to avoid\n     8\t/// 
coupling with the memory store.\n     9\t///\n    10\t/// Path: 
`~/Library/Application Support/fae/scheduler.db`\n    11\tactor 
SchedulerPersistenceStore {\n    12\t    private let dbQueue: DatabaseQueue\n   
13\t\n    14\t    /// Open or create the scheduler database at the given path.\n
15\t    init(path: String) throws {\n    16\t        let dir = (path as 
NSString).deletingLastPathComponent\n    17\t        try 
FileManager.default.createDirectory(\n    18\t            atPath: dir,\n    19\t
withIntermediateDirectories: true\n    20\t        )\n    21\t\n    22\t        
var config = Configuration()\n    23\t        config.prepareDatabase { db in\n  
24\t            try db.execute(sql: "PRAGMA journal_mode = WAL")\n    25\t      
try db.execute(sql: "PRAGMA foreign_keys = ON")\n    26\t        }\n    27\t    
dbQueue = try DatabaseQueue(path: path, configuration: config)\n    28\t        
try dbQueue.write { db in\n    29\t            try Self.applySchema(db)\n    
30\t        }\n    31\t\n    32\t        NSLog("SchedulerPersistenceStore: 
opened at %@", path)\n    33\t    }\n    34\t\n    35\t    // MARK: - Schema\n  
36\t\n    37\t    private static func applySchema(_ db: Database) throws {\n    
38\t        try db.execute(sql: """\n    39\t            CREATE TABLE IF NOT 
EXISTS task_runs (\n    40\t                id              INTEGER PRIMARY KEY 
AUTOINCREMENT,\n    41\t                task_id         TEXT NOT NULL,\n    42\t
idempotency_key TEXT NOT NULL UNIQUE,\n    43\t                state           
TEXT NOT NULL,\n    44\t                attempt         INTEGER NOT NULL DEFAULT
0,\n    45\t                updated_at      REAL NOT NULL,\n    46\t            
last_error      TEXT\n    47\t            )\n    48\t            """)\n    49\t 
try db.execute(\n    50\t            sql: "CREATE INDEX IF NOT EXISTS 
idx_task_runs_task_id ON task_runs(task_id)"\n    51\t        )\n    52\t\n    
53\t        try db.execute(sql: """\n    54\t            CREATE TABLE IF NOT 
EXISTS scheduler_state (\n    55\t                task_id    TEXT PRIMARY KEY,\n
56\t                enabled    INTEGER NOT NULL DEFAULT 1,\n    57\t            
updated_at REAL NOT NULL\n    58\t            )\n    59\t            """)\n    
60\t    }\n    61\t\n    62\t    // MARK: - Task Runs\n    63\t\n    64\t    ///
Check whether an idempotency key has already been recorded.\n    65\t    func 
hasSeenKey(_ key: String) throws -> Bool {\n    66\t        try dbQueue.read { 
db in\n    67\t            let row = try Row.fetchOne(\n    68\t                
db,\n    69\t                sql: "SELECT 1 FROM task_runs WHERE idempotency_key
= ? LIMIT 1",\n    70\t                arguments: [key]\n    71\t            )\n
72\t            return row != nil\n    73\t        }\n    74\t    }\n    75\t\n 
76\t    /// Insert a new task run record. Silently ignores duplicate idempotency
keys.\n    77\t    func insertRun(_ record: TaskRunRecord) throws {\n    78\t   
try dbQueue.write { db in\n    79\t            try db.execute(\n    80\t        
sql: """\n    81\t                    INSERT OR IGNORE INTO task_runs\n    82\t 
(task_id, idempotency_key, state, attempt, updated_at, last_error)\n    83\t    
VALUES (?, ?, ?, ?, ?, ?)\n    84\t                    """,\n    85\t           
arguments: [\n    86\t                    record.taskID,\n    87\t              
record.idempotencyKey,\n    88\t                    record.state.rawValue,\n    
89\t                    record.attempt,\n    90\t                    
record.updatedAt.timeIntervalSince1970,\n    91\t                    
record.lastError,\n    92\t                ]\n    93\t            )\n    94\t   
}\n    95\t    }\n    96\t\n    97\t    /// Update the state (and optionally 
error) of an existing run by idempotency key.\n    98\t    func 
updateRunState(idempotencyKey: String, state: TaskRunState, error: String?) 
throws {\n    99\t        try dbQueue.write { db in\n   100\t            try 
db.execute(\n   101\t                sql: """\n   102\t                    
UPDATE task_runs\n   103\t                    SET state = ?, last_error = ?, 
updated_at = ?\n   104\t                    WHERE idempotency_key = ?\n   105\t 
""",\n   106\t                arguments: [\n   107\t                    
state.rawValue,\n   108\t                    error,\n   109\t                   
Date().timeIntervalSince1970,\n   110\t                    idempotencyKey,\n   
111\t                ]\n   112\t            )\n   113\t        }\n   114\t    
}\n   115\t\n   116\t    /// Return the most recent run record for a task, or 
nil.\n   117\t    func latestRun(taskID: String) throws -> TaskRunRecord? {\n   
118\t        try dbQueue.read { db in\n   119\t            guard let row = try 
Row.fetchOne(\n   120\t                db,\n   121\t                sql: """\n  
122\t                    SELECT task_id, idempotency_key, state, attempt, 
updated_at, last_error\n   123\t                    FROM task_runs\n   124\t    
WHERE task_id = ?\n   125\t                    ORDER BY updated_at DESC\n   
126\t                    LIMIT 1\n   127\t                    """,\n   128\t    
arguments: [taskID]\n   129\t            ) else { return nil }\n   130\t        
return Self.recordFromRow(row)\n   131\t        }\n   132\t    }\n   133\t\n   
134\t    /// Return recent run records for a task, ordered by most recent 
first.\n   135\t    func recentRuns(taskID: String, limit: Int = 20) throws -> 
[TaskRunRecord] {\n   136\t        try dbQueue.read { db in\n   137\t           
let rows = try Row.fetchAll(\n   138\t                db,\n   139\t             
sql: """\n   140\t                    SELECT task_id, idempotency_key, state, 
attempt, updated_at, last_error\n   141\t                    FROM task_runs\n   
142\t                    WHERE task_id = ?\n   143\t                    ORDER BY
updated_at DESC\n   144\t                    LIMIT ?\n   145\t                  
""",\n   146\t                arguments: [taskID, limit]\n   147\t            
)\n   148\t            return rows.map { Self.recordFromRow($0) }\n   149\t     
}\n   150\t    }\n   151\t\n   152\t    /// Delete runs older than the given 
date. Returns the number of deleted rows.\n   153\t    @discardableResult\n   
154\t    func pruneOldRuns(olderThan date: Date) throws -> Int {\n   155\t      
try dbQueue.write { db in\n   156\t            try db.execute(\n   157\t        
sql: "DELETE FROM task_runs WHERE updated_at < ?",\n   158\t                
arguments: [date.timeIntervalSince1970]\n   159\t            )\n   160\t        
return db.changesCount\n   161\t        }\n   162\t    }\n   163\t\n   164\t    
/// Return timestamps of successful runs for a task, most recent first.\n   
165\t    func runHistory(taskID: String, limit: Int = 20) throws -> [Date] {\n  
166\t        try dbQueue.read { db in\n   167\t            let rows = try 
Row.fetchAll(\n   168\t                db,\n   169\t                sql: """\n  
170\t                    SELECT updated_at FROM task_runs\n   171\t             
WHERE task_id = ? AND state = ?\n   172\t                    ORDER BY updated_at
DESC\n   173\t                    LIMIT ?\n   174\t                    """,\n   
175\t                arguments: [taskID, TaskRunState.success.rawValue, limit]\n
176\t            )\n   177\t            return rows.map { 
Date(timeIntervalSince1970: $0["updated_at"]) }\n   178\t        }\n   179\t    
}\n   180\t\n   181\t    // MARK: - Task Enabled/Disabled State\n   182\t\n   
183\t    /// Load all task IDs that are currently disabled.\n   184\t    func 
loadDisabledTaskIDs() throws -> Set<String> {\n   185\t        try dbQueue.read 
{ db in\n   186\t            let rows = try Row.fetchAll(\n   187\t             
db,\n   188\t                sql: "SELECT task_id FROM scheduler_state WHERE 
enabled = 0"\n   189\t            )\n   190\t            return Set(rows.map { 
$0["task_id"] as String })\n   191\t        }\n   192\t    }\n   193\t\n   194\t
/// Set a task\'s enabled/disabled state (INSERT OR REPLACE).\n   195\t    func 
setTaskEnabled(id: String, enabled: Bool) throws {\n   196\t        try 
dbQueue.write { db in\n   197\t            try db.execute(\n   198\t            
sql: """\n   199\t                    INSERT OR REPLACE INTO scheduler_state 
(task_id, enabled, updated_at)\n   200\t                    VALUES (?, ?, ?)\n  
201\t                    """,\n   202\t                arguments: [id, enabled ?
1 : 0, Date().timeIntervalSince1970]\n   203\t            )\n   204\t        }\n
205\t    }\n   206\t\n   207\t    // MARK: - Row Mapping\n   208\t\n   209\t    
private static func recordFromRow(_ row: Row) -> TaskRunRecord {\n   210\t      
TaskRunRecord(\n   211\t            taskID: row["task_id"],\n   212\t           
idempotencyKey: row["idempotency_key"],\n   213\t            state: 
TaskRunState(rawValue: row["state"]) ?? .idle,\n   214\t            attempt: 
row["attempt"],\n   215\t            updatedAt: Date(timeIntervalSince1970: 
row["updated_at"]),\n   216\t            lastError: row["last_error"]\n   217\t 
)\n   218\t    }\n   219\t}\n',
        message='219 lines read from file starting from line 1. End of file 
reached.',
        display=[],
        extras=None
    )
)
Max number of steps reached: 5
