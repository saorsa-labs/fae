import XCTest
@testable import Fae

// MARK: - SentimentClassifier Tests

final class SentimentClassifierTests: XCTestCase {

    // MARK: - Warmth

    func testClassifiesWarmthWithMultipleKeywords() {
        let text = "I'm so glad you're here. I love working with you and I really appreciate your help."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .warmth)
    }

    func testClassifiesWarmthWithThankAndKind() {
        let text = "Thank you for being so kind and sweet today."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .warmth)
    }

    // MARK: - Concern

    func testClassifiesConcernWithMultipleKeywords() {
        let text = "I'm sorry to hear that. This is a difficult problem and I'm worried about the issue."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .concern)
    }

    func testClassifiesConcernWithUnfortunately() {
        let text = "Unfortunately this is concerning and I struggle with it."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .concern)
    }

    // MARK: - Delight

    func testClassifiesDelight() {
        let text = "This is amazing and fantastic! Brilliant work, absolutely perfect and incredible."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .delight)
    }

    func testClassifiesDelightWithAwesome() {
        let text = "That's awesome and delightful!"
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .delight)
    }

    // MARK: - Curiosity

    func testClassifiesCuriosity() {
        let text = "That's interesting and fascinating. I wonder what happens if we explore this further."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .curiosity)
    }

    func testClassifiesCuriosityWithInvestigate() {
        let text = "Let me investigate this question — it's quite intriguing and curious."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .curiosity)
    }

    // MARK: - Calm

    func testClassifiesCalm() {
        let text = "Just relax and breathe. Be peaceful and gentle. Everything is serene and tranquil."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .calm)
    }

    func testClassifiesCalmWithQuietly() {
        let text = "Slowly and quietly, softly and steadily."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .calm)
    }

    // MARK: - Focus

    func testClassifiesFocus() {
        let text = "Let me think about this. I'm analyzing and processing the data, examining it carefully."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .focus)
    }

    func testClassifiesFocusWithCalculating() {
        let text = "I'm calculating and reviewing, checking the results and considering all options."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .focus)
    }

    // MARK: - Playful

    func testClassifiesPlayful() {
        let text = "Haha that's funny! What a silly joke. Let's have fun and play."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .playful)
    }

    func testClassifiesPlayfulWithCheeky() {
        let text = "That's clever and cheeky! Laugh along with this funny guess what moment."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .playful)
    }

    // MARK: - Threshold enforcement

    func testReturnsNilBelowThreshold() {
        // Only one keyword hit — below threshold of 2
        let text = "I'm glad to see you."
        let result = SentimentClassifier.classify(text)
        XCTAssertNil(result)
    }

    func testReturnsNilForNeutralText() {
        let text = "The weather is nice today. I have a meeting at three."
        let result = SentimentClassifier.classify(text)
        XCTAssertNil(result)
    }

    func testReturnsNilForEmptyString() {
        let result = SentimentClassifier.classify("")
        XCTAssertNil(result)
    }

    // MARK: - Tie-breaking (highest score wins)

    func testReturnsHighestScoringFeeling() {
        // warmth has 2 hits, concern has 1 hit — warmth should win
        let text = "I'm glad and happy, but sorry about that."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .warmth)
    }

    func testCaseInsensitive() {
        let text = "THIS IS AMAZING AND FANTASTIC!"
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .delight)
    }

    // MARK: - Exactly at threshold

    func testReturnsFeelingAtExactThreshold() {
        // Exactly 2 hits (threshold is 2.0)
        let text = "I'm glad and happy."
        let result = SentimentClassifier.classify(text)
        XCTAssertEqual(result, .warmth)
    }
}

// MARK: - ToolPermissionSnapshot Tests

final class ToolPermissionSnapshotTests: XCTestCase {

    private var allGrantedPermissions: PermissionStatusProvider.Snapshot {
        PermissionStatusProvider.Snapshot(
            microphone: true,
            contacts: true,
            calendar: true,
            reminders: true,
            screenRecording: true,
            camera: true,
        )
    }

    private func makeSnapshot(permissions: PermissionStatusProvider.Snapshot) -> ToolPermissionSnapshot {
        ToolPermissionSnapshot(
            generatedAt: Date(),
            triggerText: "test trigger",
            toolMode: "full",
            policyProfile: "default",
            speakerState: "verified",
            ownerGateEnabled: true,
            ownerProfileExists: true,
            permissions: permissions,
            thinkingEnabled: true,
            requireDirectAddress: false,
            visionEnabled: true,
            voiceIdentityLock: false,
            allowedTools: ["read", "write"],
            deniedTools: ["bash"]
        )
    }

    // MARK: - Missing Permission Actions

    func testNoMissingPermissionsWhenAllGranted() {
        let snapshot = makeSnapshot(permissions: allGrantedPermissions)
        XCTAssertTrue(snapshot.missingPermissionActions.isEmpty)
    }

    func testDetectsMissingMicrophone() {
        let perms = PermissionStatusProvider.Snapshot(
            microphone: false,
            contacts: true,
            calendar: true,
            reminders: true,
            screenRecording: true,
            camera: true,
        )
        let snapshot = makeSnapshot(permissions: perms)
        XCTAssertEqual(snapshot.missingPermissionActions.count, 1)
        XCTAssertEqual(snapshot.missingPermissionActions[0].label, "Microphone", "should list Microphone as missing")
        XCTAssertEqual(snapshot.missingPermissionActions[0].capability, "microphone", "capability should be 'microphone'")
    }

    func testDetectsAllMissingPermissions() {
        let perms = PermissionStatusProvider.Snapshot(
            microphone: false,
            contacts: false,
            calendar: false,
            reminders: false,
            screenRecording: false,
            camera: false,
        )
        let snapshot = makeSnapshot(permissions: perms)
        XCTAssertEqual(snapshot.missingPermissionActions.count, 6)
    }

    func testMissingPermissionsHaveCorrectCapabilities() {
        let perms = PermissionStatusProvider.Snapshot(
            microphone: false,
            contacts: false,
            calendar: true,
            reminders: true,
            screenRecording: false,
            camera: false,
        )
        let snapshot = makeSnapshot(permissions: perms)
        let capabilities = snapshot.missingPermissionActions.map { $0.capability }
        XCTAssertEqual(capabilities, ["microphone", "contacts", "camera", "screen_recording"])
    }

}

// MARK: - DiagnosticsManager Tests

final class DiagnosticsManagerTests: XCTestCase {

    func testHealthStatusDefaults() {
        let status = DiagnosticsManager.HealthStatus()
        XCTAssertFalse(status.sttLoaded)
        XCTAssertFalse(status.llmLoaded)
        XCTAssertFalse(status.ttsLoaded)
        XCTAssertFalse(status.pipelineRunning)
        XCTAssertEqual(status.memoryRecordCount, 0)
        XCTAssertEqual(status.uptimeSeconds, 0)
    }

    func testHealthStatusIsSendable() {
        let status = DiagnosticsManager.HealthStatus(
            sttLoaded: true,
            llmLoaded: true,
            ttsLoaded: true,
            pipelineRunning: true,
            memoryRecordCount: 42,
            uptimeSeconds: 100
        )
        // Sendable check — just verify it compiles and values are correct
        XCTAssertTrue(status.sttLoaded)
        XCTAssertEqual(status.memoryRecordCount, 42)
    }

    @MainActor
    func testDiagnosticsManagerUpdate() {
        let manager = DiagnosticsManager()
        manager.update(
            sttLoaded: true,
            llmLoaded: true,
            ttsLoaded: false,
            pipelineRunning: true,
            memoryRecordCount: 10
        )

        XCTAssertTrue(manager.healthStatus.sttLoaded)
        XCTAssertTrue(manager.healthStatus.llmLoaded)
        XCTAssertFalse(manager.healthStatus.ttsLoaded)
        XCTAssertTrue(manager.healthStatus.pipelineRunning)
        XCTAssertEqual(manager.healthStatus.memoryRecordCount, 10)
        XCTAssertGreaterThanOrEqual(manager.healthStatus.uptimeSeconds, 0)
    }

    @MainActor
    func testDiagnosticsManagerSummary() {
        let manager = DiagnosticsManager()
        manager.update(
            sttLoaded: true,
            llmLoaded: false,
            ttsLoaded: true,
            pipelineRunning: false,
            memoryRecordCount: 5
        )

        let summary = manager.summary
        XCTAssertTrue(summary.contains("STT: loaded"))
        XCTAssertTrue(summary.contains("LLM: not loaded"))
        XCTAssertTrue(summary.contains("TTS: loaded"))
        XCTAssertTrue(summary.contains("Pipeline: stopped"))
        XCTAssertTrue(summary.contains("Memory: 5 records"))
    }

    @MainActor
    func testDiagnosticsManagerSummaryUptime() {
        let manager = DiagnosticsManager()
        manager.update(
            sttLoaded: true,
            llmLoaded: true,
            ttsLoaded: true,
            pipelineRunning: true,
            memoryRecordCount: 0
        )

        let summary = manager.summary
        XCTAssertTrue(summary.contains("Uptime:"))
        XCTAssertTrue(summary.contains("s"))
    }
}

// MARK: - SpeakerGateState Tests

final class SpeakerGateStateTests: XCTestCase {

    func testDefaultValues() {
        var state = SpeakerGateState()
        XCTAssertNil(state.currentSpeakerLabel)
        XCTAssertNil(state.currentSpeakerDisplayName)
        XCTAssertNil(state.currentSpeakerRole)
        XCTAssertFalse(state.currentSpeakerIsOwner)
        XCTAssertFalse(state.currentSpeakerIsKnownNonOwner)
        XCTAssertNil(state.speakerEncoderMelFallbackCached)
        XCTAssertNil(state.previousSpeakerLabel)
        XCTAssertEqual(state.utterancesSinceOwnerVerified, 0)
        XCTAssertNil(state.currentUtteranceTimestamp)
        XCTAssertFalse(state.firstOwnerEnrollmentActive)
        XCTAssertNil(state.firstOwnerEnrollmentContext)
        XCTAssertTrue(state.streamingSpeakerSamples.isEmpty)
        XCTAssertEqual(state.streamingSpeakerLastEvaluatedSamples, 0)
        XCTAssertNil(state.streamingSpeakerVerdict)
        XCTAssertFalse(state.streamingSpeakerVerificationAvailable)
    }

    func testResetStreamingSpeakerGate() {
        var state = SpeakerGateState()
        state.streamingSpeakerSamples = [1.0, 2.0, 3.0]
        state.streamingSpeakerLastEvaluatedSamples = 100
        state.streamingSpeakerVerdict = .allow
        state.streamingSpeakerVerificationAvailable = true

        state.resetStreamingSpeakerGate()

        XCTAssertTrue(state.streamingSpeakerSamples.isEmpty)
        XCTAssertEqual(state.streamingSpeakerLastEvaluatedSamples, 0)
        XCTAssertNil(state.streamingSpeakerVerdict)
        XCTAssertFalse(state.streamingSpeakerVerificationAvailable)
    }

    func testResetStreamingSpeakerGateKeepsCapacity() {
        var state = SpeakerGateState()
        state.streamingSpeakerSamples = Array(repeating: 0.0, count: 1000)
        state.resetStreamingSpeakerGate()
        XCTAssertTrue(state.streamingSpeakerSamples.isEmpty)
        // Can't inspect capacity directly, but verify no crash
    }

    func testClearIdentity() {
        var state = SpeakerGateState()
        state.currentSpeakerLabel = "owner"
        state.currentSpeakerDisplayName = "David"
        state.currentSpeakerRole = .owner
        state.currentSpeakerIsOwner = true
        state.currentSpeakerIsKnownNonOwner = false
        state.previousSpeakerLabel = "guest"
        state.utterancesSinceOwnerVerified = 5
        state.currentUtteranceTimestamp = Date()
        state.streamingSpeakerSamples = [1.0]
        state.streamingSpeakerVerdict = .allow

        state.clearIdentity()

        XCTAssertNil(state.currentSpeakerLabel)
        XCTAssertNil(state.currentSpeakerDisplayName)
        XCTAssertNil(state.currentSpeakerRole)
        XCTAssertFalse(state.currentSpeakerIsOwner)
        XCTAssertFalse(state.currentSpeakerIsKnownNonOwner)
        XCTAssertNil(state.previousSpeakerLabel)
        XCTAssertEqual(state.utterancesSinceOwnerVerified, 0)
        XCTAssertNil(state.currentUtteranceTimestamp)
        XCTAssertTrue(state.streamingSpeakerSamples.isEmpty)
        XCTAssertNil(state.streamingSpeakerVerdict)
    }

    func testClearIdentityDoesNotAffectEnrollmentState() {
        var state = SpeakerGateState()
        state.firstOwnerEnrollmentActive = true
        state.firstOwnerEnrollmentContext = "enrolling"

        state.clearIdentity()

        // Enrollment state is separate from identity
        XCTAssertTrue(state.firstOwnerEnrollmentActive)
        XCTAssertEqual(state.firstOwnerEnrollmentContext, "enrolling")
    }

    func testStreamingSpeakerGateVerdictEquatable() {
        XCTAssertEqual(SpeakerGateState.StreamingSpeakerGateVerdict.allow,
                       SpeakerGateState.StreamingSpeakerGateVerdict.allow)
        XCTAssertEqual(SpeakerGateState.StreamingSpeakerGateVerdict.rejectUnknown,
                       SpeakerGateState.StreamingSpeakerGateVerdict.rejectUnknown)
        XCTAssertNotEqual(SpeakerGateState.StreamingSpeakerGateVerdict.allow,
                          SpeakerGateState.StreamingSpeakerGateVerdict.rejectUnknown)
    }

    func testSpeakerGateStateIsSendable() {
        let state = SpeakerGateState()
        // Compile-time check: just use it as Sendable
        _ = state as any Sendable
    }
}

// MARK: - TTSState Tests

final class TTSStateTests: XCTestCase {

    func testDefaultValues() {
        let state = TTSState()
        XCTAssertNil(state.pendingTask)
        XCTAssertNil(state.lastUserTurnEndedAt)
        XCTAssertFalse(state.ttfaEmittedForCurrentTurn)
    }

    func testSynthesisTimeoutIs30Seconds() {
        XCTAssertEqual(TTSState.synthesisTimeoutSeconds, 30)
    }

    func testResetForNewTurn() {
        let state = TTSState()
        state.ttfaEmittedForCurrentTurn = true
        state.resetForNewTurn()
        XCTAssertFalse(state.ttfaEmittedForCurrentTurn)
    }

    func testCancelPending() {
        let state = TTSState()
        let task = Task<Void, Never> { }
        state.pendingTask = task
        state.cancelPending()
        XCTAssertNil(state.pendingTask)
    }

    func testAwaitPending() async {
        let state = TTSState()
        let task = Task<Void, Never> { }
        state.pendingTask = task
        await state.awaitPending()
        XCTAssertNil(state.pendingTask)
    }

    func testSetLastUserTurnEndedAt() {
        let state = TTSState()
        let date = Date()
        state.lastUserTurnEndedAt = date
        XCTAssertEqual(state.lastUserTurnEndedAt, date)
    }
}
