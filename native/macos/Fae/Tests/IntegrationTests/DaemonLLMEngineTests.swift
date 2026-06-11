import XCTest

@testable import Fae

// MARK: - DaemonWire Tests (pure NDJSON protocol helpers)
//
// These verify the bridge between the pipeline's LLMEngine contract and the
// fae-daemon NDJSON protocol (v2): frame encoding, response unwrapping, tool
// spec flattening, tool-call argument decoding, and startup stdout parsing.
// The contract matters because the daemon is non-streaming and speaks a
// different tool shape than MLX — a silent mismatch here would corrupt turns.

final class DaemonWireTests: XCTestCase {

    // MARK: encodeFrame

    func testEncodeFrameProducesSingleNDJSONLine() throws {
        let data = try DaemonWire.encodeFrame(
            requestID: "r1",
            command: "session.authenticate",
            payload: ["client_id": "swift-frontend-bootstrap", "token": "abc"]
        )
        // Exactly one trailing newline, none embedded.
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 2)
        XCTAssertEqual(object["request_id"] as? String, "r1")
        XCTAssertEqual(object["command"] as? String, "session.authenticate")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["token"] as? String, "abc")
    }

    func testEncodeFrameRejectsNonJSONPayload() {
        XCTAssertThrowsError(
            try DaemonWire.encodeFrame(
                requestID: "r1", command: "x", payload: ["bad": Date()]))
    }

    // MARK: unwrapResponse

    func testUnwrapResponseAcceptsOkTrue() throws {
        let object: [String: Any] = ["ok": true, "result": ["text": "hi"]]
        let unwrapped = try DaemonWire.unwrapResponse(object)
        XCTAssertNotNil(unwrapped["result"])
    }

    func testUnwrapResponseThrowsOnOkFalseWithMessage() {
        let object: [String: Any] = ["ok": false, "error": "model not loaded"]
        XCTAssertThrowsError(try DaemonWire.unwrapResponse(object)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("model not loaded"),
                "daemon error message must survive unwrapping for loud failures")
        }
    }

    // MARK: injectTextPayload

    func testInjectTextPayloadMapsMessagesAndOptions() throws {
        let messages = [
            LLMMessage(role: .user, content: "hello"),
            LLMMessage(role: .assistant, content: "hi there"),
            LLMMessage(role: .user, content: "what time is it?"),
        ]
        var options = GenerationOptions(maxTokens: 512)
        options.turnContextPrefix = "[context: morning]"

        let payload = DaemonWire.injectTextPayload(
            messages: messages, systemPrompt: "You are Fae.", options: options)

        XCTAssertEqual(payload["system"] as? String, "You are Fae.")
        XCTAssertEqual(payload["max_tokens"] as? Int, 512)
        let wire = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(wire.count, 3)
        XCTAssertEqual(wire[0]["role"] as? String, "user")
        XCTAssertEqual(wire[0]["content"] as? String, "hello")
        XCTAssertEqual(wire[1]["role"] as? String, "assistant")
        // turnContextPrefix attaches to the LAST user message only — it is
        // per-turn ephemeral context, mirroring the MLX delta semantics.
        XCTAssertEqual(
            wire[2]["content"] as? String, "[context: morning]\n\nwhat time is it?")
        XCTAssertNil(payload["tools"], "no tools key when no tools are supplied")
    }

    func testInjectTextPayloadFlattensMLXToolSpecs() throws {
        let specs: [[String: any Sendable]] = [
            [
                "type": "function",
                "function": [
                    "name": "web_search",
                    "description": "Search the web",
                    "parameters": ["type": "object"] as [String: Any],
                ] as [String: Any],
            ]
        ]
        var options = GenerationOptions(maxTokens: 64)
        options.tools = specs

        let payload = DaemonWire.injectTextPayload(
            messages: [LLMMessage(role: .user, content: "go")],
            systemPrompt: "",
            options: options)

        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "web_search")
        XCTAssertEqual(tools[0]["description"] as? String, "Search the web")
        XCTAssertEqual((tools[0]["parameters"] as? [String: Any])?["type"] as? String, "object")
    }

    func testDaemonToolsSkipsSpecsWithoutNames() {
        let specs: [[String: any Sendable]] = [
            ["type": "function", "function": ["description": "nameless"] as [String: Any]]
        ]
        XCTAssertTrue(DaemonWire.daemonTools(from: specs).isEmpty)
    }

    // MARK: parseTurn

    func testParseTurnExtractsTextAndToolCalls() {
        let response: [String: Any] = [
            "ok": true,
            "result": [
                "text": "Checking now.",
                "tool_calls": [
                    ["name": "calendar", "arguments": "{\"action\":\"list\",\"limit\":3}"]
                ],
                "finish_reason": "stop",
            ] as [String: Any],
        ]
        let turn = DaemonWire.parseTurn(from: response)
        XCTAssertEqual(turn.text, "Checking now.")
        XCTAssertEqual(turn.finishReason, "stop")
        XCTAssertEqual(turn.toolCalls.count, 1)
        XCTAssertEqual(turn.toolCalls[0].name, "calendar")
        XCTAssertEqual(turn.toolCalls[0].arguments["action"] as? String, "list")
        XCTAssertEqual(turn.toolCalls[0].arguments["limit"] as? Int, 3)
    }

    func testParseTurnToleratesMissingFields() {
        let turn = DaemonWire.parseTurn(from: ["ok": true])
        XCTAssertEqual(turn.text, "")
        XCTAssertTrue(turn.toolCalls.isEmpty)
        XCTAssertNil(turn.finishReason)
    }

    // MARK: parseToolArguments

    func testParseToolArgumentsDecodesJSONString() {
        let args = DaemonWire.parseToolArguments("{\"q\":\"weather\",\"deep\":true}")
        XCTAssertEqual(args["q"] as? String, "weather")
        XCTAssertEqual(args["deep"] as? Bool, true)
    }

    func testParseToolArgumentsPreservesUndecodableStringUnderRawKey() {
        // A garbled arguments string must not be silently dropped — the tool
        // layer can still surface it for repair.
        let args = DaemonWire.parseToolArguments("not json at all")
        XCTAssertEqual(args["raw"] as? String, "not json at all")
    }

    func testParseToolArgumentsHandlesNilAndEmpty() {
        XCTAssertTrue(DaemonWire.parseToolArguments(nil).isEmpty)
        XCTAssertTrue(DaemonWire.parseToolArguments("   ").isEmpty)
    }

    // MARK: parseStartupPaths

    func testParseStartupPathsReadsDaemonAnnouncements() {
        let lines = [
            "fae-daemon v0.1.0",
            "run dir : /Users/x/.local/share/fae/run",
            "token   : /Users/x/.local/share/fae/run/bootstrap.token",
            "listening on /Users/x/.local/share/fae/run/fae-daemon.sock",
        ]
        let paths = DaemonWire.parseStartupPaths(lines: lines)
        XCTAssertEqual(paths.runDir, "/Users/x/.local/share/fae/run")
        XCTAssertEqual(paths.tokenPath, "/Users/x/.local/share/fae/run/bootstrap.token")
        XCTAssertEqual(paths.socketPath, "/Users/x/.local/share/fae/run/fae-daemon.sock")
    }

    func testParseStartupPathsReturnsNilsForUnrelatedOutput() {
        let paths = DaemonWire.parseStartupPaths(lines: ["loading model...", "warmup done"])
        XCTAssertNil(paths.runDir)
        XCTAssertNil(paths.tokenPath)
        XCTAssertNil(paths.socketPath)
    }

    // MARK: parseObjectLine

    func testParseObjectLineRejectsNonObjects() {
        XCTAssertNil(DaemonWire.parseObjectLine(""))
        XCTAssertNil(DaemonWire.parseObjectLine("[1,2,3]"))
        XCTAssertNotNil(DaemonWire.parseObjectLine("{\"ok\":true}"))
    }
}

// MARK: - Config mapping

final class DaemonLLMConfigTests: XCTestCase {
    func testDaemonModelIdMapsToGemma4E4B() {
        // The daemon lane currently serves Gemma 4 E4B for every preset —
        // mistral.rs loads its own weights independent of the MLX catalogue.
        XCTAssertEqual(FaeConfig.daemonModelId(preset: "auto"), "google/gemma-4-E4B-it")
        XCTAssertEqual(FaeConfig.daemonModelId(preset: "qwen3_5_4b"), "google/gemma-4-E4B-it")
    }

    func testUseDaemonEngineDefaultsOff() {
        let config = FaeConfig()
        XCTAssertFalse(config.llm.useDaemonEngine)
        XCTAssertNil(config.llm.daemonBinaryPath)
    }
}
