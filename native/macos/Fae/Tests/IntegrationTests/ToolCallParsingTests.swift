import XCTest
@testable import Fae

final class ToolCallParsingTests: XCTestCase {

    // MARK: - JSON Tool Calls (Qwen3)

    func testParseJSONToolCall() {
        let text = "Hello <tool_call>{\"name\":\"web_search\",\"arguments\":{\"query\":\"weather\"}}</tool_call> goodbye"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "web_search")
        XCTAssertEqual(calls[0].arguments["query"] as? String, "weather")
    }

    func testParseMultipleJSONToolCalls() {
        let text = "<tool_call>{\"name\":\"read\",\"arguments\":{\"path\":\"/tmp/a\"}}</tool_call> middle <tool_call>{\"name\":\"write\",\"arguments\":{\"path\":\"/tmp/b\"}}</tool_call>"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "read")
        XCTAssertEqual(calls[1].name, "write")
    }

    func testParseJSONToolCallEmptyArgs() {
        let text = "<tool_call>{\"name\":\"bash\"}</tool_call>"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "bash")
        XCTAssertTrue(calls[0].arguments.isEmpty)
    }

    func testParseJSONToolCallNoMatch() {
        let text = "no tool calls here"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - XML Tool Calls (Qwen3.5)

    func testParseXMLToolCall() {
        let text = "<tool_call><function=web_search><parameter=query>weather</parameter></function></tool_call>"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "web_search")
        XCTAssertEqual(calls[0].arguments["query"] as? String, "weather")
    }

    func testParseXMLToolCallMultipleParams() {
        let text = "<tool_call><function=read><parameter>path>/tmp/file</parameter><parameter>lines>10</parameter></function></tool_call>"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments["path"] as? String, "/tmp/file")
    }

    func testParseXMLToolCallJSONValue() {
        let text = "<tool_call><function=test><parameter>count>42</parameter></function></tool_call>"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        // "42" parses as JSON number
        XCTAssertTrue((calls[0].arguments["count"] as? Double) != nil || (calls[0].arguments["count"] as? Int) != nil)
    }

    func testParseXMLToolCallBooleanValue() {
        let text = "<tool_call><function=test><parameter>enabled>true</parameter></function></tool_call>"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].arguments["enabled"] as? Bool == true)
    }

    // MARK: - Gemma Tool Calls

    func testParseGemmaToolCallWithTags() {
        let text = "Hello <|tool_call>call:web_search{query:<|\"|>weather<|\"|>}<tool_call|> goodbye"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "web_search")
        XCTAssertEqual(calls[0].arguments["query"] as? String, "weather")
    }

    func testParseGemmaBareFormat() {
        let text = "call:read{path:/tmp/file}"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read")
    }

    func testParseGemmaLegacyEscape() {
        let text = "call:write{path:<escape>/tmp/file<escape>}"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "write")
    }

    func testParseGemmaMultipleArgs() {
        let text = "call:bash{command:<|\"|>ls<|\"|>,timeout:30}"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments["command"] as? String, "ls")
    }

    // MARK: - Script Block Parsing

    func testParseScriptBlock() {
        let text = "<tool_program>console.log('hello')</tool_program>"
        let blocks = ToolCallParser.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].source.contains("console.log"))
        XCTAssertNil(blocks[0].allowedTools)
    }

    func testParseScriptBlockWithMeta() {
        let text = """
        <tool_program_meta>{"allowed_tools":["read","write"],"max_tool_calls":5}</tool_program_meta>
        <tool_program>const x = 1;</tool_program>
        """
        let blocks = ToolCallParser.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].allowedTools, ["read", "write"])
        XCTAssertNotNil(blocks[0].budget)
    }

    func testParseScriptBlockDryRun() {
        let text = """
        <tool_program_meta>{"dry_run":true}</tool_program_meta>
        <tool_program>test</tool_program>
        """
        let blocks = ToolCallParser.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].dryRun)
    }

    func testParseMultipleScriptBlocks() {
        let text = "<tool_program>code1</tool_program><tool_program>code2</tool_program>"
        let blocks = ToolCallParser.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 2)
    }

    func testParseEmptyScriptBlockSkipped() {
        let text = "<tool_program>   </tool_program>"
        let blocks = ToolCallParser.parseScriptBlocks(from: text)
        XCTAssertTrue(blocks.isEmpty)
    }

    func testParseNoScriptBlocks() {
        let text = "just regular text"
        let blocks = ToolCallParser.parseScriptBlocks(from: text)
        XCTAssertTrue(blocks.isEmpty)
    }

    // MARK: - Markup Stripping

    func testStripQwenMarkup() {
        let result = ToolCallParser.stripToolCallMarkup("Hello <tool_call>{\"name\":\"test\"}</tool_call> World")
        XCTAssertEqual(result, "Hello World")
    }

    func testStripGemmaMarkup() {
        let result = ToolCallParser.stripToolCallMarkup("Hello <|tool_call>call:test{}<tool_call|> World")
        XCTAssertEqual(result, "Hello World")
    }

    func testStripMultipleMarkups() {
        let text = "A <tool_call>{\"name\":\"a\"}</tool_call> B <tool_call>{\"name\":\"b\"}</tool_call> C"
        let result = ToolCallParser.stripToolCallMarkup(text)
        XCTAssertEqual(result, "A B C")
    }

    func testStripUnclosedMarkup() {
        let result = ToolCallParser.stripToolCallMarkup("Hello <tool_call> unclosed")
        XCTAssertEqual(result, "Hello")
    }

    func testStripNoMarkup() {
        let result = ToolCallParser.stripToolCallMarkup("Just plain text")
        XCTAssertEqual(result, "Just plain text")
    }

    // MARK: - Edge Cases

    func testParseEmptyString() {
        let calls = ToolCallParser.parseToolCalls(from: "")
        XCTAssertTrue(calls.isEmpty)
    }

    func testParseMalformedJSON() {
        let text = "<tool_call>{invalid json}</tool_call>"
        let calls = ToolCallParser.parseToolCalls(from: text)
        // Falls through XML parser, which also fails → empty
        XCTAssertTrue(calls.isEmpty)
    }

    func testParseMixedContentWithNoToolCalls() {
        let text = "The weather is nice today. I hope you have a great day!"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertTrue(calls.isEmpty)
    }

    func testParseJSONNestedArguments() {
        let text = "<tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"ls -la\",\"timeout\":30}}</tool_call>"
        let calls = ToolCallParser.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        let args = calls[0].arguments as? [String: Any]
        XCTAssertEqual(args?["command"] as? String, "ls -la")
    }
}
