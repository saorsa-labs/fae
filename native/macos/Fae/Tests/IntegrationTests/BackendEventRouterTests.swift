import XCTest
@testable import Fae

final class BackendEventRouterTests: XCTestCase {

    private var router: BackendEventRouter!
    private var receivedNotifications: [Notification] = []

    override func setUp() {
        super.setUp()
        router = BackendEventRouter()
        receivedNotifications = []
    }

    override func tearDown() {
        router = nil
        receivedNotifications = []
        super.tearDown()
    }

    private func addObserver(for name: Notification.Name) {
        NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] notification in
            self?.receivedNotifications.append(notification)
        }
    }

    private func postBackendEvent(_ event: String, payload: [String: Any] = [:]) {
        NotificationCenter.default.post(
            name: .faeBackendEvent, object: nil,
            userInfo: ["event": event, "payload": payload]
        )
    }

    // MARK: - Transcription

    func testRoutesTranscription() {
        addObserver(for: .faeTranscription)
        postBackendEvent("pipeline.transcription", payload: ["text": "hello world", "is_final": true])
        XCTAssertEqual(receivedNotifications.count, 1)
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["text"] as? String, "hello world")
        XCTAssertEqual(info["is_final"] as? Bool, true)
    }

    func testTranscriptionDefaults() {
        addObserver(for: .faeTranscription)
        postBackendEvent("pipeline.transcription", payload: [:])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["text"] as? String, "")
        XCTAssertEqual(info["is_final"] as? Bool, false)
    }

    // MARK: - Assistant Messages

    func testRoutesAssistantSentence() {
        addObserver(for: .faeAssistantMessage)
        postBackendEvent("pipeline.assistant_sentence", payload: ["text": "Hello!", "is_final": true])
        XCTAssertEqual(receivedNotifications.count, 1)
    }

    func testRoutesGenerating() {
        addObserver(for: .faeAssistantGenerating)
        postBackendEvent("pipeline.generating", payload: ["active": true])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["active"] as? Bool, true)
    }

    func testRoutesThinkingText() {
        addObserver(for: .faeThinkingText)
        postBackendEvent("pipeline.thinking_text", payload: ["text": "let me think", "is_active": true])
        XCTAssertEqual(receivedNotifications.count, 1)
    }

    // MARK: - Tool Execution

    func testRoutesToolExecuting() {
        addObserver(for: .faeToolExecution)
        postBackendEvent("pipeline.tool_executing", payload: ["name": "web_search"])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["type"] as? String, "executing")
        XCTAssertEqual(info["name"] as? String, "web_search")
    }

    func testRoutesToolCall() {
        addObserver(for: .faeToolExecution)
        postBackendEvent("pipeline.tool_call", payload: ["name": "read", "id": "t1", "input_json": "{}"])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["type"] as? String, "call")
        XCTAssertEqual(info["id"] as? String, "t1")
    }

    func testRoutesToolResult() {
        addObserver(for: .faeToolExecution)
        postBackendEvent("pipeline.tool_result", payload: ["name": "bash", "success": true, "output_text": "done"])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["type"] as? String, "result")
        XCTAssertEqual(info["success"] as? Bool, true)
    }

    // MARK: - Orb State

    func testRoutesOrbStateChanged() {
        addObserver(for: .faeOrbStateChanged)
        postBackendEvent("orb.state_changed", payload: ["mode": "idle", "feeling": "calm"])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["change_type"] as? String, "state_changed")
    }

    func testRoutesOrbPaletteSet() {
        addObserver(for: .faeOrbStateChanged)
        postBackendEvent("orb.palette_set_requested", payload: ["palette": "sunset"])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["change_type"] as? String, "palette_set")
    }

    func testRoutesOrbPaletteCleared() {
        addObserver(for: .faeOrbStateChanged)
        postBackendEvent("orb.palette_cleared", payload: [:])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["change_type"] as? String, "palette_cleared")
    }

    func testRoutesOrbFeelingSet() {
        addObserver(for: .faeOrbStateChanged)
        postBackendEvent("orb.feeling_set_requested", payload: ["feeling": "excited"])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["change_type"] as? String, "feeling_set")
    }

    func testRoutesOrbUrgencySet() {
        addObserver(for: .faeOrbStateChanged)
        postBackendEvent("orb.urgency_set_requested", payload: ["urgency": 0.8])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["change_type"] as? String, "urgency_set")
    }

    func testRoutesOrbFlash() {
        addObserver(for: .faeOrbStateChanged)
        postBackendEvent("orb.flash_requested", payload: ["flash_type": "attention"])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["change_type"] as? String, "flash")
    }

    // MARK: - Audio Level

    func testRoutesAudioLevel() {
        addObserver(for: .faeAudioLevel)
        postBackendEvent("pipeline.audio_level", payload: ["rms": 0.75])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["rms"] as? Double, 0.75)
    }

    // MARK: - Model Loaded

    func testRoutesModelLoaded() {
        addObserver(for: .faeModelLoaded)
        postBackendEvent("pipeline.model_loaded", payload: ["engine": "llm", "model_id": "qwen3-4b"])
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["engine"] as? String, "llm")
    }

    // MARK: - Memory Activity

    func testRoutesMemoryWarning() {
        addObserver(for: .faeMemoryActivity)
        postBackendEvent("pipeline.memory_recall", payload: ["query": "name"])
        XCTAssertEqual(receivedNotifications.count, 1)
    }

    func testRoutesMemoryWrite() {
        addObserver(for: .faeMemoryActivity)
        postBackendEvent("pipeline.memory_write", payload: [:])
        XCTAssertEqual(receivedNotifications.count, 1)
    }

    // MARK: - Capability (JIT Permission)

    func testRoutesCapabilityRequestedWithJit() {
        addObserver(for: .faeCapabilityRequested)
        postBackendEvent("capability.requested", payload: ["jit": true, "capability": "microphone", "reason": "STT"])
        XCTAssertEqual(receivedNotifications.count, 1)
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["capability"] as? String, "microphone")
    }

    func testIgnoresCapabilityWithoutJit() {
        addObserver(for: .faeCapabilityRequested)
        postBackendEvent("capability.requested", payload: ["jit": false, "capability": "microphone"])
        XCTAssertTrue(receivedNotifications.isEmpty)
    }

    // MARK: - Device Handoff

    func testRoutesDeviceTransfer() {
        addObserver(for: .faeDeviceTransfer)
        postBackendEvent("device.transfer_requested", payload: ["target": "other-device"])
        XCTAssertEqual(receivedNotifications.count, 1)
    }

    func testRoutesDeviceHome() {
        addObserver(for: .faeDeviceTransfer)
        postBackendEvent("device.home_requested", payload: [:])
        XCTAssertEqual(receivedNotifications.count, 1)
    }

    // MARK: - Runtime Lifecycle

    func testRoutesRuntimeStarting() {
        addObserver(for: .faeRuntimeState)
        postBackendEvent("runtime.starting", payload: [:])
        XCTAssertEqual(receivedNotifications.count, 1)
    }

    func testRoutesRuntimeError() {
        addObserver(for: .faeRuntimeState)
        postBackendEvent("runtime.error", payload: ["error": "model not found"])
        XCTAssertEqual(receivedNotifications.count, 1)
    }

    func testRoutesRuntimeProgress() {
        addObserver(for: .faeRuntimeProgress)
        postBackendEvent("runtime.progress", payload: ["stage": "download_started"])
        XCTAssertEqual(receivedNotifications.count, 1)
    }

    // MARK: - Pipeline State (default routing)

    func testRoutesPipelineStateEvents() {
        addObserver(for: .faePipelineState)
        postBackendEvent("pipeline.control", payload: ["state": "idle"])
        XCTAssertEqual(receivedNotifications.count, 1)
    }

    func testDropsUnknownEvents() {
        // No observer needed — unknown events are silently dropped
        postBackendEvent("totally.unknown.event", payload: [:])
        XCTAssertTrue(receivedNotifications.isEmpty)
    }

    // MARK: - Edge Cases

    func testRoutesWithMissingPayload() {
        addObserver(for: .faeTranscription)
        NotificationCenter.default.post(
            name: .faeBackendEvent, object: nil,
            userInfo: ["event": "pipeline.transcription"]
        )
        // Should not crash, should use defaults
        let info = receivedNotifications[0].userInfo!
        XCTAssertEqual(info["text"] as? String, "")
    }

    func testRoutesWithMissingEvent() {
        addObserver(for: .faeTranscription)
        NotificationCenter.default.post(
            name: .faeBackendEvent, object: nil,
            userInfo: ["payload": ["text": "hello"]]
        )
        XCTAssertTrue(receivedNotifications.isEmpty) // No event → dropped
    }

    func testRoutesWithNilUserInfo() {
        addObserver(for: .faeTranscription)
        NotificationCenter.default.post(
            name: .faeBackendEvent, object: nil, userInfo: nil
        )
        XCTAssertTrue(receivedNotifications.isEmpty) // No info → dropped
    }
}
