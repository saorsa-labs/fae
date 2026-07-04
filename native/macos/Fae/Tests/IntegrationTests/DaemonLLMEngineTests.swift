import Foundation
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

    // MARK: injectTextPayload — pinned summary (Phase G2)

    func testInjectTextPayloadAttachesPinnedSummaryWhenCached() throws {
        // When the caller has a cached pinned summary it rides the payload as
        // `pinned_summary`; the daemon folds it into the stable system prefix.
        var options = GenerationOptions(maxTokens: 128)
        options.pinnedSummary = "Earlier: user booked the 9am ferry to Skye."

        let payload = DaemonWire.injectTextPayload(
            messages: [LLMMessage(role: .user, content: "and the price?")],
            systemPrompt: "You are Fae.",
            options: options)

        XCTAssertEqual(
            payload["pinned_summary"] as? String,
            "Earlier: user booked the 9am ferry to Skye.")
        // The kept turns and system are untouched by pinning.
        XCTAssertEqual(payload["system"] as? String, "You are Fae.")
        let wire = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(wire[0]["content"] as? String, "and the price?")
    }

    func testInjectTextPayloadOmitsPinnedSummaryWhenAbsentOrBlank() throws {
        // No cached summary ⇒ no key at all (byte-identical to today's payload).
        let none = DaemonWire.injectTextPayload(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: "You are Fae.",
            options: GenerationOptions(maxTokens: 64))
        XCTAssertNil(none["pinned_summary"], "no key when the caller has no summary")

        // An all-whitespace summary is treated as absent — never a dangling key.
        var blankOptions = GenerationOptions(maxTokens: 64)
        blankOptions.pinnedSummary = "   \n  "
        let blank = DaemonWire.injectTextPayload(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: "You are Fae.",
            options: blankOptions)
        XCTAssertNil(blank["pinned_summary"], "blank summary omits the key")
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

    // MARK: adapter command frames (P3/C3)
    //
    // `reloadAdapter`/`setAdapterScale` build their frames through
    // `DaemonWire.encodeFrame`; these verify the exact wire shape the daemon's
    // `engine.reload` / `engine.set_adapter_scale` dispatch reads. A drift here
    // (wrong key, wrong null encoding) would be silently denied or mis-parsed.

    func testEngineReloadFrameCarriesPersonalAdapterPath() throws {
        let data = try DaemonWire.encodeFrame(
            requestID: "r7",
            command: "engine.reload",
            payload: ["personal_adapter": "/models/personal/p.gguf"])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        XCTAssertEqual(object["command"] as? String, "engine.reload")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["personal_adapter"] as? String, "/models/personal/p.gguf")
    }

    func testEngineReloadFrameEncodesNullForBaseReload() throws {
        // Base reload sends an explicit JSON null — the daemon reads
        // `personal_adapter.as_str()` (null ⇒ base). `NSNull` is required; a
        // Swift `nil as Any` would fail `isValidJSONObject` and never serialize.
        let data = try DaemonWire.encodeFrame(
            requestID: "r8",
            command: "engine.reload",
            payload: ["personal_adapter": NSNull()])
        let line = try XCTUnwrap(String(data: data.dropLast(), encoding: .utf8))
        XCTAssertTrue(line.contains("\"personal_adapter\":null"),
                      "base reload must serialize an explicit null, got: \(line)")
    }

    func testEngineSetAdapterScaleFrameCarriesScale() throws {
        let data = try DaemonWire.encodeFrame(
            requestID: "r9",
            command: "engine.set_adapter_scale",
            payload: ["scale": Double(Float(1.0))])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        XCTAssertEqual(object["command"] as? String, "engine.set_adapter_scale")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual((payload["scale"] as? NSNumber)?.doubleValue, 1.0)
    }

    func testAdapterCommandFailedErrorIsLoud() {
        let error = DaemonLLMEngineError.adapterCommandFailed(
            command: "engine.reload", code: "authorization denied")
        let description = error.localizedDescription
        XCTAssertTrue(description.contains("engine.reload"))
        XCTAssertTrue(description.contains("authorization denied"))
    }
}

// MARK: - Audio two-pass helpers (S18)

/// The two-pass audio turn synthesises the `[heard]:` line itself from a
/// dedicated transcription pass, because Gemma 4 routes audio comprehension into
/// reasoning/tool-call markup the adapter drops (diagnosed 2026-06-15). These
/// pure helpers guard the contract the pipeline depends on: a SINGLE-LINE
/// `[heard]:` transcript followed by the spoken answer.
final class DaemonAudioTwoPassTests: XCTestCase {

    private struct StaticAudioFallbackTranscriber: AudioFallbackTranscribing {
        let transcript: String?

        func transcribe(audioWAVBase64: String) async -> String? {
            transcript
        }
    }

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

    // MARK: degraded audio quality gate

    func testAudioTranscriptQualityAcceptsShortCommands() {
        XCTAssertTrue(DaemonLLMEngine.assessAudioTranscript("yes").isUsable)
        XCTAssertTrue(DaemonLLMEngine.assessAudioTranscript("no").isUsable)
        XCTAssertTrue(DaemonLLMEngine.assessAudioTranscript("stop").isUsable)
        XCTAssertTrue(DaemonLLMEngine.assessAudioTranscript("Spell it F A E").isUsable)
    }

    func testAudioTranscriptQualityRejectsEmptyAndNoSpeechMarkers() {
        XCTAssertFalse(DaemonLLMEngine.assessAudioTranscript("").isUsable)
        XCTAssertFalse(DaemonLLMEngine.assessAudioTranscript("[inaudible]").isUsable)
        XCTAssertFalse(DaemonLLMEngine.assessAudioTranscript("I can't transcribe the audio").isUsable)
    }

    func testAudioTranscriptQualityRejectsMarkupAndRepeatedGarbage() {
        XCTAssertFalse(DaemonLLMEngine.assessAudioTranscript("<think>I should call a tool</think>").isUsable)
        XCTAssertFalse(DaemonLLMEngine.assessAudioTranscript("la la la la la la").isUsable)
        XCTAssertFalse(DaemonLLMEngine.assessAudioTranscript("@@@ ### ???").isUsable)
        XCTAssertFalse(DaemonLLMEngine.assessAudioTranscript("स्टार्ट").isUsable)
        XCTAssertFalse(DaemonLLMEngine.assessAudioTranscript("sto").isUsable)
    }

    func testAudioTranscriptRunawayGateScalesWithClipDuration() {
        // A legitimate 25-30s PTT capture transcribes to ~390-480 chars. With
        // the duration threaded through, a 30s clip must accept it; without a
        // duration (short-clip default) the same length still trips the runaway
        // gate at the 300-char floor.
        let longUtterance = "I was thinking that we could go over the quarterly plans "
            + "together tomorrow morning and then maybe grab some lunch somewhere downtown "
            + "before our afternoon meeting with the design team, because they really wanted "
            + "to talk through the new onboarding flow and the small changes to the settings "
            + "screen that we first discussed last week during our sync about roadmap priorities."
        XCTAssertGreaterThan(longUtterance.count, 300)
        XCTAssertTrue(
            DaemonLLMEngine.assessAudioTranscript(longUtterance, durationSeconds: 30).isUsable)
        let shortClip = DaemonLLMEngine.assessAudioTranscript(longUtterance, durationSeconds: 2)
        XCTAssertFalse(shortClip.isUsable)
        XCTAssertEqual(shortClip.reason, "runaway_transcript")
        // No duration keeps the 300-char floor (backward compatible).
        XCTAssertFalse(DaemonLLMEngine.assessAudioTranscript(longUtterance).isUsable)
    }

    func testAudioFallbackTriggersOnQualityFailure() {
        let quality = DaemonLLMEngine.assessAudioTranscript("sto")
        XCTAssertTrue(DaemonLLMEngine.shouldAttemptAudioFallback(
            transcript: "sto", quality: quality, mode: .qualityFail))
    }

    func testAudioFallbackFragileModeCoversShortAndDictationCases() {
        XCTAssertTrue(DaemonLLMEngine.shouldAttemptAudioFallback(
            transcript: "Stap",
            quality: DaemonLLMEngine.assessAudioTranscript("Stap"),
            mode: .fragile))
        XCTAssertTrue(DaemonLLMEngine.shouldAttemptAudioFallback(
            transcript: "The number is 415236",
            quality: DaemonLLMEngine.assessAudioTranscript("The number is 415236"),
            mode: .fragile))
        XCTAssertTrue(DaemonLLMEngine.shouldAttemptAudioFallback(
            transcript: "call ser",
            quality: DaemonLLMEngine.assessAudioTranscript("call ser"),
            mode: .fragile))
        XCTAssertFalse(DaemonLLMEngine.shouldAttemptAudioFallback(
            transcript: "Open the terminal and run git status",
            quality: DaemonLLMEngine.assessAudioTranscript("Open the terminal and run git status"),
            mode: .fragile))
    }

    func testResolveAudioTranscriptUsesFallbackWhenPrimaryFailsGate() async {
        let engine = DaemonLLMEngine(
            binaryPath: nil,
            modelID: "test",
            audioFallbackTranscriber: StaticAudioFallbackTranscriber(transcript: "Stop"),
            audioFallbackMode: .qualityFail)
        let result = await engine.resolveAudioTranscript(
            primaryTranscript: "sto",
            primaryQuality: DaemonLLMEngine.assessAudioTranscript("sto"),
            audioWAVBase64: "ZmFrZS13YXY=")
        XCTAssertEqual(result, "Stop")
    }

    func testResolveAudioTranscriptFailsClosedWhenFallbackBad() async {
        let engine = DaemonLLMEngine(
            binaryPath: nil,
            modelID: "test",
            audioFallbackTranscriber: StaticAudioFallbackTranscriber(transcript: ""),
            audioFallbackMode: .qualityFail)
        let result = await engine.resolveAudioTranscript(
            primaryTranscript: "sto",
            primaryQuality: DaemonLLMEngine.assessAudioTranscript("sto"),
            audioWAVBase64: "ZmFrZS13YXY=")
        XCTAssertEqual(result, "sto")
    }

    func testAudioFallbackConfigRequiresLockedBinaryArtifactID() throws {
        let (dir, binary, lock) = try makeFallbackFixture(binarySHA: "abc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = AudioFallbackTranscriberConfig.fromEnvironment([
            "FAE_AUDIO_FALLBACK_BIN": binary.path,
            "FAE_AUDIO_FALLBACK_LOCK": lock.path,
        ])
        XCTAssertNil(config)
    }

    func testAudioFallbackConfigRejectsBinaryHashMismatch() throws {
        let (dir, binary, lock) = try makeFallbackFixture(binarySHA: "0000")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = AudioFallbackTranscriberConfig.fromEnvironment([
            "FAE_AUDIO_FALLBACK_BIN": binary.path,
            "FAE_AUDIO_FALLBACK_BIN_ARTIFACT_ID": "test-whisper-bin",
            "FAE_AUDIO_FALLBACK_LOCK": lock.path,
        ])
        XCTAssertNil(config)
    }

    func testAudioFallbackConfigRejectsModelWithoutLockedArtifactID() throws {
        let (dir, binary, lock) = try makeFallbackFixture()
        let model = dir.appendingPathComponent("model.bin")
        try Data("model".utf8).write(to: model)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = AudioFallbackTranscriberConfig.fromEnvironment([
            "FAE_AUDIO_FALLBACK_BIN": binary.path,
            "FAE_AUDIO_FALLBACK_BIN_ARTIFACT_ID": "test-whisper-bin",
            "FAE_AUDIO_FALLBACK_MODEL": model.path,
            "FAE_AUDIO_FALLBACK_LOCK": lock.path,
        ])
        XCTAssertNil(config)
    }

    func testAudioFallbackConfigAcceptsLockedBinaryAndModel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-fallback-test-")
            .appendingPathExtension(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = try writeExecutableFixture(in: dir)
        let model = dir.appendingPathComponent("model.bin")
        try Data("model".utf8).write(to: model)
        let binarySHA = try ExternalProcessAudioFallbackTranscriber.sha256Hex(of: binary)
        let modelSHA = try ExternalProcessAudioFallbackTranscriber.sha256Hex(of: model)
        let lock = dir.appendingPathComponent("models.lock")
        try lockText(binarySHA: binarySHA, modelSHA: modelSHA).write(to: lock, atomically: true, encoding: .utf8)

        let config = try XCTUnwrap(AudioFallbackTranscriberConfig.fromEnvironment([
            "FAE_AUDIO_FALLBACK_BIN": binary.path,
            "FAE_AUDIO_FALLBACK_BIN_ARTIFACT_ID": "test-whisper-bin",
            "FAE_AUDIO_FALLBACK_MODEL": model.path,
            "FAE_AUDIO_FALLBACK_MODEL_ARTIFACT_ID": "test-whisper-model",
            "FAE_AUDIO_FALLBACK_LOCK": lock.path,
        ]))
        XCTAssertEqual(config.binaryArtifactID, "test-whisper-bin")
        XCTAssertEqual(config.modelArtifactID, "test-whisper-model")
        XCTAssertEqual(config.argumentTemplate, ["-m", "{model}", "-f", "{wav}", "-nt", "-np"])
    }

    private func makeFallbackFixture(binarySHA: String? = nil) throws -> (URL, URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-fallback-test-")
            .appendingPathExtension(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = try writeExecutableFixture(in: dir)
        let actualSHA = try ExternalProcessAudioFallbackTranscriber.sha256Hex(of: binary)
        let lock = dir.appendingPathComponent("models.lock")
        try lockText(binarySHA: binarySHA ?? actualSHA, modelSHA: nil).write(to: lock, atomically: true, encoding: .utf8)
        return (dir, binary, lock)
    }

    private func writeExecutableFixture(in dir: URL) throws -> URL {
        let binary = dir.appendingPathComponent("fallback.sh")
        try "#!/bin/sh\necho transcript\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    private func lockText(binarySHA: String, modelSHA: String?) -> String {
        var text = """
        schema_version = 1

        [[artifact]]
        id = \"test-whisper-bin\"
        role = \"asr_binary\"
        sha256 = \"\(binarySHA)\"

        """
        if let modelSHA {
            text += """
            [[artifact]]
            id = \"test-whisper-model\"
            role = \"asr_model\"
            sha256 = \"\(modelSHA)\"

            """
        }
        return text
    }

    func testUnclearAudioRetryResponseIsSafeReask() {
        XCTAssertEqual(
            DaemonLLMEngine.unclearAudioRetryResponse(),
            "[heard]: (unclear audio)\nI didn't catch that — please say it again.")
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

// MARK: - Conversation compaction orchestration (Phase G2)

final class ConversationCompactionEngineTests: XCTestCase {

    /// Fallback contract: a compact ERROR must not alter the turn — the current
    /// turn already proceeded on the hard-truncated window. The caller catches,
    /// logs, and retains the backlog; it does NOT install a summary.
    func testCompactErrorLeavesTurnStateIntactAndRetainsBacklog() async throws {
        let engine = MockLLMEngine()
        await engine.setCompactShouldThrow(true)

        let state = ConversationStateTracker()
        await state.setMaxHistory(4)
        for i in 0..<6 { await state.addUserMessage("m\(i)") }

        let pending = await state.pendingCompaction()
        let work = try XCTUnwrap(pending)

        var threw = false
        do {
            _ = try await engine.compactConversation(
                evicted: work.evicted, priorSummary: work.priorSummary)
        } catch {
            // The caller's fallback: swallow, log loudly, do NOT apply a result.
            threw = true
        }
        XCTAssertTrue(threw, "the summarizer error surfaces to the caller")

        // The turn proceeded on the hard-truncated window; nothing was dropped
        // silently — no summary, and the evicted backlog is kept for a retry.
        let history = await state.history
        XCTAssertEqual(history.count, 4)
        let pinned = await state.pinnedSummary
        XCTAssertNil(pinned)
        let retained = await state.pendingEvictionCount()
        XCTAssertEqual(retained, 2)
    }

    /// Happy path: a successful compaction installs the pinned summary and drains
    /// the backlog, so subsequent turns carry the summary and exclude the covered
    /// turns (already trimmed).
    func testCompactSuccessInstallsPinnedSummaryViaEngine() async throws {
        let engine = MockLLMEngine()
        await engine.setCompactSummary("user counted from 0 to 5")

        let state = ConversationStateTracker()
        await state.setMaxHistory(4)
        for i in 0..<6 { await state.addUserMessage("m\(i)") }

        let pending = await state.pendingCompaction()
        let work = try XCTUnwrap(pending)
        let rawSummary = try await engine.compactConversation(
            evicted: work.evicted, priorSummary: work.priorSummary)
        let summary = try XCTUnwrap(rawSummary)
        await state.applyCompactionResult(summary: summary, covered: work.evicted.count)

        let pinned = await state.pinnedSummary
        XCTAssertEqual(pinned, "user counted from 0 to 5")
        let after = await state.pendingCompaction()
        XCTAssertNil(after, "backlog drained after a successful fold")
    }

    /// An engine with no daemon summarizer returns nil (the default protocol
    /// impl), so the caller hard-truncates without installing a summary.
    func testEngineWithoutSummarizerReturnsNil() async throws {
        let engine = MockLLMEngine()  // compactSummary is nil, no throw
        let result = try await engine.compactConversation(
            evicted: [LLMMessage(role: .user, content: "x")], priorSummary: nil)
        XCTAssertNil(result)
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
