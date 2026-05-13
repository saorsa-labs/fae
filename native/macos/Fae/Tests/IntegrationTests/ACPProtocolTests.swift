import XCTest
@testable import Fae

final class ACPProtocolTests: XCTestCase {

    // MARK: - ACPContentBlock

    func testACPContentBlockText() {
        let block = ACPContentBlock.text("Hello world")
        XCTAssertEqual(block.type, .text)
        XCTAssertEqual(block.text, "Hello world")
        XCTAssertNil(block.source)
        XCTAssertNil(block.mimeType)
    }

    func testACPContentBlockImage() {
        let block = ACPContentBlock.image(source: "data:image/png;base64,abc123", mimeType: "image/png")
        XCTAssertEqual(block.type, .image)
        XCTAssertNil(block.text)
        XCTAssertEqual(block.source, "data:image/png;base64,abc123")
        XCTAssertEqual(block.mimeType, "image/png")
    }

    func testACPContentBlockImageNoMimeType() {
        let block = ACPContentBlock.image(source: "file.png")
        XCTAssertEqual(block.type, .image)
        XCTAssertNil(block.mimeType)
    }

    func testACPContentBlockJSONObjectText() {
        let block = ACPContentBlock.text("test content")
        let obj = block.jsonObject()
        XCTAssertEqual(obj["type"] as? String, "text")
        XCTAssertEqual(obj["text"] as? String, "test content")
    }

    func testACPContentBlockJSONObjectImage() {
        let block = ACPContentBlock.image(source: "img.png", mimeType: "image/png")
        let obj = block.jsonObject()
        XCTAssertEqual(obj["type"] as? String, "image")
        XCTAssertEqual(obj["source"] as? String, "img.png")
        XCTAssertEqual(obj["mime_type"] as? String, "image/png")
    }

    func testACPContentBlockJSONObjectImageNoMimeType() {
        let block = ACPContentBlock.image(source: "img.png")
        let obj = block.jsonObject()
        XCTAssertNil(obj["mime_type"])
    }

    // MARK: - ACPRequest

    func testACPRequestPromptMethod() {
        let req = ACPRequest.prompt(sessionId: "s1", text: "hello", attachments: [])
        XCTAssertEqual(req.method, "prompt")
    }

    func testACPRequestApproveMethod() {
        let req = ACPRequest.approvePermission(requestId: "r1", approved: true)
        XCTAssertEqual(req.method, "approve_permission")
    }

    func testACPRequestCancelMethod() {
        let req = ACPRequest.cancelTurn(sessionId: "s1")
        XCTAssertEqual(req.method, "cancel_turn")
    }

    func testACPRequestPromptParams() {
        let req = ACPRequest.prompt(sessionId: "s1", text: "hello", attachments: [])
        let params = req.params
        XCTAssertEqual(params["sessionId"] as? String, "s1")
        let content = params["content"] as? [[String: Any]]
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.first?["text"] as? String, "hello")
    }

    func testACPRequestPromptWithAttachments() {
        let attachment = ACPContentBlock.image(source: "img.png", mimeType: "image/png")
        let req = ACPRequest.prompt(sessionId: "s1", text: "describe this", attachments: [attachment])
        let params = req.params
        let content = params["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 2) // text + image
    }

    func testACPRequestApproveParams() {
        let req = ACPRequest.approvePermission(requestId: "r1", approved: true)
        let params = req.params
        XCTAssertEqual(params["requestId"] as? String, "r1")
        XCTAssertEqual(params["approved"] as? Bool, true)
    }

    func testACPRequestJSONRPCObject() {
        let req = ACPRequest.cancelTurn(sessionId: "s1")
        let obj = req.jsonRPCObject(id: "test-id")
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(obj["id"] as? String, "test-id")
        XCTAssertEqual(obj["method"] as? String, "cancel_turn")
    }

    func testACPRequestSerializedData() throws {
        let req = ACPRequest.cancelTurn(sessionId: "s1")
        let data = try req.serializedData(id: "test-id")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["jsonrpc"] as? String, "2.0")
    }

    func testACPRequestSerializedLine() throws {
        let req = ACPRequest.cancelTurn(sessionId: "s1")
        let line = try req.serializedLine(id: "test-id")
        XCTAssertTrue(line.hasSuffix("\n"))
        let jsonStr = String(line.dropLast())
        let data = jsonStr.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
    }

    // MARK: - ACPEventParser — NDJSON events

    private var parser: ACPEventParser { ACPEventParser() }

    func testParseEmptyLine() throws {
        XCTAssertNil(try parser.parse(line: ""))
        XCTAssertNil(try parser.parse(line: "   "))
        XCTAssertNil(try parser.parse(line: "\n"))
    }

    func testParseInvalidJSON() throws {
        XCTAssertNil(try parser.parse(line: "not json at all"))
    }

    func testParseAgentMessageChunk() throws {
        let line = "{\"type\":\"agent_message_chunk\",\"sessionId\":\"s1\",\"content\":\"Hello there\",\"isFinal\":true}"
        guard let event = try parser.parse(line: line) else { XCTFail(); return }
        switch event {
        case .agentMessageChunk(let sid, let content, let isFinal):
            XCTAssertEqual(sid, "s1")
            XCTAssertEqual(content, "Hello there")
            XCTAssertTrue(isFinal)
        default:
            XCTFail("Expected agentMessageChunk")
        }
    }

    func testParseAgentMessageChunkWithSnakeCase() throws {
        let line = "{\"type\":\"agent_message_chunk\",\"session_id\":\"s2\",\"text\":\"Hi\",\"is_final\":false}"
        guard let event = try parser.parse(line: line) else { XCTFail(); return }
        switch event {
        case .agentMessageChunk(let sid, let content, let isFinal):
            XCTAssertEqual(sid, "s2")
            XCTAssertEqual(content, "Hi")
            XCTAssertFalse(isFinal)
        default:
            XCTFail("Expected agentMessageChunk")
        }
    }

    func testParseToolCall() throws {
        let line = "{\"type\":\"tool_call\",\"sessionId\":\"s1\",\"toolName\":\"bash\",\"toolCallId\":\"tc1\",\"input\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}"
        guard let event = try parser.parse(line: line) else { XCTFail(); return }
        switch event {
        case .toolCall(let sid, let name, let callId, _):
            XCTAssertEqual(sid, "s1")
            XCTAssertEqual(name, "bash")
            XCTAssertEqual(callId, "tc1")
        default:
            XCTFail("Expected toolCall")
        }
    }

    func testParseToolUpdate() throws {
        let line = "{\"type\":\"tool_update\",\"sessionId\":\"s1\",\"toolCallId\":\"tc1\",\"output\":\"result\",\"isComplete\":true}"
        guard let event = try parser.parse(line: line) else { XCTFail(); return }
        switch event {
        case .toolUpdate(let sid, let callId, let output, let isComplete):
            XCTAssertEqual(sid, "s1")
            XCTAssertEqual(callId, "tc1")
            XCTAssertEqual(output, "result")
            XCTAssertTrue(isComplete)
        default:
            XCTFail("Expected toolUpdate")
        }
    }

    func testParseToolUpdateWithStatusCompleted() throws {
        let line = "{\"type\":\"tool_update\",\"sessionId\":\"s1\",\"toolCallId\":\"tc1\",\"output\":\"done\",\"status\":\"completed\"}"
        guard let event = try parser.parse(line: line) else { XCTFail(); return }
        switch event {
        case .toolUpdate(_, _, _, let isComplete):
            XCTAssertTrue(isComplete)
        default:
            XCTFail("Expected toolUpdate")
        }
    }

    func testParseRequestPermission() throws {
        let line = "{\"type\":\"request_permission\",\"sessionId\":\"s1\",\"toolName\":\"write\",\"description\":\"Write to file\",\"requestId\":\"req1\"}"
        guard let event = try parser.parse(line: line) else { XCTFail(); return }
        switch event {
        case .requestPermission(let sid, let name, let desc, let reqId):
            XCTAssertEqual(sid, "s1")
            XCTAssertEqual(name, "write")
            XCTAssertEqual(desc, "Write to file")
            XCTAssertEqual(reqId, "req1")
        default:
            XCTFail("Expected requestPermission")
        }
    }

    func testParseSessionComplete() throws {
        let line = "{\"type\":\"session_complete\",\"sessionId\":\"s1\",\"stopReason\":\"end_turn\"}"
        guard let event = try parser.parse(line: line) else { XCTFail(); return }
        switch event {
        case .sessionComplete(let sid, let reason):
            XCTAssertEqual(sid, "s1")
            XCTAssertEqual(reason, "end_turn")
        default:
            XCTFail("Expected sessionComplete")
        }
    }

    func testParseError() throws {
        let line = "{\"type\":\"error\",\"sessionId\":\"s1\",\"code\":500,\"message\":\"Internal error\"}"
        guard let event = try parser.parse(line: line) else { XCTFail(); return }
        switch event {
        case .error(let sid, let code, let msg):
            XCTAssertEqual(sid, "s1")
            XCTAssertEqual(code, 500)
            XCTAssertEqual(msg, "Internal error")
        default:
            XCTFail("Expected error")
        }
    }

    func testParseErrorWithoutSessionId() throws {
        let line = "{\"type\":\"error\",\"code\":400,\"message\":\"Bad request\"}"
        guard let event = try parser.parse(line: line) else { XCTFail(); return }
        switch event {
        case .error(let sid, let code, let msg):
            XCTAssertNil(sid)
            XCTAssertEqual(code, 400)
            XCTAssertEqual(msg, "Bad request")
        default:
            XCTFail("Expected error")
        }
    }

    func testParseUnknownEventType() throws {
        let line = "{\"type\":\"unknown_event\",\"sessionId\":\"s1\"}"
        XCTAssertNil(try parser.parse(line: line))
    }

    // MARK: - ACPEventParser — JSON-RPC events

    func testParseJSONRPCAgentMessageChunk() throws {
        let line = "{\"jsonrpc\":\"2.0\",\"method\":\"agent_message_chunk\",\"params\":{\"sessionId\":\"s1\",\"text\":\"Hello\",\"isFinal\":true}}"
        guard let event = try parser.parse(line: line) else { XCTFail(); return }
        switch event {
        case .agentMessageChunk(let sid, let content, let isFinal):
            XCTAssertEqual(sid, "s1")
            XCTAssertEqual(content, "Hello")
            XCTAssertTrue(isFinal)
        default:
            XCTFail("Expected agentMessageChunk")
        }
    }

    func testParseJSONRPCError() throws {
        let line = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}"
        guard let event = try parser.parse(line: line) else { XCTFail(); return }
        switch event {
        case .error(let sid, let code, let msg):
            XCTAssertNil(sid)
            XCTAssertEqual(code, -32600)
            XCTAssertEqual(msg, "Invalid Request")
        default:
            XCTFail("Expected error")
        }
    }

    func testParseJSONRPCUnknownMethod() throws {
        let line = "{\"jsonrpc\":\"2.0\",\"method\":\"unknown_method\",\"params\":{}}"
        XCTAssertNil(try parser.parse(line: line))
    }

    // MARK: - ACPEvent Equatable

    func testACPEventEquatable() {
        let e1 = ACPEvent.agentMessageChunk(sessionId: "s1", content: "hi", isFinal: true)
        let e2 = ACPEvent.agentMessageChunk(sessionId: "s1", content: "hi", isFinal: true)
        let e3 = ACPEvent.agentMessageChunk(sessionId: "s1", content: "bye", isFinal: false)

        XCTAssertEqual(e1, e2)
        XCTAssertNotEqual(e1, e3)
    }

    // MARK: - ACPProtocolError

    func testACPProtocolErrorDescription() {
        let error: Error = ACPProtocolError.invalidJSONObject
        XCTAssertEqual((error as? ACPProtocolError)?.errorDescription, "ACP request could not be represented as valid JSON.")
    }
}
