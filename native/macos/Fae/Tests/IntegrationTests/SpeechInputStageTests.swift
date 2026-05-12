import XCTest
@testable import Fae

// MARK: - SpeechInputStage Tests

final class SpeechInputStageTests: XCTestCase {

    func testDefaultValues() {
        let stage = SpeechInputStage()
        XCTAssertFalse(stage.isRunning)
        XCTAssertEqual(stage.streamingEpoch, 0)
        XCTAssertTrue(stage.streamingWakeSamples.isEmpty)
        XCTAssertEqual(stage.streamingWakeLastEvaluatedSamples, 0)
        XCTAssertNil(stage.streamingWakeDetection)
        XCTAssertNil(stage.lastStreamingPartialTranscript)
        XCTAssertEqual(stage.speechSegmentsDroppedForBackpressure, 0)
        XCTAssertEqual(stage.speechSegmentsDroppedForStaleness, 0)
    }

    func testSpeechSegmentQueueDepth() {
        XCTAssertEqual(SpeechInputStage.speechSegmentQueueDepth, 6)
    }

    func testSegmentStalenessThreshold() {
        XCTAssertEqual(SpeechInputStage.segmentStalenessThreshold, 30.0)
    }

    func testAcousticWakeEvalStride() {
        XCTAssertEqual(SpeechInputStage.acousticWakeEvalStrideSamples, 4_800)
    }

    func testIncrementStreamingEpoch() {
        let stage = SpeechInputStage()
        XCTAssertEqual(stage.streamingEpoch, 0)
        stage.incrementStreamingEpoch()
        XCTAssertEqual(stage.streamingEpoch, 1)
        stage.incrementStreamingEpoch()
        XCTAssertEqual(stage.streamingEpoch, 2)
    }

    func testResetStreamingWakeDetector() {
        let stage = SpeechInputStage()
        stage.streamingWakeSamples = Array(repeating: 0.5, count: 1000)
        stage.streamingWakeLastEvaluatedSamples = 500
        // Can't set detection directly if it's private, but verify samples reset
        stage.resetStreamingWakeDetector()
        XCTAssertTrue(stage.streamingWakeSamples.isEmpty)
        XCTAssertEqual(stage.streamingWakeLastEvaluatedSamples, 0)
    }

    func testSetPartialTranscript() {
        let stage = SpeechInputStage()
        stage.lastStreamingPartialTranscript = "hello"
        XCTAssertEqual(stage.lastStreamingPartialTranscript, "hello")
    }
}

// MARK: - AppleSpeechClassifier Constants Tests

final class AppleSpeechClassifierConstantsTests: XCTestCase {

    func testConfidenceThreshold() {
        XCTAssertEqual(AppleSpeechClassifier.confidenceThreshold, 0.5)
    }

    func testSpeechIdentifiers() {
        XCTAssertEqual(AppleSpeechClassifier.speechIdentifiers, ["speech"])
    }

    func testRejectIdentifiers() {
        let expected: Set<String> = ["music", "singing", "television"]
        XCTAssertEqual(AppleSpeechClassifier.rejectIdentifiers, expected)
    }
}

// MARK: - ClassificationResult Tests

final class ClassificationResultTests: XCTestCase {

    private func makeResult(
        isSpeech: Bool = true,
        isMusic: Bool = false,
        speechConfidence: Double = 0.9,
        musicConfidence: Double = 0.1,
        topClassification: String = "speech",
        topConfidence: Double = 0.9
    ) -> AppleSpeechClassifier.ClassificationResult {
        AppleSpeechClassifier.ClassificationResult(
            isSpeech: isSpeech,
            isMusic: isMusic,
            speechConfidence: speechConfidence,
            musicConfidence: musicConfidence,
            topClassification: topClassification,
            topConfidence: topConfidence,
            timestamp: Date()
        )
    }

    func testShouldProcessWhenSpeechDominates() {
        let result = makeResult(
            isSpeech: true,
            speechConfidence: 0.9,
            musicConfidence: 0.1
        )
        XCTAssertTrue(result.shouldProcessForSpeaker)
    }

    func testShouldNotProcessWhenMusicDominates() {
        let result = makeResult(
            isSpeech: true,
            speechConfidence: 0.3,
            musicConfidence: 0.8
        )
        XCTAssertFalse(result.shouldProcessForSpeaker)
    }

    func testShouldNotProcessWhenNotSpeech() {
        let result = makeResult(
            isSpeech: false,
            speechConfidence: 0.1,
            musicConfidence: 0.9
        )
        XCTAssertFalse(result.shouldProcessForSpeaker)
    }

    func testShouldNotProcessWhenEqualConfidence() {
        let result = makeResult(
            isSpeech: true,
            speechConfidence: 0.5,
            musicConfidence: 0.5
        )
        // speechConfidence > musicConfidence must be strictly greater
        XCTAssertFalse(result.shouldProcessForSpeaker)
    }

    func testIsSendable() {
        let result = makeResult()
        _ = result as any Sendable
    }

    func testTimestampIsSet() {
        let before = Date()
        let result = makeResult()
        let after = Date()
        XCTAssertGreaterThanOrEqual(result.timestamp.timeIntervalSince1970, before.timeIntervalSince1970)
        XCTAssertLessThanOrEqual(result.timestamp.timeIntervalSince1970, after.timeIntervalSince1970)
    }

    func testTopClassificationIsStored() {
        let result = makeResult(topClassification: "dog_bark")
        XCTAssertEqual(result.topClassification, "dog_bark")
    }

    func testConfidenceValuesAreStored() {
        let result = makeResult(
            speechConfidence: 0.75,
            musicConfidence: 0.25,
            topConfidence: 0.75
        )
        XCTAssertEqual(result.speechConfidence, 0.75)
        XCTAssertEqual(result.musicConfidence, 0.25)
        XCTAssertEqual(result.topConfidence, 0.75)
    }
}

// MARK: - ReversibilityEngine CheckpointRecord Tests

final class ReversibilityEngineCheckpointRecordTests: XCTestCase {

    func testCheckpointRecordCreation() {
        let record = ReversibilityEngine.CheckpointRecord(
            id: "test-id",
            createdAt: Date(),
            originalPath: "/tmp/test.txt",
            backupPath: "/tmp/backup.bak",
            existedBefore: true,
            reason: "test checkpoint"
        )
        XCTAssertEqual(record.id, "test-id")
        XCTAssertEqual(record.originalPath, "/tmp/test.txt")
        XCTAssertEqual(record.backupPath, "/tmp/backup.bak")
        XCTAssertTrue(record.existedBefore)
        XCTAssertEqual(record.reason, "test checkpoint")
    }

    func testCheckpointRecordWithNilBackup() {
        let record = ReversibilityEngine.CheckpointRecord(
            id: "new-file",
            createdAt: Date(),
            originalPath: "/tmp/new.txt",
            backupPath: nil,
            existedBefore: false,
            reason: "new file created"
        )
        XCTAssertNil(record.backupPath)
        XCTAssertFalse(record.existedBefore)
    }

    func testCheckpointRecordIsCodable() {
        let record = ReversibilityEngine.CheckpointRecord(
            id: "test-id",
            createdAt: Date(),
            originalPath: "/tmp/test.txt",
            backupPath: "/tmp/backup.bak",
            existedBefore: true,
            reason: "test"
        )

        let encoder = JSONEncoder()
        let data = try! encoder.encode(record)
        let decoder = JSONDecoder()
        let decoded = try! decoder.decode(ReversibilityEngine.CheckpointRecord.self, from: data)

        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.originalPath, record.originalPath)
        XCTAssertEqual(decoded.reason, record.reason)
    }

    func testCheckpointRecordIsSendable() {
        let record = ReversibilityEngine.CheckpointRecord(
            id: "test-id",
            createdAt: Date(),
            originalPath: "/tmp/test.txt",
            backupPath: nil,
            existedBefore: true,
            reason: "test"
        )
        _ = record as any Sendable
    }
}

// MARK: - FaeEvent Tests

final class FaeEventTests: XCTestCase {

    // MARK: - Pipeline events

    func testPipelineStateChanged() {
        let event = FaeEvent.pipelineStateChanged(.running)
        switch event {
        case .pipelineStateChanged(let state):
            XCTAssertEqual(state, .running)
        default:
            XCTFail("Expected pipelineStateChanged")
        }
    }

    func testAssistantGenerating() {
        let event = FaeEvent.assistantGenerating(true)
        switch event {
        case .assistantGenerating(let active):
            XCTAssertTrue(active)
        default:
            XCTFail("Expected assistantGenerating")
        }
    }

    func testAudioLevel() {
        let event = FaeEvent.audioLevel(0.75)
        switch event {
        case .audioLevel(let level):
            XCTAssertEqual(level, 0.75)
        default:
            XCTFail("Expected audioLevel")
        }
    }

    func testTranscription() {
        let event = FaeEvent.transcription(text: "hello", isFinal: true)
        switch event {
        case .transcription(let text, let isFinal):
            XCTAssertEqual(text, "hello")
            XCTAssertTrue(isFinal)
        default:
            XCTFail("Expected transcription")
        }
    }

    func testAssistantText() {
        let event = FaeEvent.assistantText(text: "response", isFinal: false)
        switch event {
        case .assistantText(let text, let isFinal):
            XCTAssertEqual(text, "response")
            XCTAssertFalse(isFinal)
        default:
            XCTFail("Expected assistantText")
        }
    }

    // MARK: - Runtime events

    func testRuntimeState() {
        let event = FaeEvent.runtimeState(.started)
        switch event {
        case .runtimeState(let state):
            XCTAssertEqual(state, .started)
        default:
            XCTFail("Expected runtimeState")
        }
    }

    func testRuntimeProgress() {
        let event = FaeEvent.runtimeProgress(stage: "loading", progress: 0.5)
        switch event {
        case .runtimeProgress(let stage, let progress):
            XCTAssertEqual(stage, "loading")
            XCTAssertEqual(progress, 0.5)
        default:
            XCTFail("Expected runtimeProgress")
        }
    }

    // MARK: - Orb events

    func testOrbStateChanged() {
        let event = FaeEvent.orbStateChanged(mode: "active", feeling: "warmth", palette: nil)
        switch event {
        case .orbStateChanged(let mode, let feeling, let palette):
            XCTAssertEqual(mode, "active")
            XCTAssertEqual(feeling, "warmth")
            XCTAssertNil(palette)
        default:
            XCTFail("Expected orbStateChanged")
        }
    }

    // MARK: - Approval events

    func testApprovalRequested() {
        let event = FaeEvent.approvalRequested(id: 1, toolName: "write", input: "test", manualOnly: false)
        switch event {
        case .approvalRequested(let id, let name, let input, let manualOnly, let isDisasterLevel):
            XCTAssertEqual(id, 1)
            XCTAssertEqual(name, "write")
            XCTAssertEqual(input, "test")
            XCTAssertFalse(manualOnly)
            XCTAssertFalse(isDisasterLevel)
        default:
            XCTFail("Expected approvalRequested")
        }
    }

    func testApprovalResolved() {
        let event = FaeEvent.approvalResolved(id: 1, approved: true, source: "user")
        switch event {
        case .approvalResolved(let id, let approved, let source):
            XCTAssertEqual(id, 1)
            XCTAssertTrue(approved)
            XCTAssertEqual(source, "user")
        default:
            XCTFail("Expected approvalResolved")
        }
    }

    // MARK: - Memory events

    func testMemoryRecalled() {
        let event = FaeEvent.memoryRecalled(count: 5)
        switch event {
        case .memoryRecalled(let count):
            XCTAssertEqual(count, 5)
        default:
            XCTFail("Expected memoryRecalled")
        }
    }

    func testMemoryCaptured() {
        let event = FaeEvent.memoryCaptured(id: "mem-123")
        switch event {
        case .memoryCaptured(let id):
            XCTAssertEqual(id, "mem-123")
        default:
            XCTFail("Expected memoryCaptured")
        }
    }

    // MARK: - Tool events

    func testToolExecuting() {
        let event = FaeEvent.toolExecuting(name: "read")
        switch event {
        case .toolExecuting(let name):
            XCTAssertEqual(name, "read")
        default:
            XCTFail("Expected toolExecuting")
        }
    }

    func testToolResult() {
        let event = FaeEvent.toolResult(id: "t1", name: "bash", success: true, output: "done")
        switch event {
        case .toolResult(let id, let name, let success, let output):
            XCTAssertEqual(id, "t1")
            XCTAssertEqual(name, "bash")
            XCTAssertTrue(success)
            XCTAssertEqual(output, "done")
        default:
            XCTFail("Expected toolResult")
        }
    }

    // MARK: - UI events

    func testCanvasVisibility() {
        let event = FaeEvent.canvasVisibility(true)
        switch event {
        case .canvasVisibility(let visible):
            XCTAssertTrue(visible)
        default:
            XCTFail("Expected canvasVisibility")
        }
    }

    func testCanvasContent() {
        let event = FaeEvent.canvasContent(html: "<p>test</p>", append: true)
        switch event {
        case .canvasContent(let html, let append):
            XCTAssertEqual(html, "<p>test</p>")
            XCTAssertTrue(append)
        default:
            XCTFail("Expected canvasContent")
        }
    }

    // MARK: - Model events

    func testModelLoaded() {
        let event = FaeEvent.modelLoaded(engine: "mlx", modelId: "qwen3-4b")
        switch event {
        case .modelLoaded(let engine, let modelId):
            XCTAssertEqual(engine, "mlx")
            XCTAssertEqual(modelId, "qwen3-4b")
        default:
            XCTFail("Expected modelLoaded")
        }
    }

    // MARK: - CoWork security events

    func testCoworkRedactionApplied() {
        let event = FaeEvent.coworkRedactionApplied(provider: "test", strippedFields: ["field1"])
        switch event {
        case .coworkRedactionApplied(let provider, let fields):
            XCTAssertEqual(provider, "test")
            XCTAssertEqual(fields, ["field1"])
        default:
            XCTFail("Expected coworkRedactionApplied")
        }
    }

    func testCoworkSecurityBlocked() {
        let event = FaeEvent.coworkSecurityBlocked(provider: "test", reason: "injection")
        switch event {
        case .coworkSecurityBlocked(let provider, let reason):
            XCTAssertEqual(provider, "test")
            XCTAssertEqual(reason, "injection")
        default:
            XCTFail("Expected coworkSecurityBlocked")
        }
    }

    // MARK: - Capability events

    func testCapabilityRequested() {
        let event = FaeEvent.capabilityRequested(capability: "camera", reason: "vision tool")
        switch event {
        case .capabilityRequested(let capability, let reason):
            XCTAssertEqual(capability, "camera")
            XCTAssertEqual(reason, "vision tool")
        default:
            XCTFail("Expected capabilityRequested")
        }
    }

    // MARK: - Sendable check

    func testFaeEventIsSendable() {
        let event: FaeEvent = .pipelineStateChanged(.running)
        _ = event as any Sendable
    }
}

// MARK: - FaePipelineState Tests

final class FaePipelineStateTests: XCTestCase {

    func testAllStatesHaveRawValues() {
        XCTAssertEqual(FaePipelineState.stopped.rawValue, "stopped")
        XCTAssertEqual(FaePipelineState.starting.rawValue, "starting")
        XCTAssertEqual(FaePipelineState.running.rawValue, "running")
        XCTAssertEqual(FaePipelineState.stopping.rawValue, "stopping")
        XCTAssertEqual(FaePipelineState.error.rawValue, "error")
    }

    func testInitFromRawValue() {
        XCTAssertNotNil(FaePipelineState(rawValue: "running"))
        XCTAssertNil(FaePipelineState(rawValue: "invalid"))
    }
}

// MARK: - FaeRuntimeState Tests

final class FaeRuntimeStateTests: XCTestCase {

    func testAllStatesHaveRawValues() {
        XCTAssertEqual(FaeRuntimeState.starting.rawValue, "starting")
        XCTAssertEqual(FaeRuntimeState.started.rawValue, "started")
        XCTAssertEqual(FaeRuntimeState.stopped.rawValue, "stopped")
        XCTAssertEqual(FaeRuntimeState.error.rawValue, "error")
    }

    func testInitFromRawValue() {
        XCTAssertNotNil(FaeRuntimeState(rawValue: "started"))
        XCTAssertNil(FaeRuntimeState(rawValue: "invalid"))
    }
}

// MARK: - FaeTypes Tests

final class FaeTypesTests: XCTestCase {

    func testOrbFeelingCases() {
        let feelings: [OrbFeeling] = [.warmth, .concern, .delight, .curiosity, .calm, .focus, .playful]
        XCTAssertEqual(feelings.count, 7)
        // All unique
        XCTAssertEqual(Set(feelings).count, 7)
    }

    func testSpeakerRoleCases() {
        let roles: [SpeakerRole] = [.owner, .trusted, .guest, .faeSelf]
        XCTAssertEqual(roles.count, 4)
        XCTAssertEqual(SpeakerRole.owner.rawValue, "owner")
        XCTAssertEqual(SpeakerRole.trusted.rawValue, "trusted")
        XCTAssertEqual(SpeakerRole.guest.rawValue, "guest")
        XCTAssertEqual(SpeakerRole.faeSelf.rawValue, "fae_self")
    }

    func testSpeakerRoleCaseIterable() {
        let allRoles = SpeakerRole.allCases
        XCTAssertEqual(allRoles.count, 4)
        XCTAssertTrue(allRoles.contains(.owner))
        XCTAssertTrue(allRoles.contains(.guest))
    }
}
