import XCTest
@testable import Fae

final class ThinkAndToolFlowSafetyTests: XCTestCase {

    func testThinkTagStripperRemovesThinkBlock() {
        var stripper = TextProcessing.ThinkTagStripper()

        let a = stripper.process("<think>secret reasoning")
        let b = stripper.process(" still hidden</think>")

        XCTAssertEqual(a, "")
        XCTAssertEqual(b, "")
        XCTAssertTrue(stripper.hasExitedThinkBlock)

        let c = stripper.process(" Final answer.")
        XCTAssertEqual(c, " Final answer.")
    }

    func testStripNonSpeechCharsRemovesThinkAndVoiceTags() {
        let text = "<think>hidden</think><voice character=\"narrator\">Hello</voice> **world**"
        let cleaned = TextProcessing.stripNonSpeechChars(text)

        XCTAssertFalse(cleaned.contains("<think>"))
        XCTAssertFalse(cleaned.contains("</think>"))
        XCTAssertFalse(cleaned.contains("<voice"))
        XCTAssertFalse(cleaned.contains("</voice>"))
        XCTAssertEqual(cleaned, "hiddenHello world")
    }

    func testParseToolCallsSupportsQwen35XmlFormat() {
        let response = """
        Sure — doing it now.
        <tool_call>
        <function=read>
        <parameter=path>/tmp/example.txt</parameter>
        </function>
        </tool_call>
        """

        let calls = PipelineCoordinator.parseToolCalls(from: response)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read")
        XCTAssertEqual(calls[0].arguments["path"] as? String, "/tmp/example.txt")
    }

    func testParseToolCallsSupportsQwenJsonFormat() {
        let response = """
        <tool_call>{"name":"read","arguments":{"path":"/tmp/x.txt"}}</tool_call>
        """

        let calls = PipelineCoordinator.parseToolCalls(from: response)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read")
        XCTAssertEqual(calls[0].arguments["path"] as? String, "/tmp/x.txt")
    }
}
