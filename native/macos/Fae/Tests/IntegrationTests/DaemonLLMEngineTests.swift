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

    func testPromptBudgetMetricsCountsTextAndTools() throws {
        let specs: [[String: any Sendable]] = [
            [
                "type": "function",
                "function": [
                    "name": "read",
                    "description": "Read a file",
                    "parameters": ["type": "object", "properties": ["path": ["type": "string"]]] as [String: Any],
                ] as [String: Any],
            ]
        ]
        var options = GenerationOptions(maxTokens: 64)
        options.tools = specs
        let payload = DaemonWire.injectTextPayload(
            messages: [LLMMessage(role: .user, content: "hello")],
            systemPrompt: "You are Fae.",
            options: options)

        let metrics = DaemonWire.promptBudgetMetrics(for: payload)
        XCTAssertEqual(metrics.systemChars, "You are Fae.".count)
        XCTAssertEqual(metrics.messageChars, "hello".count)
        XCTAssertEqual(metrics.toolCount, 1)
        XCTAssertGreaterThan(metrics.toolBytes, 0)
        XCTAssertGreaterThan(metrics.payloadBytes, metrics.toolBytes)
        XCTAssertEqual(
            metrics.estimatedTextTokens,
            metrics.estimatedSystemTokens + metrics.estimatedMessageTokens + metrics.estimatedToolTokens
        )
    }

    func testPromptBudgetMetricsReportsZeroForNoTools() {
        let payload = DaemonWire.injectTextPayload(
            messages: [LLMMessage(role: .user, content: "hello")],
            systemPrompt: "You are Fae.",
            options: GenerationOptions(maxTokens: 64)
        )
        let metrics = DaemonWire.promptBudgetMetrics(for: payload)
        XCTAssertEqual(metrics.toolCount, 0)
        XCTAssertEqual(metrics.toolBytes, 0)
        XCTAssertEqual(metrics.estimatedToolTokens, 0)
    }

    func testPromptBudgetWorkingSetReducesGenericToolPayload() throws {
        let registry = ToolRegistry.buildDefault()
        let allTools = try XCTUnwrap(registry.nativeToolSpecs(for: "full"))
        let workingSet = TurnHelpers.fullSchemaToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "hello fae",
            availableToolNames: registry.toolNames,
            proactiveAllowedTools: nil
        )
        let workingTools = try XCTUnwrap(
            registry.nativeToolSpecs(for: "full", limitedTo: workingSet)
        )

        var allOptions = GenerationOptions(maxTokens: 64)
        allOptions.tools = allTools
        let allPayload = DaemonWire.injectTextPayload(
            messages: [LLMMessage(role: .user, content: "hello fae")],
            systemPrompt: "You are Fae.",
            options: allOptions
        )
        var workingOptions = GenerationOptions(maxTokens: 64)
        workingOptions.tools = workingTools
        let workingPayload = DaemonWire.injectTextPayload(
            messages: [LLMMessage(role: .user, content: "hello fae")],
            systemPrompt: "You are Fae.",
            options: workingOptions
        )

        let allMetrics = DaemonWire.promptBudgetMetrics(for: allPayload)
        let workingMetrics = DaemonWire.promptBudgetMetrics(for: workingPayload)
        NSLog(
            "PromptBudgetTest: generic all_tools=%d all_tool_tokens=%d working_tools=%d working_tool_tokens=%d reduction_tokens=%d",
            allMetrics.toolCount,
            allMetrics.estimatedToolTokens,
            workingMetrics.toolCount,
            workingMetrics.estimatedToolTokens,
            allMetrics.estimatedToolTokens - workingMetrics.estimatedToolTokens
        )
        XCTAssertLessThan(workingMetrics.toolCount, allMetrics.toolCount)
        XCTAssertLessThan(workingMetrics.estimatedToolTokens, allMetrics.estimatedToolTokens)
    }

    func testDaemonToolsSkipsSpecsWithoutNames() {
        let specs: [[String: any Sendable]] = [
            ["type": "function", "function": ["description": "nameless"] as [String: Any]]
        ]
        XCTAssertTrue(DaemonWire.daemonTools(from: specs).isEmpty)
    }

    // MARK: injectTextPayload — audio (S18 push-to-talk)

    func testInjectTextPayloadAttachesAudioWithEmptyContent() throws {
        // Empirical daemon contract (docs/spikes/S18): the audio user message
        // must carry EMPTY content — any text out-competes the audio and gets
        // transcribed instead — and the turn-context prefix migrates to the
        // system prompt so memory recall still reaches the model.
        let messages = [
            LLMMessage(role: .assistant, content: "earlier reply"),
            LLMMessage(role: .user, content: "(voice message)"),
        ]
        var options = GenerationOptions(maxTokens: 256)
        options.turnContextPrefix = "[context: morning]"
        options.audioWAVBase64 = "QkFTRTY0"

        let payload = DaemonWire.injectTextPayload(
            messages: messages, systemPrompt: "You are Fae.", options: options)

        let wire = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(wire.count, 2)
        XCTAssertEqual(wire[1]["content"] as? String, "")
        XCTAssertEqual(wire[1]["audio_wav_base64"] as? String, "QkFTRTY0")
        XCTAssertNil(wire[0]["audio_wav_base64"], "audio attaches to the final user message only")
        let system = try XCTUnwrap(payload["system"] as? String)
        XCTAssertTrue(system.contains("[context: morning]"))
    }

    func testInjectTextPayloadWithoutAudioIsUnchanged() throws {
        // Text turns must stay byte-identical to the pre-S18 shape.
        let payload = DaemonWire.injectTextPayload(
            messages: [LLMMessage(role: .user, content: "hello")],
            systemPrompt: "You are Fae.",
            options: GenerationOptions(maxTokens: 64))
        let wire = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(wire[0]["content"] as? String, "hello")
        XCTAssertNil(wire[0]["audio_wav_base64"])
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

    func testParseStartupPathsStripsTrailingAnnotations() {
        // The daemon's real startup lines carry parenthesised annotations that
        // are NOT part of the path — and the paths contain spaces
        // ("Application Support"), so only a trailing group may be stripped.
        // Regression: the un-stripped " (0700)" poisoned the socket path and
        // the engine polled a nonexistent file for the full 600 s timeout.
        let lines = [
            "run dir : /Users/x/Library/Application Support/fae/run (0700)",
            "token   : /Users/x/Library/Application Support/fae/run/bootstrap.token (0600)",
            "fae-daemon: listening on /Users/x/Library/Application Support/fae/run/fae-daemon.sock (NDJSON)",
        ]
        let paths = DaemonWire.parseStartupPaths(lines: lines)
        XCTAssertEqual(paths.runDir, "/Users/x/Library/Application Support/fae/run")
        XCTAssertEqual(
            paths.tokenPath,
            "/Users/x/Library/Application Support/fae/run/bootstrap.token")
        XCTAssertEqual(
            paths.socketPath,
            "/Users/x/Library/Application Support/fae/run/fae-daemon.sock")
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

// MARK: - Audio two-pass helpers (S18)

/// The two-pass audio turn synthesises the `[heard]:` line itself from a
/// dedicated transcription pass, because Gemma 4 routes audio comprehension into
/// reasoning/tool-call markup the adapter drops (diagnosed 2026-06-15). These
/// pure helpers guard the contract the pipeline depends on: a SINGLE-LINE
/// `[heard]:` transcript followed by the spoken answer.
final class DaemonAudioTwoPassTests: XCTestCase {

    // MARK: flattenTranscript

    func testFlattenTranscriptCollapsesNewlinesToOneLine() {
        // HeardLineParser ends the `[heard]:` line at the first newline, so a
        // multi-sentence transcript MUST be one line or its tail leaks into the
        // spoken answer.
        let result = DaemonLLMEngine.flattenTranscript("What is the\ncapital of\nFrance?")
        XCTAssertEqual(result, "What is the capital of France?")
        XCTAssertFalse(result.contains("\n"))
    }

    func testFlattenTranscriptStripsStrayLeadingHeardLabel() {
        // If the transcription model echoes a `[heard]:` label we must not
        // double it when combineHeard prepends the authoritative one.
        let result = DaemonLLMEngine.flattenTranscript("[heard]: hello there")
        XCTAssertEqual(result, "hello there")
    }

    func testFlattenTranscriptTrimsWhitespace() {
        XCTAssertEqual(DaemonLLMEngine.flattenTranscript("  hi  "), "hi")
        XCTAssertEqual(DaemonLLMEngine.flattenTranscript(""), "")
    }

    // MARK: combineHeard

    func testCombineHeardPrependsTranscriptThenAnswer() {
        let combined = DaemonLLMEngine.combineHeard(
            transcript: "what time is it", answer: "It's 3 PM.")
        XCTAssertEqual(combined, "[heard]: what time is it\nIt's 3 PM.")
    }

    func testCombineHeardDedupesRedundantHeardLineFromAnswer() {
        // The reasoning pass may re-emit its own `[heard]:` line; the authoritative
        // transcript (pass 1) must win and the echo must be dropped.
        let combined = DaemonLLMEngine.combineHeard(
            transcript: "play jazz", answer: "[heard]: play jazz\nPlaying jazz now.")
        XCTAssertEqual(combined, "[heard]: play jazz\nPlaying jazz now.")
    }

    func testCombineHeardEmptyAnswerYieldsHeardLineOnly() {
        // A pure tool-call turn has no spoken text — the pipeline still needs the
        // transcript line so the turn is captured and displayed.
        let combined = DaemonLLMEngine.combineHeard(transcript: "open mail", answer: "")
        XCTAssertEqual(combined, "[heard]: open mail")
    }

    // MARK: strippingHeardInstruction

    func testStrippingHeardInstructionRemovesContractBlock() {
        let prompt =
            "You are Fae.\n\nThe user's message arrives as audio. Begin EVERY reply with [heard]:."
        XCTAssertEqual(DaemonLLMEngine.strippingHeardInstruction(prompt), "You are Fae.")
    }

    func testStrippingHeardInstructionIsNoOpWhenMarkerAbsent() {
        let prompt = "You are Fae. Be concise."
        XCTAssertEqual(DaemonLLMEngine.strippingHeardInstruction(prompt), prompt)
    }

    // MARK: replacingFinalUserContent

    func testReplacingFinalUserContentSwapsLastUserMessage() {
        let messages = [
            LLMMessage(role: .user, content: "old"),
            LLMMessage(role: .assistant, content: "reply"),
            LLMMessage(role: .user, content: ""),
        ]
        let result = DaemonLLMEngine.replacingFinalUserContent(messages, with: "transcript")
        XCTAssertEqual(result[2].content, "transcript")
        XCTAssertEqual(result[0].content, "old")  // earlier user turn untouched
        XCTAssertEqual(result[1].content, "reply")
    }

    func testReplacingFinalUserContentAppendsWhenNoUserMessage() {
        let messages = [LLMMessage(role: .system, content: "sys")]
        let result = DaemonLLMEngine.replacingFinalUserContent(messages, with: "transcript")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.last?.role, .user)
        XCTAssertEqual(result.last?.content, "transcript")
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

    func testUseDaemonEngineDefaultsOn() {
        // The daemon is the PRIMARY LLM lane (daemon-default, 2026-06-13):
        // a fresh install with no config.toml must route turns to the bundled
        // fae-daemon. No binary path is required — resolution falls back to
        // the daemon embedded in the app bundle.
        let config = FaeConfig()
        XCTAssertTrue(config.llm.useDaemonEngine)
        XCTAssertNil(config.llm.daemonBinaryPath)
    }
}
