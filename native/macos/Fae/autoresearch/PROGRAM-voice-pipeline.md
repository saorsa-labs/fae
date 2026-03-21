# Voice Pipeline AutoResearch Program

## Philosophy: What Makes Fae a Great Voice Companion

A truly reliable voice companion must excel at ten things simultaneously:

1. **Hear accurately** — STT transcribes faithfully, names correct, no hallucinated words
2. **Know who's speaking** — primary user recognised instantly, strangers handled gracefully
3. **Ignore noise** — music, TV, traffic, typing never trigger false activation
4. **Respond quickly** — simple queries get snappy replies; complex ones get "I'm thinking" feedback
5. **Think when needed** — reasoning for hard questions, direct answers for easy ones
6. **Remember everything** — names, preferences, facts captured automatically, recalled naturally
7. **Feel like a friend** — warm, empathetic, humorous, never robotic or templated
8. **Know her capabilities** — describes tools/skills accurately, suggests help proactively
9. **Handle interruption** — user can always break in; Fae stops, listens, pivots
10. **Be resource-conscious** — doesn't drain battery, overheat GPU, or eat RAM

This autoresearch run tests dimensions 1-10 without executing tools/skills (dimension 8 tests
*knowledge* of capabilities, not invocation).

## Dimensions

### 1. responsiveness (text + audio)

How fast Fae responds, measured at each pipeline stage.

**Sub-metrics:**
- `ttft_ms` — time to first LLM token after speech ends
- `ttfa_ms` — time to first TTS audio after speech ends
- `e2e_simple_ms` — end-to-end for "Hello" → response
- `e2e_complex_ms` — end-to-end for multi-sentence question → response
- `think_overhead_ms` — extra latency when thinking vs not thinking
- `followup_speedup` — second turn faster than first (KV cache hit)

**Target:** Simple greetings < 3s TTFA, factual questions < 8s TTFA.

### 2. conversation_quality (text)

Natural, coherent multi-turn conversation.

**Sub-metrics:**
- `multi_turn_coherence` — maintains context across 5+ turns
- `topic_switch_grace` — handles "actually, let's talk about X" naturally
- `pronoun_resolution` — "Tell me about Mars. How far is it?" → "it" = Mars
- `contradiction_handling` — "Actually I meant Jupiter" → corrects gracefully
- `brevity_match` — short questions get short answers, complex get detailed
- `no_parroting` — never repeats what the user just said ("You asked about...")
- `no_template_feel` — responses feel natural, not canned/AI-slop

### 3. memory_pipeline (text)

Automatic memory capture and natural recall during conversation.

**Sub-metrics:**
- `name_capture` — "My name is David" → stores, recalls later
- `preference_capture` — "I prefer tea" → stores, recalls
- `fact_capture` — "My birthday is July 15" → stores, recalls
- `relationship_capture` — "My sister Emma works at..." → stores, recalls
- `correction_handling` — "Actually it's David not Dave" → updates
- `cross_turn_recall` — info from turn 2 available in turn 8
- `no_false_recall` — doesn't invent memories not in the store

### 4. personality (text)

Warmth, empathy, humor — Fae should feel like a caring friend.

**Sub-metrics:**
- `warm_greeting` — greetings are personal, not generic
- `empathy` — responds to "I'm feeling down" with genuine care
- `humor` — tells jokes when asked, light humor in conversation
- `identity_consistency` — always knows she's Fae, Scottish roots
- `voice_appropriate_length` — answers are spoken-word length, not essay-length
- `no_ai_slop` — no "Great question!", "Absolutely!", "I'd be happy to!"
- `farewell_warmth` — goodbyes are warm, not abrupt

### 5. thinking_mode (text)

Appropriate use of think/no-think mode.

**Sub-metrics:**
- `simple_no_think` — "Hello" gets no-think fast response
- `math_no_think` — "What's 7 × 8?" → direct answer, no think
- `complex_thinks` — "Explain quantum entanglement" → may think, thorough
- `tags_never_leak` — <think> tags never appear in spoken output
- `think_adds_quality` — thinking produces better answers when used
- `think_latency_acceptable` — thinking doesn't add > 5s for simple queries

### 6. capability_awareness (text)

Fae knows what she can do without actually doing it.

**Sub-metrics:**
- `describes_tools` — "What can you do?" → lists real capabilities
- `knows_calendar` — "Can you check my calendar?" → "Yes, I can"
- `knows_limitations` — "Can you order food?" → honest "I can't"
- `knows_skills` — "What skills do you have?" → accurate list
- `no_hallucinated_capabilities` — doesn't claim abilities she lacks
- `suggests_help` — proactively offers relevant capabilities

### 7. speaker_gate (audio)

Voice identity — who gets responded to, who gets ignored.

**Sub-metrics:**
- `owner_accept_rate` — primary user voice → responds (target: >95%)
- `stranger_reject_rate` — unknown voice → ignores (target: >90%)
- `conversation_context` — owner + stranger talking → responds to owner, acknowledges stranger
- `re_identification` — owner speaks after 30s silence → still recognised
- `echo_rejection` — Fae's own TTS output → never self-triggers
- `enrollment_quality` — enrollment from 3 utterances → reliable identification

### 8. noise_resilience (audio)

Environmental robustness — Fae doesn't activate on non-speech.

**Sub-metrics:**
- `music_rejection` — music playing → no activation (target: >95%)
- `tv_rejection` — TV/video audio → no activation
- `environmental_rejection` — typing, doors, traffic → no activation
- `speech_in_noise` — owner speaks over music → still responds
- `silence_stability` — long silence → no false activation
- `noise_burst_recovery` — loud noise then speech → handles correctly

### 9. barge_in (audio)

Interruption handling — user can always break in.

**Sub-metrics:**
- `interrupt_latency_ms` — time from user speech to TTS stop (target: <500ms)
- `interrupt_reliability` — always stops when user speaks (target: >95%)
- `post_interrupt_response` — responds to the interruption content correctly
- `false_interrupt_rate` — doesn't stop for non-speech sounds (target: <5%)
- `mid_word_stop` — stops cleanly even mid-word, no audio artifacts
- `rapid_redirect` — "stop, tell me X instead" → pivots cleanly

### 10. resource_usage (measurement)

System resource efficiency during pipeline operation.

**Sub-metrics:**
- `idle_cpu_percent` — CPU usage when Fae is listening but idle
- `active_cpu_percent` — CPU during LLM generation
- `gpu_memory_mb` — GPU VRAM usage (model weights + KV cache)
- `rss_memory_mb` — Process RSS (total memory footprint)
- `inference_tps` — LLM tokens per second during generation
- `tts_rtf` — TTS real-time factor (< 1.0 = faster than real-time)

## Scenario Types

### Text Scenarios (inject via /inject)
Used for: responsiveness, conversation_quality, memory_pipeline, personality,
thinking_mode, capability_awareness.

Format: Same JSONL as current harness.

### Audio Scenarios (inject via /command inject_audio)
Used for: speaker_gate, noise_resilience, barge_in.

Format:
```json
{
  "id": "sg_owner_greeting",
  "dimension": "speaker_gate",
  "type": "audio",
  "audio_file": "audio/primary/greeting_hello.wav",
  "expect_response": true,
  "expect_response_contains": ["hello", "hi", "hey"],
  "max_latency_ms": 10000
}
```

### Resource Scenarios (measurement via ps/top)
Used for: resource_usage.

Format:
```json
{
  "id": "ru_idle_baseline",
  "dimension": "resource_usage",
  "type": "resource",
  "phase": "idle",
  "duration_ms": 10000,
  "metrics": ["cpu", "rss", "gpu_mem"]
}
```

## Audio Test Corpus

Generated via macOS `say` command + ffmpeg conversion to 16kHz mono WAV.

**Voices:**
- Primary user: `Daniel` (en_GB male) — enrolled as owner
- Secondary (stranger): `Karen` (en_AU female) — not enrolled
- Tertiary (stranger): `Fred` (en_US male) — not enrolled
- Background conversation: `Moira` (en_IE female) — for multi-speaker context

**Audio categories:**
```
autoresearch/audio/
  primary/          # Daniel voice — enrolled owner
  stranger/         # Karen/Fred voices — not enrolled
  noise/            # Music, environmental sounds
  mixed/            # Speech over noise
  interrupt/        # Short interrupt phrases
  enrollment/       # Enrollment utterances
```

## Pipeline Test Flow

### Phase 0: Setup
1. Launch Fae with --test-server + FAE_DISABLE_STREAMING_ASR=1
2. Wait for health=ok
3. Disable direct-address gating
4. Disable proactive awareness
5. Mute microphone (for audio injection — prevents echo)
6. Warmup LLM with greeting

### Phase 1: Speaker Enrollment
1. Inject 3 enrollment audio clips (Daniel voice)
2. Trigger voice enrollment via text command
3. Verify enrollment succeeded
4. Verify owner profile exists

### Phase 2: Text Dimensions
Run text-injection scenarios for:
- responsiveness, conversation_quality, memory_pipeline
- personality, thinking_mode, capability_awareness

### Phase 3: Audio Dimensions (post-enrollment)
Run audio-injection scenarios for:
- speaker_gate, noise_resilience, barge_in

### Phase 4: Resource Measurement
Sample CPU/GPU/memory during:
- Idle (listening, no speech)
- Active (LLM generating)
- TTS (speaking)

## Scoring

Each sub-metric scores 0-100. Dimension score = weighted average of sub-metrics.

**Weights by dimension (total = 100):**
- responsiveness: 15
- conversation_quality: 15
- memory_pipeline: 15
- personality: 10
- thinking_mode: 10
- capability_awareness: 10
- speaker_gate: 10
- noise_resilience: 5
- barge_in: 5
- resource_usage: 5

**Overall target: all dimensions ≥ 85/100.**

## Modification Strategy

When a dimension scores below 85, work through layers in order:

### Layer 1: Parameters
- VAD thresholds (vad.threshold, minSilenceDurationMs)
- Speaker thresholds (owner 0.75, guest 0.70)
- Barge-in sensitivity (minRms, confirmMs)
- Echo suppression parameters
- LLM temperature, maxTokens
- Memory recall count (maxRecallResults)

### Layer 2: Prompts
- Core voice prompt (PersonalityManager layer 1)
- Tool schema descriptions
- SOUL.md personality contract
- Skill descriptions in prompt

### Layer 3: Code
- PipelineCoordinator timing/gating logic
- EchoSuppressor algorithms
- TextProcessing name corrections
- MemoryOrchestrator recall weighting
- VoiceActivityDetector thresholds
- SpeakerProfileStore matching

## Constraints

1. Never modify TestServer.swift
2. Never execute tools during scenarios (test knowledge only)
3. Max 5 attempts per sub-metric before moving on
4. Always commit improvements before trying next change
5. Revert if any dimension regresses > 5 points
6. Zero .unwrap() or panic!() in production code
7. All Python via uv run
