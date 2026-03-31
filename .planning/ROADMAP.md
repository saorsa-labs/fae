# Roadmap: Voice Experience Overhaul

## Design Documents
- Design doc: `~/.gstack/projects/saorsa-labs-fae/davidirvine-main-design-20260331-151032.md`
- Status: APPROVED (2026-03-31)

## Success Criteria
- Wake word >95% detection at 2m, <1% false positive, <200ms response
- PTT works 100% regardless of RAM
- Enrollment complete in <2 minutes
- Shadow mode: zero regressions during rollout
- The mom test: non-technical person says "Fae" and gets a response first try

---

## Milestone 1: Push-to-Talk + Fused Enrollment

### Phase 1.1: Push-to-Talk Button ✅ COMPLETE
- Add 2s ring buffer to AudioCaptureManager (32,000 samples at 16kHz)
- Extend GlobalHotkeyManager: keyUp events for hold-to-talk (Right Option default)
- Wire orb click in collapsed mode to start listening
- Missed-wake capture: log preceding audio when PTT after failed wake
- Storage: ~/Library/Application Support/fae/wake_training/missed/ (max 500, FIFO)
- Tests: ring buffer, hold/release, missed-wake logging

### Phase 1.2: Fused Enrollment Flow ✅ COMPLETE
- Replace SpeakerEnrollmentView 4-step with 6-step:
  1. Name, 2. Wake phrases (4x), 3. Conversational (3x 8s), 4. Room noise (20s), 5. Photo, 6. Complete
- Atomic commit on step 6 completion
- Generate acoustic templates + reference embeddings from wake phrases
- Tests: completion, abandonment, template generation

### Phase 1.3: Bundle Keyword Classifier ✅ COMPLETE
- Train MLXKeywordClassifier offline (~10K synthetic + LibriSpeech negatives)
- Bundle model.safetensors + config.json
- Score fusion: 0.7 * classifier + 0.3 * max(template_cosine)
- Tests: loading, inference, fusion, threshold

### Phase 1.4: Shadow-Mode Evaluator ✅ COMPLETE
- ShadowWakeWordEvaluator: parallel detector comparison
- Promotion: 200 attempts + FP < 1% + FN < 5%
- Demotion: FP > 2% over 50-utterance window
- Thermal gate, Voice Diagnostics screen
- Tests: promotion, demotion, thermal pause

---

## Milestone 2: Proactive Vocabulary Learning

### Phase 2.1: PersonalLexicon Actor ✅ COMPLETE
- PersonalLexicon actor with JSON persistence at ~/Library/Application Support/fae/personal_lexicon.json
- DynamicVocabularyCorrector.ingestLexicon() integration
- Git Vault backup (personal_lexicon.json added to configFiles)
- PipelineCoordinator loads lexicon at startup, feeds into DVC rebuild
- Name corrections auto-saved to lexicon + DVC
- Tests: 14 (CRUD, persistence, snapshot, bulk merge, DVC integration)

### Phase 2.2: Vocabulary Harvesting ✅ COMPLETE
- VocabularyHarvester: harvests Contacts (CNContactStore) + Calendar (EKEventStore, next 30 days)
- Scheduler task vocabulary_harvest: daily at 04:00
- Post-enrollment trigger: vocabulary harvest runs after primary user enrollment
- Graceful permission handling: skips sources without access, no crashes
- Tests: 4 (harvest integration, dedup, persistence, permission handling)

### Phase 2.3: Enhanced Correction Loop ✅ COMPLETE
- ASRConfidenceDetector: phonetic clustering, spelling divergence detection across utterances
- Max 1 correction prompt per conversation to avoid annoyance
- Typed correction flow: applyTypedSpellingCorrection() feeds PersonalLexicon + DVC
- PipelineCoordinator integration: feeds transcriptions into detector, schedules prompts
- Tests: 8 (divergence detection, consistent spellings, prompt limits, reset, common/short words, typed correction)
