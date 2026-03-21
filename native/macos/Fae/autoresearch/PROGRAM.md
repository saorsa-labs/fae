# FaeAutoResearch Program

## Objective

Bring all 9 quality dimensions to **≥85/100** through iterative, autonomous improvement.
Each iteration: run scenarios → evaluate → identify weakest sub-metric → modify code/config → re-test → keep or revert.

## Priority Order

1. **Voice Pipeline** — foundation; nothing works if STT→LLM→TTS chain fails
2. **Tool Execution** — core value; Fae's power comes from tools
3. **Conversation Quality** — user experience; needs to feel natural for voice
4. **Barge-in & Interruption** — critical UX; users must be able to interrupt
5. **Advanced Pipeline** — streaming ASR, turn detection, speculative prefill, generation takeover
6. **Memory & Context** — stickiness; what makes Fae personal
7. **Speaker Identity & Security** — voice is the auth model
8. **Skill System** — extensibility; platform value
9. **Proactive Features** — delight; what makes Fae magical

## Modification Strategy

When a dimension scores below 85/100, work through these layers in order.
Try the cheapest/safest change first. Escalate only when simpler changes fail.

### Layer 1: Parameter Tuning (low risk — try first)

Config values that can be changed without code modification:

**LLM generation:**
- `temperature` (0.3–1.0)
- `maxTokens` (256–8192)
- `prefillStepSize` (128–1024)
- `kvGroupSize`, `kvQuantStartTokens`, `repetitionContextSize`

**Barge-in / adaptive interruption:**
- `AdaptiveInterruptionConfig.minOverlapMs` (100–500)
- `AdaptiveInterruptionConfig.rmsSustainFloor` (0.02–0.10)
- `AdaptiveInterruptionConfig.minSustainedChunks` (1–6)
- `AdaptiveInterruptionConfig.peakRmsRatio` (1.0–2.0)
- `AdaptiveInterruptionDecider.assistantStartHoldoffMs` (100–500)
- `FalseInterruptionRecovery.timeoutMs` (800–3000)
- `GenerationTakeoverCandidate.minConsecutiveChunksForTakeover` (10–40)

**Echo suppressor:**
- `echoTailMs` (200–1000)
- `shortUtteranceGuardMs` (300–1500)
- `playbackSpikeMultiplier` (1.5–4.0)
- `echoRmsCeiling` (0.05–0.25)

**Endpointing:**
- `configMinSilenceMs` (400–2000)
- `bargeInSilenceMs` (100–500)
- `continuationFloorMs` (2000–5000)
- `incompleteFloorMs` (1500–3500)

**Speaker ID:**
- `ownerThreshold` (0.60–0.90)
- `threshold` (0.55–0.85)

**Turn detector:**
- EOU thresholds (per-language, see MLXTurnDetector.languageThresholds)

### Layer 2: Prompt Tuning (medium risk)

- PersonalityManager system prompt layers (12-layer stack)
- SOUL.md character definition
- Tool schemas (parameter descriptions, examples in tool spec JSON)
- Skill SKILL.md instructions and frontmatter

### Layer 3: Code Modification (higher risk — when layers 1-2 insufficient)

- Pipeline timing logic in PipelineCoordinator
- EchoSuppressor algorithms
- TextProcessing patterns (name corrections, think tag stripping)
- Tool implementations (parameter parsing, result formatting)
- Memory recall weighting (ANN/FTS5 hybrid ratio)
- BackchannelClassifier phrase list
- silenceThresholdMs() decision logic

## Constraints

1. **Never modify TestServer.swift** — immutable test infrastructure
2. **Never modify test scenario files** without explicit human approval
3. **All modifications must pass `just build`** before re-testing
4. **Maximum 5 modification attempts** per sub-metric before escalating to next layer
5. **Always commit working improvements** before attempting next change
6. **Revert immediately** if any dimension regresses > 5 points
7. **Never introduce `.unwrap()` or `panic!()`** — zero tolerance
8. **Document every modification** in STATE.json modifications array

## Evaluation Protocol

1. Each scenario runs against live Fae via TestServer HTTP API
2. Timing metrics extracted from `/events?since=N` (220+ debug events)
3. Accuracy metrics from `/conversation` (response text comparison)
4. Subjective quality from LLM-as-judge (via Fae's own inference)
5. Security metrics from tool gating and approval flow verification
6. Dimension score = weighted average of sub-metrics, scaled 0-100

## Session Management

- Each iteration: build → launch → test → evaluate → modify → rebuild → re-test
- Between iterations: `POST /reset` clears conversation state
- Fae process restarted between dimension switches (clean state)
- Results persisted to `results/run_TIMESTAMP.json`
- STATE.json updated after each successful evaluation
