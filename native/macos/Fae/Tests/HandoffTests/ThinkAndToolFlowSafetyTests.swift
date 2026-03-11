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

    func testStripNonSpeechCharsNormalizesHistoricalNumberArtifacts() {
        let text = "The ab acus in Mes opot amia dates to 3 0 0 0 - 2 5 0 0 BCE."
        let cleaned = TextProcessing.stripNonSpeechChars(text)

        XCTAssertTrue(cleaned.contains("abacus"))
        XCTAssertTrue(cleaned.contains("Mesopotamia"))
        XCTAssertTrue(cleaned.contains("3000 to 2500"))
        XCTAssertTrue(cleaned.contains("B C E"))
    }

    func testStripNonSpeechCharsVerbalizesDates() {
        let text = "Milestones were 2026-03-03 and 03/04/2026."
        let cleaned = TextProcessing.stripNonSpeechChars(text)

        XCTAssertTrue(cleaned.contains("March 3, 2026"))
        XCTAssertTrue(cleaned.contains("March 4, 2026"))
    }

    func testStripReasoningPrefaceRemovesThinkingStyleLeadIn() {
        let text = "I'll analyze the user's request carefully. Let me think through each option systematically. Option 1 is a local database."
        let cleaned = TextProcessing.stripReasoningPreface(text)

        XCTAssertEqual(cleaned, "Option 1 is a local database.")
    }

    func testStripReasoningPrefacePreservesDirectAnswerContent() {
        let text = "Option 1 is a local database with strong privacy and low operational overhead."
        let cleaned = TextProcessing.stripReasoningPreface(text)

        XCTAssertEqual(cleaned, text)
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

    func testParseToolCallsSupportsUnterminatedQwen35XmlBlock() {
        let response = """
        <voice character="David"><dialog><p>I'll check that.</p></dialog></voice>
        <tool_call>
        <function=read>
        <parameter=path>
        /etc/hosts
        </parameter>
        <parameter=content>
        localhost:1 localhost
        """

        let calls = PipelineCoordinator.parseToolCalls(from: response)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read")
        XCTAssertEqual(calls[0].arguments["path"] as? String, "/etc/hosts")
        XCTAssertEqual(calls[0].arguments["content"] as? String, "localhost:1 localhost")
    }

    func testStripToolCallMarkupRemovesUnterminatedToolCallTail() {
        let response = """
        Sure, I'll check.
        <tool_call>
        <function=read>
        <parameter=path>/etc/hosts</parameter>
        """

        XCTAssertEqual(PipelineCoordinator.stripToolCallMarkup(response), "Sure, I'll check.")
    }

    func testLooksLikeNonProseDetectsToolPayloadJSON() {
        let payload = #"{"name":"web_search","arguments":{"query":"weather"}}"#
        XCTAssertTrue(TextProcessing.looksLikeNonProse(payload))
    }

    func testLooksLikeNonProseAllowsTechnicalProseSentence() {
        let sentence = "I'll inspect the config path and explain each setting before we change anything."
        XCTAssertFalse(TextProcessing.looksLikeNonProse(sentence))
    }

    func testLooksLikeNonProseDetectsToolXMLMarkup() {
        let xml = "<tool_call><function=read><parameter=path>/tmp/a.txt</parameter></function></tool_call>"
        XCTAssertTrue(TextProcessing.looksLikeNonProse(xml))
    }

    func testLooksLikeNonProseAllowsStructuredButConversationalText() {
        let sentence = "First, open Settings. Next, choose Audio. Finally, enable Voice Isolation."
        XCTAssertFalse(TextProcessing.looksLikeNonProse(sentence))
    }

    func testWakeAddressMatchDetectsFuzzyNearMissAtGreeting() {
        let match = TextProcessing.findWakeAddressMatch(
            in: "Hey faeye open settings",
            aliases: TextProcessing.nameVariants,
            wakeWord: "hi fae"
        )

        XCTAssertNotNil(match)
        XCTAssertEqual(match?.kind, .fuzzy)
        XCTAssertEqual(match?.matchedToken, "faeye")
    }

    func testWakeAddressMatchRejectsTwoLetterFalsePositive() {
        let match = TextProcessing.findWakeAddressMatch(
            in: "Ah.",
            aliases: TextProcessing.nameVariants,
            wakeWord: "hi fae"
        )

        XCTAssertNil(match)
    }

    func testWakeAddressMatchRejectsOrdinaryWordNearMiss() {
        let match = TextProcessing.findWakeAddressMatch(
            in: "What day is it today?",
            aliases: TextProcessing.nameVariants,
            wakeWord: "hi fae"
        )

        XCTAssertNil(match)
    }

    func testExtractQueryAroundNameReturnsEmptyForWakeOnlyUtterance() {
        let text = "Fae"
        let range = text.startIndex..<text.endIndex

        XCTAssertEqual(TextProcessing.extractQueryAroundName(in: text, nameRange: range), "")
    }

    func testExtractWakeAliasCandidateFromGreeting() {
        let alias = TextProcessing.extractWakeAliasCandidate(from: "Hi Faye can you help")
        XCTAssertEqual(alias, "faye")
    }

    func testBargeInOnlyTracksWhileAssistantSpeaking() {
        XCTAssertTrue(PipelineCoordinator.shouldTrackBargeIn(assistantSpeaking: true))
        XCTAssertFalse(PipelineCoordinator.shouldTrackBargeIn(assistantSpeaking: false))
    }

    func testBargeInDoesNotInterruptSilentGeneration() {
        XCTAssertFalse(
            PipelineCoordinator.shouldAllowBargeInInterrupt(
                assistantSpeaking: false,
                assistantGenerating: true
            )
        )
        XCTAssertTrue(
            PipelineCoordinator.shouldAllowBargeInInterrupt(
                assistantSpeaking: true,
                assistantGenerating: true
            )
        )
    }

    func testSelfConfigGetSettingsBypassesApproval() {
        XCTAssertFalse(
            PipelineCoordinator.toolRequiresApproval(
                toolName: "self_config",
                arguments: ["action": "get_settings"],
                defaultRequiresApproval: true
            )
        )
    }

    func testSelfConfigAdjustSettingStillRequiresApproval() {
        XCTAssertTrue(
            PipelineCoordinator.toolRequiresApproval(
                toolName: "self_config",
                arguments: ["action": "adjust_setting", "key": "tts.speed", "value": 1.1],
                defaultRequiresApproval: true
            )
        )
    }

    func testModelManagerEffectiveTTSModelIDUsesCanonicalFaeVoiceWhenLocked() async {
        let manager = ModelManager(eventBus: FaeEventBus())
        var config = FaeConfig()
        config.tts.modelId = "kokoro:af_heart"
        config.tts.voice = "bf_emma"
        config.tts.speed = 1.25
        config.tts.voiceIdentityLock = true

        let modelID = await manager.effectiveTTSModelID(for: config)
        XCTAssertEqual(modelID, "kokoro:fae:1.25")
    }

    func testModelManagerEffectiveTTSModelIDUsesConfiguredVoiceWhenUnlocked() async {
        let manager = ModelManager(eventBus: FaeEventBus())
        var config = FaeConfig()
        config.tts.modelId = "kokoro:af_heart"
        config.tts.voice = "bf_emma"
        config.tts.speed = 0.95
        config.tts.voiceIdentityLock = false

        let modelID = await manager.effectiveTTSModelID(for: config)
        XCTAssertEqual(modelID, "kokoro:bf_emma:0.95")
    }

    func testModelManagerEffectiveTTSModelIDLeavesNonKokoroModelUntouched() async {
        let manager = ModelManager(eventBus: FaeEventBus())
        var config = FaeConfig()
        config.tts.modelId = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"
        config.tts.voice = "fae"
        config.tts.voiceIdentityLock = true

        let modelID = await manager.effectiveTTSModelID(for: config)
        XCTAssertEqual(modelID, "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16")
    }

    func testKokoroDownloadRevisionIsPinned() {
        XCTAssertEqual(KokoroMLXTTSEngine.pinnedModelRevision, "14b74f4")
        XCTAssertEqual(KokoroMLXTTSEngine.pinnedVoicesRevision, "4685882")
        XCTAssertNotEqual(KokoroMLXTTSEngine.pinnedModelRevision, "main")
        XCTAssertNotEqual(KokoroMLXTTSEngine.pinnedVoicesRevision, "main")
    }
}
