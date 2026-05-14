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

    // MARK: - shouldShowCapabilitiesCanvas

    func testShouldShowCapabilitiesCanvasTriggerPhrase() {
        XCTAssertTrue(PipelineCoordinator.shouldShowCapabilitiesCanvas(triggerText: "what can you do", modelResponse: "I can help with many things"))
    }

    func testShouldShowCapabilitiesCanvasTagInResponse() {
        XCTAssertTrue(PipelineCoordinator.shouldShowCapabilitiesCanvas(triggerText: "hello", modelResponse: "here is info <show_capabilities/>"))
    }

    func testShouldShowCapabilitiesCanvasNoMatch() {
        XCTAssertFalse(PipelineCoordinator.shouldShowCapabilitiesCanvas(triggerText: "hello world", modelResponse: "hi there"))
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
}
