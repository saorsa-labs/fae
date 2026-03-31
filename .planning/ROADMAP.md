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

### Phase 2.1: PersonalLexicon Actor
- Single source of truth for user vocabulary
- JSON persistence, Git Vault backup
- DynamicVocabularyCorrector integration
- Tests: CRUD, DVC rebuild, persistence

### Phase 2.2: Vocabulary Harvesting
- Scheduler task: Contacts + Calendar names
- Permission warm-up during enrollment
- Tests: harvesting, permission, dedup

### Phase 2.3: Enhanced Correction Loop
- ASR confidence heuristic (spelling divergence)
- "Type that so I remember it" prompt
- Typed corrections, spelling recognition (stretch)
- Tests: confidence detection, typed correction flow
