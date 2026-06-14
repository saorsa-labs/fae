# S18 kill-list 3/3 — Qwen-ASR + non-PTT speech flow removal plan

Status: EXECUTED 2026-06-12. Predecessors landed: 1/3 SmartTurn (384f39d7),
2/3 keyword spotter (13480bb8), both CI green. Companion context:
docs/spikes/S18-pure-gemma-asr-ptt.md ("Post-S18 consolidation queue").

Task #10 follow-up: EXECUTED 2026-06-14. Scope clarified to the orb
Thinking-liveness bug: silent awareness/proactive generations are tracked for
stale-token isolation but no longer drive the user-visible `assistantGenerating`
indicator; overlapping/stale generations now force the indicator back to idle
when no visible generation or approval pause remains.

Execution notes (deviations from the delete/keep lists below):
- `ParakeetStreamingEngine` went with the `StreamingSTTEngine` protocol (its
  only conformer); `KeywordBiasConfig` moved into `KeywordSpotter.swift`.
- `AppleSpeechClassifier` DELETED (dead-flow-only, recreatable wrapper).
- Speech verifiers (CoreML + MLX): confirmed segment-flow-only → coordinator
  call sites + ModelManager loads removed; type files stay compiled.
- The ToolRegistry `sttEngine:` param was vestigial (its consumer was the
  voice_identity tool, deleted in teardown Phase B) — param removed, no tool
  to migrate.
- `injectAudio` (companion handoff) now rides the daemon audio lane like a
  PTT capture (WAV → pendingPTTAudioBase64 → audio turn), marking the turn
  as owner.
- Also removed as orphans: `FaeConfig.recommendedSTTModel`, `[stt]` +
  `[streamingASR]` config sections (legacy keys parse as no-ops),
  `PipelineDegradedMode.noSTT`, `STTResult`, missed-wake pipeline glue
  (`markFailedWake`/`consumeFailedWake` — `MissedWakeStore` type kept),
  speculative prefill, silent-generation buffer, semantic-turn hold, and the
  in-loop barge-in paths (PTT click is the interrupt; `BargeInState` and the
  static decision helpers + tests remain).

## Owner decisions (2026-06-12, verbatim intent)

1. **Wake-word machinery: KEEP, disabled.** Future always-on rethink may
   reuse it ("models may give us this, but machinery may change — keep for
   now, disabled"). Keep the types compiled; their pipeline call sites
   disappear with the deleted flow, which is the "disabled" state. Do NOT
   delete WakeWordScoreFusion, WakeWordAcousticDetector,
   WakeWordProfileStore, ShadowWakeWordEvaluator, MissedWakeStore, or their
   tests (tests of pure helpers stay valid).
2. **Vocabulary correction: KEEP and USE.** Wire
   TextProcessing.correctNameRecognition + DynamicVocabularyCorrector onto
   the daemon lane's `[heard]:` transcripts. CorrectionDetector
   ("my name is X not Y") stays too — it feeds memory + corrector pairs.
3. **PTT-only.** Push-to-talk is THE capture model — no always-on lane.
   Retire `voice.pushToTalkOnly` (the flag becomes meaningless); delete the
   non-PTT speech flow outright. Owner: "adding more is too complex and we
   have lots of work to do on skills/overnight training and more."

## Delete list

| Surface | Notes |
|---------|-------|
| `ML/MLXSTTEngine.swift` (139 LOC) | Qwen3-ASR engine |
| `ML/StreamingSTTEngine.swift` (147 LOC) | protocol for the disabled Parakeet fast-path; `ModelManager.parakeetEngine` with it |
| `Pipeline/SpeechInputStage.swift` (171 LOC) | speech segment queue + streaming partials |
| PipelineCoordinator: `handleSpeechSegment`, the always-on segment loop, streaming-transcription session consumption, `processTranscription`'s ASR-only entry path | the LARGEST part — map precisely before cutting; PTT path (`pttStart/pttStop/pttToggle` + buffered WAV → daemon) is the survivor |
| `STTEngine` protocol in `Core/MLProtocols.swift` | check no other conformers |
| `FaeCore.sttEngine` (line ~162) + wiring (~309, ~456, ~465-466) | also ModelManager.loadAll(stt:) param (~247) |
| `ToolRegistry` `sttEngine:` params (lines 28/40/56) | find which tool consumes it (likely a transcription/audio tool) and decide: delete tool or route through daemon ASR |
| `voice.pushToTalkOnly` config flag | retire; PTT is unconditional |
| CLAUDE.md: STT model-stack row, pipeline diagram step 5, `stt.modelId` config section, vocabulary-correction section header (update wording: corrections now apply to [heard] transcripts) |

## Keep list (verified reasons)

- **WeSpeaker/speakerGate/SpeakerProfileStore** — S18 doc gray zone +
  fae_self echo rejection (Phase C pending).
- **Speech verifier (CoreML + MLX)** — CHECK FIRST: if its only consumer is
  the deleted segment flow, it becomes wake-machinery-adjacent: keep
  compiled, call sites go (same "disabled" treatment; note in commit).
- **VAD (SileroVAD)** — PTT endpointing uses it (pttSilenceSamples, vad.reset()
  in pttStart; silence-stop logic).
- **Echo suppressor** — Phase C decides.
- **AppleSpeechClassifier** — check consumers; likely deleted-flow-only →
  same keep-compiled treatment unless trivially deletable… it's an Apple
  framework wrapper; if only the dead flow uses it, prefer DELETE (it's
  recreatable, unlike trained wake templates).

## Wiring work (the constructive part)

1. **[heard] transcripts through vocab correction.** Current correction
   application is at PipelineCoordinator ~3465-3466
   (`TextProcessing.correctNameRecognition` → `vocabularyCorrector.correct`)
   — verify whether the daemon-lane [heard] extraction (region ~149-291,
   `[heard]:` first-line contract) flows through that path. If not, apply
   both correctors to the extracted transcription before it is stored /
   displayed / spoken-about. CorrectionDetector should also run on the
   corrected [heard] text (it currently hooks processTranscription).
2. **Vocab corrector lifecycle stays**: rebuild at pipeline start
   (~2415-2423), correction learning (~2430-2469) — these survive
   unchanged; only their input source narrows to PTT/[heard]/typed text.
3. **pttToggle/pttStart/pttStop, hotkeys, orb talk_toggle** — unchanged.

## Validation

- `swift build` zero errors; full suite `swift test --skip VocabularyHarvest`
  from native/macos/Fae (QUIT the dev app first — RuntimeContractTests races
  into live daemon sockets + MLX loads; see project_ci_test_debt memory).
  Known flakes (one may fail per run, rerun/isolate): EchoSuppressor timing,
  CorpusEval noise-floor boundary.
- Live re-test: `source ~/.secrets && just run-dev` → click orb → speak →
  [heard] transcript shows CORRECTED text (try a name Qwen/Gemma garbles).
- CI green before proceeding to the next chunk.

## After this chunk (queue order)

1. Daemon-default chunk (Task #9): bundle fae-daemon into Fae.app, flip
   `llm.useDaemonEngine`/`tts.useDaemonEngine` defaults true, models.lock
   distribution — THEN delete FaeTTSAdapter + MLXLLMEngine (note: MLX LLM is
   the LoRA training substrate; decide training story first).
2. Test isolation (Task #10) — superseded by the clarified Task #10
   Thinking-liveness fix above; test isolation remains future CI debt.
3. Daemon streaming + cancel; candle voice-tts backend.
4. MTP wiring (Task #1, recipe in memory project_mtp_daemon_speedup.md).
