import XCTest
@testable import Fae

final class ToolRoutingHelpersTests: XCTestCase {

    // MARK: - toolCallAcknowledgement

    func testAckSessionSearch() {
        let call = ToolCall(name: "session_search", arguments: [:])
        let ack = ToolRoutingHelpers.toolCallAcknowledgement(for: [call])
        XCTAssertTrue(ack.contains("earlier conversations"))
    }

    func testAckWebSearch() {
        let call = ToolCall(name: "web_search", arguments: [:])
        let ack = ToolRoutingHelpers.toolCallAcknowledgement(for: [call])
        XCTAssertTrue(ack.contains("check that quickly"))
    }

    func testAckCalendar() {
        let call = ToolCall(name: "calendar", arguments: [:])
        let ack = ToolRoutingHelpers.toolCallAcknowledgement(for: [call])
        XCTAssertTrue(ack.contains("Checking that now"))
    }

    func testAckBash() {
        let call = ToolCall(name: "bash", arguments: [:])
        let ack = ToolRoutingHelpers.toolCallAcknowledgement(for: [call])
        XCTAssertTrue(ack.contains("working on that now"))
    }

    func testAckUnknown() {
        let call = ToolCall(name: "custom_tool", arguments: [:])
        let ack = ToolRoutingHelpers.toolCallAcknowledgement(for: [call])
        XCTAssertTrue(ack.contains("check that for you"))
    }

    func testAckEmpty() {
        let ack = ToolRoutingHelpers.toolCallAcknowledgement(for: [])
        XCTAssertEqual(ack, "")
    }

    // MARK: - stripVoiceTagMarkup

    func testStripVoiceTags() {
        let result = ToolRoutingHelpers.stripVoiceTagMarkup(
            "<voice character=\"en\">Hello world</voice>"
        )
        XCTAssertEqual(result, "Hello world")
    }

    func testStripVoiceTagsNoTags() {
        let result = ToolRoutingHelpers.stripVoiceTagMarkup("Just plain text")
        XCTAssertEqual(result, "Just plain text")
    }

    // MARK: - stripThinkContent

    func testStripThinkContent() {
        let result = ToolRoutingHelpers.stripThinkContent(
            "<think>reasoning here</think> The answer is 42."
        )
        XCTAssertTrue(result.contains("The answer"))
        XCTAssertFalse(result.contains("<think"))
    }

    func testStripThinkContentNoTag() {
        let text = "Just normal text"
        let result = ToolRoutingHelpers.stripThinkContent(text)
        XCTAssertEqual(result, text)
    }

    // MARK: - isReadOnlyDeferredAction

    func testIsReadOnlyCalendarList() {
        let call = ToolCall(name: "calendar", arguments: ["action": "list_today"])
        XCTAssertTrue(ToolRoutingHelpers.isReadOnlyDeferredAction(call))
    }

    func testIsReadOnlyCalendarCreate() {
        let call = ToolCall(name: "calendar", arguments: ["action": "create_event"])
        XCTAssertFalse(ToolRoutingHelpers.isReadOnlyDeferredAction(call))
    }

    func testIsReadOnlySearchTools() {
        let search = ToolCall(name: "web_search", arguments: [:])
        XCTAssertTrue(ToolRoutingHelpers.isReadOnlyDeferredAction(search))

        let fetch = ToolCall(name: "fetch_url", arguments: [:])
        XCTAssertTrue(ToolRoutingHelpers.isReadOnlyDeferredAction(fetch))

        let read = ToolCall(name: "read", arguments: [:])
        XCTAssertTrue(ToolRoutingHelpers.isReadOnlyDeferredAction(read))
    }

    func testIsReadOnlyUnknownTool() {
        let call = ToolCall(name: "unknown_tool", arguments: [:])
        XCTAssertFalse(ToolRoutingHelpers.isReadOnlyDeferredAction(call))
    }

    // MARK: - responseImpliesToolIntent

    func testResponseImpliesToolIntentYes() {
        XCTAssertTrue(ToolRoutingHelpers.responseImpliesToolIntent("Let me check that for you"))
    }

    func testResponseImpliesToolIntentNo() {
        XCTAssertFalse(ToolRoutingHelpers.responseImpliesToolIntent("The weather is nice today."))
    }

    func testResponseImpliesToolIntentTooLong() {
        let longText = String.init(repeating: "word ", count: 100) + "let me check"
        // >400 chars → false
        XCTAssertFalse(ToolRoutingHelpers.responseImpliesToolIntent(longText))
    }

    // MARK: - isCameraIntentRequest

    func testIsCameraIntentYes() {
        XCTAssertTrue(ToolRoutingHelpers.isCameraIntentRequest("can you see me"))
    }

    func testIsCameraIntentNo() {
        XCTAssertFalse(ToolRoutingHelpers.isCameraIntentRequest("the weather is nice"))
    }

    // MARK: - isScreenIntentRequest

    func testIsScreenIntentYes() {
        XCTAssertTrue(ToolRoutingHelpers.isScreenIntentRequest("what's on my screen"))
    }

    func testIsScreenIntentScreenshot() {
        XCTAssertTrue(ToolRoutingHelpers.isScreenIntentRequest("take a screenshot"))
    }

    func testIsScreenIntentNo() {
        XCTAssertFalse(ToolRoutingHelpers.isScreenIntentRequest("hello how are you"))
    }

    // MARK: - extractReferencedAppName

    func testExtractAppNameFinder() {
        let app = ToolRoutingHelpers.extractReferencedAppName(from: "what's open in Finder")
        XCTAssertEqual(app, "Finder")
    }

    func testExtractAppNameNoMatch() {
        let app = ToolRoutingHelpers.extractReferencedAppName(from: "just some text")
        XCTAssertNil(app)
    }

    // MARK: - isToolBackedLookupRequest

    func testIsToolBackedLookupYes() {
        XCTAssertTrue(ToolRoutingHelpers.isToolBackedLookupRequest("what's the weather"))
    }

    func testIsToolBackedLookupNo() {
        XCTAssertFalse(ToolRoutingHelpers.isToolBackedLookupRequest("hello world"))
    }

    // MARK: - shouldSuppressThinking

    func testShouldSuppressThinkingForceOn() {
        XCTAssertTrue(ToolRoutingHelpers.shouldSuppressThinking(
            forceSuppressThinking: true,
            thinkingLevel: .deep,
            isToolFollowUp: false
        ))
    }

    func testShouldSuppressThinkingToolFollowUp() {
        // Tool follow-up keeps thinking enabled
        XCTAssertFalse(ToolRoutingHelpers.shouldSuppressThinking(
            forceSuppressThinking: false,
            thinkingLevel: .fast,
            isToolFollowUp: true
        ))
    }

    func testShouldSuppressThinkingFastMode() {
        XCTAssertTrue(ToolRoutingHelpers.shouldSuppressThinking(
            forceSuppressThinking: false,
            thinkingLevel: .fast,
            isToolFollowUp: false
        ))
    }

    func testShouldSuppressThinkingFullMode() {
        XCTAssertFalse(ToolRoutingHelpers.shouldSuppressThinking(
            forceSuppressThinking: false,
            thinkingLevel: .deep,
            isToolFollowUp: false
        ))
    }

    // MARK: - extractSingleQuotedSegments

    func testExtractQuotedSegments() {
        let segments = ToolRoutingHelpers.extractSingleQuotedSegments(from: "use 'hello world' here")
        XCTAssertFalse(segments.isEmpty)
        XCTAssertEqual(segments[0], "hello world")
    }

    func testExtractQuotedSegmentsNone() {
        let segments = ToolRoutingHelpers.extractSingleQuotedSegments(from: "no quotes here")
        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: - extractPathCandidate

    func testExtractPathCandidate() {
        let path = ToolRoutingHelpers.extractPathCandidate(from: "read /tmp/file.txt")
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasPrefix("/"))
    }

    func testExtractPathCandidateNone() {
        let path = ToolRoutingHelpers.extractPathCandidate(from: "no path here")
        XCTAssertNil(path)
    }

    // MARK: - extractURLCandidate

    func testExtractURLCandidate() {
        let url = ToolRoutingHelpers.extractURLCandidate(from: "check https://example.com")
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.hasPrefix("https://"))
    }

    func testExtractURLCandidateNone() {
        let url = ToolRoutingHelpers.extractURLCandidate(from: "no url here")
        XCTAssertNil(url)
    }

    // MARK: - extractSearchQuery

    func testExtractSearchQuery() {
        let query = ToolRoutingHelpers.extractSearchQuery(from: "search for weather forecast")
        XCTAssertNotNil(query)
    }

    func testExtractSearchQueryNone() {
        let query = ToolRoutingHelpers.extractSearchQuery(from: "just normal text")
        XCTAssertNil(query)
    }

    // MARK: - containsWholeWord

    func testContainsWholeWordYes() {
        XCTAssertTrue(ToolRoutingHelpers.containsWholeWord("hello", in: "say hello world"))
    }

    func testContainsWholeWordNo() {
        XCTAssertFalse(ToolRoutingHelpers.containsWholeWord("hel", in: "hello world"))
    }

    // MARK: - deferredToolAllowlist

    func testDeferredToolAllowlist() {
        XCTAssertTrue(ToolRoutingHelpers.deferredToolAllowlist.contains("calendar"))
        XCTAssertTrue(ToolRoutingHelpers.deferredToolAllowlist.contains("web_search"))
        XCTAssertFalse(ToolRoutingHelpers.deferredToolAllowlist.contains("bash"))
    }

    // MARK: - inlineGroundedToolAllowlist

    func testInlineGroundedToolAllowlist() {
        XCTAssertTrue(ToolRoutingHelpers.inlineGroundedToolAllowlist.contains("calendar"))
        XCTAssertTrue(ToolRoutingHelpers.inlineGroundedToolAllowlist.contains("screenshot"))
        XCTAssertFalse(ToolRoutingHelpers.inlineGroundedToolAllowlist.contains("bash"))
    }

    // MARK: - screenRepairToolCall

    func testScreenRepairToolCallScreenshot() {
        let call = ToolRoutingHelpers.screenRepairToolCall(for: "take a screenshot")
        XCTAssertEqual(call.name, "screenshot")
    }

    func testScreenRepairToolCallDescribeScreen() {
        let call = ToolRoutingHelpers.screenRepairToolCall(for: "what's on my screen")
        // Should return a tool call for the appropriate action
        XCTAssertFalse(call.name.isEmpty)
    }

    // MARK: - repairedToolCallForSkippedTurn

    func testRepairedReadFile() {
        let call = ToolRoutingHelpers.repairedToolCallForSkippedTurn("read /tmp/file.txt")
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.name, "read")
        XCTAssertEqual(call?.arguments["path"] as? String, "/tmp/file.txt")
    }

    func testRepairedWriteFile() {
        let call = ToolRoutingHelpers.repairedToolCallForSkippedTurn("write 'hello world' to /tmp/out.txt")
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.name, "write")
    }

    func testRepairedFetchURL() {
        let call = ToolRoutingHelpers.repairedToolCallForSkippedTurn("fetch https://example.com")
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.name, "fetch_url")
    }

    func testRepairedWebSearch() {
        let call = ToolRoutingHelpers.repairedToolCallForSkippedTurn("search for weather forecast")
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.name, "web_search")
    }

    func testRepairedSelfConfig() {
        let call = ToolRoutingHelpers.repairedToolCallForSkippedTurn("use self_config to get settings")
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.name, "self_config")
    }

    func testRepairedVoiceIdentity() {
        let call = ToolRoutingHelpers.repairedToolCallForSkippedTurn("check voice identity status")
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.name, "voice_identity")
    }

    func testRepairedCameraIntent() {
        let call = ToolRoutingHelpers.repairedToolCallForSkippedTurn("can you see me on camera")
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.name, "camera")
    }

    func testRepairedNoMatch() {
        let call = ToolRoutingHelpers.repairedToolCallForSkippedTurn("just a normal sentence")
        XCTAssertNil(call)
    }



    // MARK: - normalizeSearchRepairQuery

    func testNormalizeSearchQuery() {
        let normalized = ToolRoutingHelpers.normalizeSearchRepairQuery("  What's the weather today?  ")
        XCTAssertFalse(normalized.hasPrefix(" "))
        XCTAssertFalse(normalized.hasSuffix(" "))
    }
}
