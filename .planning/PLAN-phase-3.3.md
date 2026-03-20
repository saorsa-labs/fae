# Phase 3.3: Extract Static Helpers + Type Definitions

> **Honest scope adjustment**: The original roadmap described extracting "LLMStage actor" and
> "ToolExecutionStage actor". After analysis in Phases 3.1-3.2, we know that `generateWithTools`
> and `executeTool` have 10+ coordinator dependencies (eventBus, playback, conversationState,
> memoryOrchestrator, speakerGate, config, registry, echoSuppressor, etc.) and cannot be moved
> to separate actors without introducing async boundary changes.
>
> What CAN be extracted: the ~1800 lines of pure static helper functions and type definitions
> that support these methods. This is the honest maximum achievable extraction.

## Task 1: Extract ToolRoutingHelpers namespace

Move all tool routing/repair/intent-detection static functions to `ToolRoutingHelpers.swift`.

**Functions to move** (lines ~8093-9141):
- `toolCallAcknowledgement(for:)`
- `stripVoiceTagMarkup(_:)`
- `stripThinkContent(_:)`
- `deferredToolAllowlist` (static let)
- `inlineGroundedToolAllowlist` (static let)
- `canRunDeferredToolCalls(_:registry:)`
- `shouldPreferInlineToolExecution(userText:toolCalls:)`
- `isReadOnlyDeferredAction(_:)`
- `responseImpliesToolIntent(_:)`
- `isCameraIntentRequest(_:)`
- `isScreenIntentRequest(_:)`
- `screenRepairToolCall(for:)`
- `extractReferencedAppName(from:)`
- `isToolBackedLookupRequest(_:)`
- `repairedToolCallForSkippedTurn(_:)`
- `extractSessionSearchQuery(from:)`
- `shouldAttemptRepairToolCall(...)`
- `preflightToolDenial(...)`
- `shouldSuppressThinking(...)`
- `extractSingleQuotedSegments(from:)`
- `extractReplacementPair(...)`
- `extractPathCandidate(from:)`
- `extractURLCandidate(from:)`
- `extractSearchQuery(from:)`
- `normalizeSearchRepairQuery(_:)`
- `repairedCalendarLookupCall(from:lowercased:)`
- `repairedRemindersLookupCall(from:lowercased:)`
- `repairedCloseAppCall(lowercased:)`
- `repairedContactsLookupCall(from:lowercased:)`
- `repairedMailLookupCall(lowercased:)`
- `repairedNotesLookupCall(from:lowercased:)`
- `extractISODateCandidate(from:)`
- `containsWholeWord(_:in:)`
- `extractCalendarSearchQuery(from:lowercased:)`
- `extractCommandCandidate(from:)`
- `extractNamedEntity(from:markers:)`
- `extractIntervalSchedule(from:)`
- `extractSkillName(from:)`
- `extractExecutableSkillName(from:)`
- `extractElementIndex(from:)`
- `extractTypeText(from:)`
- `estimateTokenCount(for:)`
- `directToolReplyText(for:result:)`
- `serializeArguments(_:)`
- `stripScreenshotEnvelope(from:)`
- `stripSimpleToolPrefix(_:from:)`
- `extractAudioFilePath(from:)`
- `inferUserPresentFromCameraOutput(_:)`
- `contentHash(_:)`

**Approach**: Create `enum ToolRoutingHelpers` namespace. Add forwarding methods/typealiases in PipelineCoordinator for any call sites that reference `Self.xxx` or `PipelineCoordinator.xxx`.

**Expected reduction**: ~1000 lines

## Task 2: Extract TurnHelpers namespace

Move memory/turn decision static functions to `TurnHelpers.swift`.

**Functions to move** (lines ~129-900):
- `shouldRecallMemoryForTurn(...)`
- `memoryTurnGuidance(for:)`
- `explicitInterestTopic(in:lower:)`
- `cleanInterestTopic(_:)`
- `visibleToolNamesForTurn(...)`
- `ambiguousToolNames` (static let)
- `explicitlyMentionedToolNames(...)`
- `inferredToolNamesForTurn(...)`
- `shouldSuppressEpisodeRecallForToolSensitiveTurn(...)`
- `arithmeticNumberWords` (static let)
- `isEphemeralArithmeticQuery(_:)`
- `deterministicEasyTurnAction(for:rememberedUserName:)`
- `normalizeEasyTurnInput(_:)`
- `deterministicArithmeticReply(for:)`
- `parseArithmeticExpression(_:)`
- `parseArithmeticOperand(_:)`
- `standaloneUserNameDeclaration(in:)`
- `isLikelyStandaloneHumanName(_:)`
- `isSimpleUserNameRecallQuery(_:)`
- `batchedTTSSegments(...)`
- `shouldAcceptVoiceApprovalResponse(...)`
- `toolNameAliases(_:)`
- `llmFailureFallbackMessage(...)`
- `prefersLegacyInlineToolPrompt(modelId:)`
- `shouldShowCapabilitiesCanvas(triggerText:modelResponse:)`
- `detectExplicitUserAuthorization(in:)`
- `shouldForceThinkingSuppression(for:)` (convert to static)
- `resolveRelayReply(...)`
- `normalizeForPhraseMatch(_:)`
- `isConversationStopTrigger(...)`
- `immediateQuietTriggers` (static let)

**Approach**: Create `enum TurnHelpers` namespace. Add forwarding methods in PipelineCoordinator.

**Expected reduction**: ~770 lines

## Task 3: Extract GateHelpers namespace

Move gate/speaker decision static functions to `GateHelpers.swift`.

**Functions to move** (lines ~2111-2350):
- `idleRearmSeconds(...)`
- `silenceThresholdMs(...)`
- `shouldSkipSTTAfterSpeakerVerification(...)`
- `streamingSpeakerSimilarityDecision(...)`
- `fusedVoiceAttentionDecision(...)`
- `shouldDeferSemanticTurn(...)`
- Speaker threshold constants (previewSpeakerWindowMs, etc.)
- `faeSelfEchoThreshold`

**Expected reduction**: ~240 lines

## Task 4: Extract remaining type definitions

Move internal struct types to `PipelineTypes.swift` (append to existing file):
- `PendingGovernanceAction` + `AnySendableValue`
- `WorkflowTraceContext`
- `PendingSemanticTurn`
- `DeferredToolJob` + `GenerationContext`
- `DeferredProactiveRequest`

**Expected reduction**: ~80 lines

## Task 5: Build + test validation

- `swift build` zero warnings
- `swift test` all 1560 tests pass
- Verify line count reduction

## Summary

**Expected total reduction**: ~2090 lines (9,663 → ~7,573)
**Cumulative from 10,080**: ~2507 lines removed (~25%)
**Realistic final size after 3.4 cleanup**: ~7,200-7,500 lines

**Why not smaller**: The core methods (generateWithTools ~2000 lines, processTranscription ~700 lines,
main pipeline loop ~1200 lines, gate control ~1300 lines, speech segment processing ~1200 lines)
all have deep coordinator state dependencies and cannot be extracted without async boundary changes.
