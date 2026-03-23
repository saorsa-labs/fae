# Conversational AutoResearch Program

## Philosophy

This is NOT a test script. It's an AI-to-AI conversation where Claude evaluates
Fae's responses as a thoughtful friend would — judging warmth, accuracy, speed,
and naturalness. Each interaction is scored, issues are diagnosed, fixes are
attempted, and improvements are measured.

## Dimensions & Acceptance Criteria

### 1. Voice Pipeline (speaker→mic)
- **Wake word**: "Fae" detected in speech (acoustic sim >0.70)
- **STT accuracy**: transcription matches intent (>90% word accuracy)
- **Speaker match**: owner voice recognized (sim >threshold)
- **Latency**: STT complete <3s after speech ends

### 2. Stranger Rejection
- Non-owner voice → no response
- Different TTS voice through speakers → rejected
- Owner voice after stranger → still accepted

### 3. Noise Resilience
- Pink/white noise → no activation
- Music → no activation
- Speech after noise → still responds
- Background noise during conversation → doesn't interrupt

### 4. Barge-In
- User speaks while Fae is talking → Fae stops
- Redirect after interrupt → responds to new request
- "Stop" during speech → immediate stop

### 5. Conversation Quality
- Greeting: warm, personal, uses name if known
- Multi-turn coherence: maintains context across turns
- Pronoun resolution: "it" refers to previous topic
- Topic switching: handles gracefully
- Brevity: spoken-word length, not essay

### 6. Memory
- Store: name, preferences, facts, relationships
- Recall: accurately retrieves stored info
- Correction: "actually it's X not Y" → updates
- Cross-session: persists across restarts

### 7. Personality
- Warmth/empathy: responds to emotions appropriately
- Humor: tells jokes when asked
- Identity: knows she's Fae, Scottish roots
- No AI slop: no "Great question!", "Absolutely!"

### 8. Tool Calling
- Read tools: calendar, reminders, contacts, mail, notes
- Write tools: reminder create, self-config, calendar create
- Follow-up: acknowledges tool results naturally
- Auto-approve: owner voice skips approval prompt
- Tool name normalization: handles "tool=action" format

### 9. Skills
- Skill listing: manage_skill returns installed skills
- Skill activation: activate_skill loads skill context
- Skill execution: run_skill executes Python/instruction skills

### 10. Self-Improvement
- Self-config: speed, temperature, thinking mode
- Directive: set/append/clear directive
- Config persists across turns

### 11. Web & Research
- Web search: queries web, summarizes results
- URL fetch: retrieves page content
- Multi-tool chains: search → fetch → summarize

### 12. Vision
- Screenshot: captures screen without crash
- VLM description: describes what's on screen
- Camera: captures camera image (if permission)

## Metrics Per Interaction

| Metric | How Measured |
|--------|-------------|
| pass/fail | Did the interaction achieve its goal? |
| quality (0-10) | Subjective: warmth, accuracy, naturalness |
| TPS | From llm_token_throughput_tps in log |
| TTFT | Time from inject/speech to first token |
| E2E latency | Time from input to response complete |
| STT accuracy | Compare spoken text to transcription |
| Speaker sim | From speaker matched log |

## Test Method

For each dimension:
1. Inject text OR speak through speakers (via voice CLI)
2. Wait for response
3. Read conversation + log
4. Score pass/fail + quality + metrics
5. If fail: diagnose from log, attempt fix, re-test
6. If pass but slow: check params, tune, re-test
7. Commit improvements, move to next dimension

## Multi-Model Testing Matrix

Every dimension MUST be tested across all three model tiers. Performance
improvements apply to all tiers — a TPS fix benefits everyone.

| Model Preset | Active Params | Target RAM | Expected TPS | Target TPS |
|-------------|---------------|------------|-------------|------------|
| `saorsa_1_1_tiny` | 2B | <16 GB | TBD | 30+ |
| `qwen3_5_4b` | 4B | ≥16 GB | 17-23 | 25+ |
| `qwen3_5_35b_a3b` | 3B (MoE) | ≥32 GB | 4-6 (current) | 20+ |

### Model-Specific Behavior Expectations

| Dimension | 2B (tiny) | 4B | 35B-A3B |
|-----------|-----------|-----|---------|
| Tool calling | May need repair path | Mostly correct | Reliable |
| Tool interpretation | Direct reply only | Direct reply only | LLM interpretation |
| Hallucination risk | High | Medium | Low |
| Identity awareness | May miss | Needs prompting | Reliable |
| Memory recall | Basic | Good | Good |
| Multi-tool chains | Unlikely | Sometimes | Reliable |

### How to Switch Models

```bash
# In interactive.py, change FAE_VOICE_MODEL_PRESET:
"FAE_VOICE_MODEL_PRESET": "saorsa_1_1_tiny",   # 2B
"FAE_VOICE_MODEL_PRESET": "qwen3_5_4b",         # 4B
"FAE_VOICE_MODEL_PRESET": "qwen3_5_35b_a3b",    # 35B-A3B (MoE)
```

### TPS Optimization Priority

The 35B-A3B model should be getting 20+ TPS (community reports on similar
hardware), but we're seeing only 4-6 TPS. Investigate:
- MLX generation parameters (batch size, cache settings)
- TokenRing sampler overhead
- GPU memory allocation
- Unnecessary CPU synchronization
- Quantization settings (4-bit vs 8-bit)

Any TPS fix for the engine benefits ALL model tiers.

## Parameter Tuning Space

| Parameter | Current | Range | Impact |
|-----------|---------|-------|--------|
| speaker.threshold | 0.45 | 0.3-0.8 | False accept/reject rate |
| speaker.ownerThreshold | 0.50 | 0.4-0.8 | Owner recognition |
| llm.temperature | 0.5-0.7 | 0.3-1.0 | Response creativity |
| llm.maxTokens | 4096 | 1024-8192 | Response length |
| tts.speed | 1.1-1.2 | 0.8-1.4 | Speech pace |
| bargeIn.minRms | 0.05 | 0.01-0.15 | Interrupt sensitivity |
| bargeIn.confirmMs | 150 | 50-500 | Interrupt confirmation |
| vad.threshold | 0.30 | 0.1-0.5 | Speech detection |
| segmentStaleness | 30s | 10-60s | Long utterance support |
| approvalTimeout | 45s | 20-120s | Approval window |
