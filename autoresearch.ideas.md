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

## Measurement Fix

- Per-suite filtering instead of batched (659 profraws vs 65) to avoid XCTest/Swift Testing profraw corruption
- Runtime: ~7min for 220+ individual suite runs

## Remaining Opportunities (Phase 1 continued)

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
