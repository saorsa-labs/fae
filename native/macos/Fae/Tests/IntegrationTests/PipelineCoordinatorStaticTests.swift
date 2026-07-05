import XCTest
@testable import Fae

final class PipelineCoordinatorStaticTests: XCTestCase {

    // MARK: - normalizeForPhraseMatch

    func testNormalizeForPhraseMatch() {
        let normalized = PipelineCoordinator.normalizeForPhraseMatch("  Hello World!  ")
        XCTAssertFalse(normalized.hasPrefix(" "))
        XCTAssertFalse(normalized.hasSuffix(" "))
    }

    func testNormalizeForPhraseMatchEmpty() {
        let normalized = PipelineCoordinator.normalizeForPhraseMatch("")
        XCTAssertTrue(normalized.isEmpty)
    }

    // MARK: - detectExplicitUserAuthorization

    func testDetectExplicitAuthorizationYes() {
        XCTAssertTrue(PipelineCoordinator.detectExplicitUserAuthorization(in: "yes please do it"))
    }

    func testDetectExplicitAuthorizationNo() {
        XCTAssertFalse(PipelineCoordinator.detectExplicitUserAuthorization(in: "just a normal sentence"))
    }

    // MARK: - stripVoiceTagMarkup

    func testStripVoiceTagMarkup() {
        let stripped = PipelineCoordinator.stripVoiceTagMarkup("hello <voice>world</voice>")
        XCTAssertFalse(stripped.contains("<voice>"))
    }

    // MARK: - stripThinkContent

    func testStripThinkContent() {
        let stripped = PipelineCoordinator.stripThinkContent("thinking... answer")
        XCTAssertFalse(stripped.isEmpty)
    }

    // MARK: - workflowTraceSignature

    func testWorkflowTraceSignature() {
        let sig = PipelineCoordinator.workflowTraceSignature(for: ["read", "write", "bash"])
        XCTAssertEqual(sig, "read -> write -> bash")
    }

    func testWorkflowTraceSignatureEmpty() {
        let sig = PipelineCoordinator.workflowTraceSignature(for: [])
        XCTAssertNil(sig)
    }

    func testWorkflowTraceSignatureTrimsAndLowercases() {
        let sig = PipelineCoordinator.workflowTraceSignature(for: [" Read ", " WRITE "])
        XCTAssertEqual(sig, "read -> write")
    }

    // MARK: - estimateTokenCount (delegates to ToolRoutingHelpers)

    func testEstimateTokenCount() {
        let count = PipelineCoordinator.estimateTokenCount(for: "hello world this is a test")
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - inferUserPresentFromCameraOutput (delegates to ToolRoutingHelpers)

    func testInferUserPresentFromCameraOutput() {
        let present = PipelineCoordinator.inferUserPresentFromCameraOutput("person detected")
        XCTAssertNotNil(present)
    }

    // MARK: - contentHash (delegates to ToolRoutingHelpers)

    func testContentHash() {
        let hash = PipelineCoordinator.contentHash("hello world")
        XCTAssertFalse(hash.isEmpty)
    }

    // MARK: - isSafeSkillName (delegates to ToolExecutor)

    func testIsSafeSkillName() {
        XCTAssertTrue(PipelineCoordinator.isSafeSkillName("my-skill"))
    }

    // MARK: - serializeArguments (delegates to ToolRoutingHelpers)

    func testSerializeArguments() {
        let serialized = PipelineCoordinator.serializeArguments(["key": "value"])
        XCTAssertFalse(serialized.isEmpty)
    }

    // MARK: - cloudRouteHint (UX W3)

    private let triggers = ["ask the cloud", "use the cloud"]

    func testCloudRouteHintMatchesAndStripsWhenLanePermits() {
        let r = PipelineCoordinator.cloudRouteHint(
            for: "ask the cloud to research quantum computing",
            triggers: triggers, privacyLane: "all")
        XCTAssertEqual(r.hint, "cloud")
        XCTAssertEqual(r.text, "to research quantum computing")
    }

    func testCloudRouteHintIsCaseInsensitiveAndDropsSeparators() {
        let r = PipelineCoordinator.cloudRouteHint(
            for: "Use The Cloud: what's the weather",
            triggers: triggers, privacyLane: "all")
        XCTAssertEqual(r.hint, "cloud")
        XCTAssertEqual(r.text, "what's the weather")
    }

    func testCloudRouteHintIgnoredWhenLaneIsLocal() {
        // Not configured for cloud ⇒ no hint AND the text is returned untouched
        // (never silently strip words from a local-only user).
        let r = PipelineCoordinator.cloudRouteHint(
            for: "ask the cloud to do X",
            triggers: triggers, privacyLane: "local")
        XCTAssertNil(r.hint)
        XCTAssertEqual(r.text, "ask the cloud to do X")
    }

    func testCloudRouteHintNoMatchLeavesTextUnchanged() {
        let r = PipelineCoordinator.cloudRouteHint(
            for: "what's on my calendar today",
            triggers: triggers, privacyLane: "all")
        XCTAssertNil(r.hint)
        XCTAssertEqual(r.text, "what's on my calendar today")
    }

    func testCloudRouteHintTriggerOnlyYieldsNoHint() {
        // "use the cloud" with nothing after ⇒ no usable prompt ⇒ no hint, and the
        // original text is preserved rather than sending an empty turn.
        let r = PipelineCoordinator.cloudRouteHint(
            for: "use the cloud", triggers: triggers, privacyLane: "all")
        XCTAssertNil(r.hint)
        XCTAssertEqual(r.text, "use the cloud")
    }
}
