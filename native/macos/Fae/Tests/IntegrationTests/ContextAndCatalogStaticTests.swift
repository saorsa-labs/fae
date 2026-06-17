import XCTest
@testable import Fae

/// Coverage for two 0%-covered pure-logic files: ToolExecutorContext (pure value
/// struct + restrictedFallback factory + ToolExecutorCallbacks.noop) and
/// LocalModelCatalog (static catalog arrays + cache-status helpers).
final class ContextAndCatalogStaticTests: XCTestCase {

    // MARK: - ToolExecutorContext

    func testRestrictedFallbackHasSafeDefaults() {
        let ctx = ToolExecutorContext.restrictedFallback()
        XCTAssertEqual(ctx.toolMode, "off")
        XCTAssertEqual(ctx.privacyMode, "strict_local")
        XCTAssertEqual(ctx.modelLocality, .local)
        XCTAssertFalse(ctx.explicitUserAuthorization)
        XCTAssertFalse(ctx.isOwner)
        XCTAssertNil(ctx.livenessScore)
        XCTAssertNil(ctx.speakerId)
        XCTAssertEqual(ctx.actionSource, .voice)
        XCTAssertNil(ctx.proactiveContext)
        XCTAssertFalse(ctx.visionEnabled)
        XCTAssertFalse(ctx.firstOwnerEnrollmentActive)
        XCTAssertNil(ctx.workflowTurnID)
        XCTAssertNil(ctx.traceToolCallID)
        XCTAssertNil(ctx.workflowRunID)
    }

    func testContextCanBeConstructedWithAllFields() {
        let ctx = ToolExecutorContext(
            toolMode: "full",
            privacyMode: "local_preferred",
            modelLocality: .nonLocal,
            explicitUserAuthorization: true,
            isOwner: true,
            livenessScore: 0.92,
            speakerId: "spk-1",
            actionSource: .text,
            proactiveContext: nil,
            visionEnabled: true,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: "turn-1",
            traceToolCallID: "tc-1",
            workflowRunID: "run-1"
        )
        XCTAssertEqual(ctx.toolMode, "full")
        XCTAssertEqual(ctx.modelLocality, .nonLocal)
        XCTAssertTrue(ctx.explicitUserAuthorization)
        // Float? has no Double accuracy overload — compare via optional unwrap.
        if let score = ctx.livenessScore {
            XCTAssertEqual(Double(score), 0.92, accuracy: 1e-6)
        } else {
            XCTFail("livenessScore should be 0.92")
        }
        XCTAssertEqual(ctx.speakerId, "spk-1")
        XCTAssertEqual(ctx.actionSource, .text)
        XCTAssertTrue(ctx.visionEnabled)
        XCTAssertEqual(ctx.workflowRunID, "run-1")
    }

    // MARK: - ToolExecutorCallbacks

    func testNoopCallbacksDoNotCrash() async {
        // The noop closures should be callable without side effects.
        let cb = ToolExecutorCallbacks.noop
        await cb.onApprovalPending(true, false)
        await cb.onVisionAutoEnabled()
        let step = await cb.onComputerUseStep()
        XCTAssertEqual(step, 0)
    }

    func testCustomCallbacksFire() async {
        // Actor-isolated box to capture invocations.
        actor Box {
            var approvalCalls = 0
            var visionCalls = 0
            var stepCount = 0
            func approval() { approvalCalls += 1 }
            func vision() { visionCalls += 1 }
            func step() -> Int { stepCount += 1; return stepCount }
            func approvalCount() -> Int { approvalCalls }
            func visionCount() -> Int { visionCalls }
        }
        let box = Box()
        let cb = ToolExecutorCallbacks(
            onApprovalPending: { _, _ in await box.approval() },
            onVisionAutoEnabled: { await box.vision() },
            onComputerUseStep: { await box.step() }
        )
        await cb.onApprovalPending(true, true)
        await cb.onVisionAutoEnabled()
        _ = await cb.onComputerUseStep()
        _ = await cb.onComputerUseStep()
        let approvalCount = await box.approvalCount()
        let visionCount = await box.visionCount()
        XCTAssertEqual(approvalCount, 1)
        XCTAssertEqual(visionCount, 1)
    }

    // MARK: - LocalModelCatalog

    func testVoiceOptionsNonEmptyAndContainAuto() {
        XCTAssertFalse(LocalModelCatalog.voiceOptions.isEmpty)
        let auto = LocalModelCatalog.voiceOptions.first { $0.value == "auto" }
        XCTAssertNotNil(auto)
        XCTAssertEqual(auto?.label, "Auto (Recommended)")
    }

    func testVisionOptionsNonEmptyAndContainAuto() {
        XCTAssertFalse(LocalModelCatalog.visionOptions.isEmpty)
        let auto = LocalModelCatalog.visionOptions.first { $0.value == "auto" }
        XCTAssertNotNil(auto)
    }

    func testVoiceOptionValueUniqueness() {
        let values = LocalModelCatalog.voiceOptions.map(\.value)
        XCTAssertEqual(values.count, Set(values).count, "voice option values should be unique")
    }

    func testVisionOptionValueUniqueness() {
        let values = LocalModelCatalog.visionOptions.map(\.value)
        XCTAssertEqual(values.count, Set(values).count, "vision option values should be unique")
    }

    func testIsModelCachedReturnsBool() {
        // Unknown model id -> false (no matching directory).
        XCTAssertFalse(LocalModelCatalog.isModelCached(modelID: "definitely-not-a-real-model-id-xyz"))
    }
}
