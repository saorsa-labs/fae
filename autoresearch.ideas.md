# Autoresearch Ideas — Fae Coverage Optimization

## Completed (Phase 1)

- TurnHelpersTests: 54 tests, 84.5%→89.4%
- SchedulerDistillerTests: 24 tests, distillation helpers exposed
- ToolCallParsingTests: 25 tests for JSON/XML/Gemma parsing
- BackendEventRouterTests: 30 tests for event routing
- PersonalityManagerTests: 34 tests for approval prompts, ephemeral context
- TextProcessingTests: 23 tests for sentence/clause boundary, meta commentary
- AwarenessThrottleTests: 12 tests for frequency reduction, jitter
- ToolRoutingHelpersTests: 46 tests for acknowledgements, repair, intent detection
- ACPProtocolTests: 14 new tests, 67.6%→79.2%
- ConversationBridgeTests: 21 tests for label formatting
- ToolExecutorStaticTests: 34 tests for approval, narration, countdown
- BuiltinToolsTests: 9 new tests for jailbreak detection, metadata blocking
- SchedulerToolsTests: 14 tests for scheduling date calculation
- MemoryInboxTests: 10 tests for text splitting, SHA256
- FaeCoreStaticTests: 5 tests for extractPrimaryName
- ToolAugmentationManagerTests: 10 tests, 17.9%→37.1%
- SkillParserTests: 6 tests, 98.2% coverage
- FaeConfigStaticTests: 16 tests for model recommendations
- WorkWithFaeWorkspaceTests: 8 tests for workspace selection
- CoworkLLMProviderTests: 16 tests for reasoning hints, SSE parsing
- CoworkWorkspaceModelsTests: 21 tests for displayName/category/scheduleDescription
- SkillManagerStaticTests: 9 tests for skill name validation, tier priority
- ChannelSettingsStoreTests: 9 tests, normalizeChannelKey/normalizeFieldID/parseList/parsePort
- EntityContextFormatterTests: 6 tests, formatRelationType/formatMultiple
- CorrectionDetectorTests: 5 tests, capitalizeFirst/isPlausibleName (97.3%)
- EchoSuppressorStaticTests: 5 tests, extractNumbersFromText/numbersFuzzyMatch/normalizeForOverlap (93.0%)
- ImplicitFeedbackDetectorTests: 3 tests, wordBigrams
- PipelineCoordinatorStaticTests: 4 tests, normalizeForPhraseMatch/detectExplicitUserAuthorization
- MetaOptHypothesisGeneratorTests: 7 tests, isToolRelated/isSerializationRelated/directiveAlreadyContains (78.3%)
- MetaOptMemorySeedGeneratorTests: 6 tests, isToolRelated/isScheduleRelated/isSerializationRelated (86.6%)
- SkillMigratorTests: 2 tests, normalizeSkillMarkdown
- DirectiveTunerTests: 4 tests, normaliseGroupKey/groupByContent (96.7%)
- MemoryDigestServiceTests: 10 tests, compactSnippet/digestMetadataJSON/digestSourceRecordIDs/digestSourceKey (90.9%)
- CoworkWorkspaceControllerTests: 3 tests, workspaceConversationMessage/chatMessage
- VisionToolsStaticTests: 6 tests, normalize/didVerifyTypedText (VisionTools 12.0%)
- PersonQueryDetectorTests: 3 tests, extractNameAndLabel (79.6%)
- DamageControlPolicyTests: 7 tests, isDestructiveShellCommand/matches (94.2%)
- NetworkTargetPolicyTests: 8 tests, isBlockedIPAddress (92.9%)
- ToolStaticTests: 14 tests, shellEscape/hashArguments/redactLongOpaqueTokens/escapeHTML/clampInteger/inferJSONSchemaType
- MetaOptNarratorTests: 7 tests, extractTopicHint/describeFromKeywords (76.9%)
- MetaOptSkillGeneratorTests: 4 tests, isToolRelated/isSerializationRelated (98.4%)
- SkillSecurityReviewTests: 2 tests, normalizeSkillURL (90.0%)
- TurnHelpersStaticTests: 15 tests, arithmetic/name parsing (91.4%)

## Measurement Fix

- Per-suite filtering instead of batched (659 profraws vs 65) to avoid XCTest/Swift Testing profraw corruption
- Runtime: ~7min for 220+ individual suite runs

## Remaining Opportunities (Phase 1 continued)

- **TurnHelpers.swift** `explicitInterestTopic` — last remaining private static func
- **TextProcessing.swift** `firstSentenceBoundary`, `verbalizeDates`, `applyCommandCorrections`, `normalizeWakeAlias`, `isBoundary`, `tokenizeWords` — pure string processing but likely already covered by existing test flows
- **PipelineCoordinator.swift** `stripVoiceTagMarkup`, `stripThinkContent`, `isScreenIntentRequest` — pure string processing in massive file (8216 lines)
- **CorrectionDetector.swift** `nameIsNotPattern`, `itsNotPattern`, `iSaidPattern` — pure pattern matching but small impact
- **EchoSuppressor.swift** `extractDigitsFromNumberWords` — pure but likely already covered
- **SkillImportView.swift** `rewriteFrontmatterName` — pure string processing in SwiftUI view

- **BuiltinTools.swift** (38.4%, 528 uncovered): Mostly async execute() methods. Static methods like `containsJailbreakPattern` tested. Could add more integration tests with temp files.
- **FaeScheduler.swift** (38.5%, 1355 uncovered): Large actor with many instance methods. Distillation helpers exposed and tested. Remaining code is async state machine.
- **ToolRoutingHelpers.swift** (80.1%, 212 uncovered): `shouldAttemptRepairToolCall` and `preflightToolDenial` require ToolRegistry dependency. Could mock or extract pure logic.
- **TextProcessing.swift** (82.2%, 207 uncovered): `normalizeForSpeechOutput`, `verbalizeDates` are private static. Could expose for testing.

## Not Recommended (per user feedback)

- ~~Phase 2: Protocol abstractions for GRDB/Contacts/Calendar~~ — tail-wagging-the-dog
- ~~Phase 3: SwiftUI ViewModel extraction~~ — too much churn, low ROI
- Remaining 0% files are SwiftUI views (~35K lines), system-framework-dependent code, or complex actors

## Realistic Ceiling

**28.8%** is the practical ceiling for Phase 1 (pure logic testing + visibility changes). 
To push beyond 30% would require:
- Production code refactoring (extracting testable modules from large coordinators)
- Integration tests with real SQLite/in-memory databases
- XCUITest for SwiftUI views

The 90% target is a category error for a SwiftUI-heavy macOS app with system framework dependencies. Natural ceiling: **30-35%**.
