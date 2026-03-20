
# Self-Diagnostic + Feedback Learning

## Milestone 1: Diagnostic Skill + Anomaly Monitor

### Phase 1.1: self-diagnostic SKILL.md
- [x] Create Resources/Skills/self-diagnostic/SKILL.md (instruction skill, 7-section checklist)

### Phase 1.2: Voice command trigger
- [x] Add .runDiagnostics to VoiceCommand enum
- [x] Match: "diagnose", "run diagnostics", "health check", "how are you doing", "are you working"
- [x] Handler in PipelineCoordinator: activateDiagnosticSkill()

### Phase 1.3: Proactive anomaly watcher
- [x] Add self_diagnostic scheduler task (6h interval)
- [x] Checks memory health, skill health, disk space
- [x] Queues proactive message via proactiveQueryHandler when anomalies found

### Milestone 1 Complete — 2026-03-20

---

## Milestone 2: User Correction Feedback Loop

### Phase 2.1: Correction detection
- [x] Create CorrectionDetector.swift with 4 correction kinds
- [x] Patterns: name errors, mishearings, interruptions, wrong actions
- [x] Value extraction: "my name is X not Y", "I said X not Y", "it's X not Y"

### Phase 2.2: Correction-context correlation
- [x] Create CorrectionRecord with memory text generation
- [x] Integrate detection into PipelineCoordinator.processTranscription()
- [x] Track pendingCorrection with last assistant context

### Phase 2.3: Memory capture
- [x] Add MemoryOrchestrator.storeCorrection() (profile for names, episode for others)
- [x] Wire capturePendingCorrection() at both memory capture sites

### Phase 2.4: Post-ASR vocabulary learning
- [x] Add DynamicVocabularyCorrector.addCorrectionPair()
- [x] Feed name corrections into vocabulary corrector from capturePendingCorrection()

### Milestone 2 Complete — 2026-03-20

---

## Milestone 3: Testing + Integration

### Phase 3.1: Unit + integration tests
- [x] 27 CorrectionDetector tests (all pattern types, edge cases, false positives, CorrectionRecord)
- [x] 8 VocabularyLearning tests (addCorrectionPair, dedup, priority, integration flow)

### Phase 3.2: Skill activation tests
- [x] 16 SelfDiagnosticSkill tests (voice commands, skill discovery, activation/deactivation)

### Phase 3.3: Documentation
- [x] Update CLAUDE.md: new skill, scheduler task, CorrectionDetector, vocabulary learning
- [x] Update docs/CHANGELOG.md: v1.5.0 entry
- [x] Update .planning/progress.md

### Milestone 3 Complete — 2026-03-20
Total new tests: 51 (27 + 8 + 16), all passing, zero warnings
Grand total: 1395 tests, 0 failures

---

# Previous Project: Channel Gateway

## Phase 1.1: CoworkToolExecutor Actor (Updated with CEO review cherry-picks)
- [x] Task 1: Fix force-unwrap, pipelineNotReady guard, CustomStringConvertible (commit: c48b371b)
- [x] Task 2: Extract DRY security check helper (commit: a0751816)
- [x] Task 3: Add empty response guard (commit: a0751816)
- [x] Task 4: Wire SecurityEventLogger for CoWork (commit: a0751816)
- [x] Task 5: Emit redaction visibility event (commit: a0751816)
- [x] Task 6: Add per-provider security metrics (commit: a0751816)
- [x] Task 7: Update ASCII diagram in CoworkToolExecutor (commit: a0751816)
- [x] Task 8: Complete unit tests for new features (commit: a0dd2916)

### Phase 1.1 Complete — 2026-03-19

---

## Milestone 1: Gateway Core (Unified Channel Gateway)

### Phase 1.1: ChannelMessage Envelope + ChannelSession Actor
- [x] Create ChannelMessage.swift (ChannelKind, ChannelAttachment, ChannelMessage) (commit: 0ded8f1d)
- [x] Create ChannelSession.swift (SessionKey, ChannelSession with per-sender history) (commit: 0ded8f1d)
- [x] Create ChannelSessionStore.swift (actor managing all sessions with idle cleanup) (commit: 0ded8f1d)
- [x] Unit tests: 27 tests for all types (commit: 0ded8f1d)

### Phase 1.2: ChannelGateway Actor
- [x] Create ChannelAdapter.swift (protocol for uniform adapter interface) (commit: ca451483)
- [x] Create ChannelGateway.swift (central routing actor with session store) (commit: ca451483)
- [x] MockChannelAdapter + 11 gateway tests (commit: ca451483)

### Phase 1.3: Per-Sender Conversation Isolation
- [x] Add swapHistory() to ConversationStateTracker (commit: 4c214dcd)
- [x] Add injectChannelMessage(_:session:) to PipelineCoordinator (commit: 4c214dcd)
- [x] 4 isolation tests (commit: 4c214dcd)

### Milestone 1 Complete — 2026-03-19
Total tests: 42 (27 + 11 + 4), all passing, zero warnings
