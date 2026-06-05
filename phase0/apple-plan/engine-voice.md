# Apple-First Engine + Voice Plan — G2 Completion

> **Status:** Planning (Phase 0 context gathered)  
> **Goal:** Complete G2 engine parity proof and wire the full Apple voice loop for the Rust daemon  
> **Sources:** S13 spike, headless-core-impl-plan, bench/engine-parity, legacy/rust-core, ADR-001

---

## Executive Summary

The S13 spike **confirmed mistral.rs 0.8.1 as the primary engine**:

- ✅ Gemma-4 E4B: ~65 tok/s, tool calling, **unified audio STT in-process**
- ✅ Qwen3-14B dense: ~42 tok/s, tool calling (heavy driver)
- ❌ Gemma-4 26B-A4B MoE: does NOT run (candle gather unsupported)

**Remaining work:**
1. **G2 engine parity harness** — prove llama.cpp fallback via same `ProviderAdapter` contract
2. **Voice pipeline in Rust daemon** — port/wire cpal→VAD→STT→LLM→TTS→playback
3. **E4B/Qwen routing logic** — front model vs heavy driver selection
4. **Latency/voice parity gates** — meet ADR-002 SLOs before shipping

---

## 1. Engine Architecture (Post-S13)

### 1.1 Confirmed Stack

| Component | Primary | Fallback | Status |
|-----------|---------|----------|--------|
| **LLM Engine** | mistral.rs 0.8.1 (in-process) | llama.cpp via `llama-server` HTTP | S13 ✓ / G2 pending |
| **Front Model** | Gemma-4 E4B (~65 tok/s) | Qwen3-0.6B (smoke) | S13 ✓ |
| **Heavy Driver** | Qwen3-14B dense (~42 tok/s) | — | S13 ✓ (MoE blocked) |
| **STT** | E4B unified audio-in | Parakeet TDT 0.6B cascaded | S13 ✓ (both options) |
| **TTS** | Kokoro-82M via ort + misaki-rs | — | legacy ✓ |
| **VAD** | Silero (energy-based for now) | — | legacy ✓ |

### 1.2 E4B/Qwen Routing Logic

```
[user turn] → complexity check →
  if tool count ≤ 1 && prompt tokens < 2K:
    route to E4B (fast, ~65 tok/s)
  else:
    route to Qwen3-14B (heavy, ~42 tok/s)
```

Routing criteria to implement:
- **Token threshold:** ~2K prompt tokens triggers heavy driver
- **Tool complexity:** multi-tool chains → heavy driver
- **Reasoning mode:** `thinking=true` → heavy driver (Qwen3 CoT)
- **Audio input:** any audio clip → E4B (unified STT path)

---

## 2. G2 Tasks: Engine Parity Harness

### 2.1 Current State

- `bench/engine-parity/` scaffold exists with:
  - `lib.rs`: `ProviderAdapter` trait shape, `NormalizedToolCall`, parity check logic
  - `main.rs`: `check` and `render` CLI commands
  - `fixtures/weather-tool-call.json`: fixture proving schema
- **Does NOT yet have:**
  - Real `MistralrsAdapter` (must port 0.7→0.8)
  - Real `LlamaCppAdapter` (HTTP client to `llama-server`)
  - Actual model runs with results

### 2.2 G2 Implementation Tasks

| # | Task | LOC | Blocked On |
|---|------|-----|------------|
| **G2.1** | Add `mistralrs = "0.8"` + `tokio`, `reqwest`, `async-trait` to `bench/engine-parity/Cargo.toml` | ~15 | — |
| **G2.2** | Implement `MistralrsAdapter` (port `legacy/rust-core/src/fae_llm/providers/local.rs` 0.7→0.8) | ~150 | G2.1 |
| **G2.3** | Implement `LlamaCppAdapter` (HTTP POST to `llama-server /v1/chat/completions`) | ~100 | G2.1 |
| **G2.4** | Add `run` CLI command that: loads both adapters, runs same `ParityCase`, compares tool calls | ~100 | G2.2, G2.3 |
| **G2.5** | Smoke test with Qwen3-0.6B (both engines) | — | G2.4 + model download |
| **G2.6** | Full test with Gemma-4 E4B (tool calling parity) | — | G2.4 + 16GB download |
| **G2.7** | Document results in `bench/engine-parity/results/g2-results.md` | ~50 | G2.5/G2.6 |

**Total new code:** ~415 LOC

### 2.3 G2 Acceptance Criteria

```
G2 passes when:
  - `engine-parity run --model qwen3-0.6b --llama-endpoint http://localhost:8080`
    produces equivalent `get_weather({"city":"Paris"})` from both engines
  - Results document committed to bench/engine-parity/results/
  - No crashes, no panics
```

### 2.4 G2 Validation Commands

```bash
# 1. Build harness
cargo build --release --manifest-path bench/engine-parity/Cargo.toml

# 2. Start llama-server (separate terminal)
llama-server -m ~/.cache/huggingface/Qwen3-0.6B-Q4_K_M.gguf --port 8080 --chat-template qwen3

# 3. Run parity test
./target/release/engine-parity run \
  --mistralrs-model Qwen/Qwen3-0.6B \
  --llama-endpoint http://localhost:8080 \
  --output bench/engine-parity/results/qwen3-parity.json

# 4. Verify pass
./target/release/engine-parity check bench/engine-parity/results/qwen3-parity.json
echo $?  # 0 = pass

# 5. Render report
./target/release/engine-parity render bench/engine-parity/results/qwen3-parity.json \
  > bench/engine-parity/results/qwen3-parity.md
```

---

## 3. Voice Pipeline Tasks (Phase 2 prep)

### 3.1 Current Swift Stack (reference)

The Swift app (`native/macos/Fae/`) has a working voice pipeline:
- VAD: Silero v5 (MLX)
- STT: Qwen3-ASR-1.7B (MLX 4-bit)
- LLM: Qwen3.5/Gemma-4 (MLX 4-bit)
- TTS: Kokoro-82M (MLXAudioTTS float32)
- Speaker ID: ECAPA-TDNN (Core ML fp16)

### 3.2 Rust Daemon Voice Stack (to wire)

The legacy Rust code exists in `legacy/rust-core/src/`:

| Component | Legacy File | LOC | Port Status |
|-----------|-------------|-----|-------------|
| **Audio capture** | `audio/capture.rs` | ~180 | Ready — uses cpal |
| **Audio playback** | `audio/playback.rs` | ~230 | Ready — uses cpal |
| **VAD** | `vad/mod.rs` | ~200 | Energy-based (needs Silero ONNX upgrade) |
| **STT (Parakeet)** | `stt/mod.rs` | ~120 | Ready — `parakeet-rs` |
| **STT (E4B unified)** | — | ~80 (new) | Use `mistralrs::AudioInput` per S13 |
| **TTS (Kokoro)** | `tts/mod.rs` + kokoro | ~150 | Stale — needs `ort` + `misaki-rs` wiring |
| **Provider adapter** | `fae_llm/providers/local.rs` | ~350 | Port 0.7→0.8 |
| **Fallback chain** | `llm/fallback.rs` | ~180 | Ready |
| **Pipeline coordinator** | `pipeline/` | ~500 | Needs revival |

### 3.3 Voice Pipeline Tasks

| # | Task | LOC | Priority |
|---|------|-----|----------|
| **V1** | Port `LocalMistralrsAdapter` 0.7→0.8 (already S13-validated) | ~50 delta | P0 |
| **V2** | Wire E4B unified STT path (use `RequestBuilder::add_audio_message`) | ~80 | P0 |
| **V3** | Revive `CpalCapture` + `CpalPlayback` into daemon skeleton | ~60 | P0 |
| **V4** | Wire VAD → STT → LLM → TTS pipeline coordinator | ~200 | P0 |
| **V5** | Upgrade VAD to Silero ONNX (from energy-based) | ~100 | P1 |
| **V6** | Wire TTS Kokoro via `ort` + `misaki-rs` | ~150 | P0 |
| **V7** | Add barge-in via mic↔playback cross-correlation | ~100 | P1 |
| **V8** | Speaker ID gate (voiceprint check before tool execution) | ~80 | P2 |
| **V9** | Echo suppression (reference buffer + RMS ceiling) | ~80 | P1 |

**Total new/delta code:** ~900 LOC

### 3.4 E4B Unified STT Example (S13 validated)

```rust
// From bench/mistralrs-eval/src/main.rs — confirmed working
let clip = AudioInput::read_wav("audio.wav")?;
let request = RequestBuilder::new()
    .add_message(TextMessageRole::System, "Transcribe this audio.")
    .add_audio_message(TextMessageRole::User, "Transcribe:", vec![clip]);
let mut stream = model.stream_chat_request(request).await?;
// → transcript in response chunks
```

This replaces the cascaded Parakeet STT path when using E4B.

### 3.5 Cascaded Parakeet Fallback

For llama.cpp fallback (which can't do unified audio), use:
```rust
// legacy/rust-core/src/stt/mod.rs
let stt = ParakeetStt::new(&stt_config, &model_config)?;
let transcription = stt.transcribe(&speech_segment)?;
// → transcription.text into LLM
```

---

## 4. Latency / Voice Parity Gates

### 4.1 ADR-002 SLOs (target)

| Metric | SLO | Current (Swift) | Rust Target |
|--------|-----|-----------------|-------------|
| **TTFT** (time to first token) | < 500ms | ~300ms | < 500ms |
| **Decode rate** | > 30 tok/s | ~60 tok/s | > 40 tok/s |
| **STT latency** | < 1s | ~0.5s | < 1s |
| **TTS latency** | < 500ms | ~300ms | < 500ms |
| **End-to-end** (voice→voice) | < 3s | ~2s | < 3s |

### 4.2 Voice Parity Test (kill-criterion #3)

Before shipping Rust daemon as default:
1. Run same prompt through Swift MLX and Rust mistralrs
2. Compare TTFT, decode rate, end-to-end latency
3. Rust must be ≤1.5× slower than Swift on all metrics
4. TTS quality subjectively equivalent (same Kokoro voice)

### 4.3 Validation Commands (voice pipeline)

```bash
# 1. Build daemon (after Phase 1 skeleton exists)
cargo build --release -p fae-daemon

# 2. Voice latency test (measure TTFT + decode + TTS)
./target/release/fae-daemon voice-test \
  --audio tests/fixtures/hello.wav \
  --output bench/voice-latency.json

# 3. Check SLOs
jq '.ttft_ms < 500 and .decode_tps > 40 and .tts_ms < 500' bench/voice-latency.json
# → true

# 4. Compare to Swift baseline
swift test --filter VoiceLatencyTests  # in native/macos/Fae
```

---

## 5. Implementation Phases

### Phase 0a: G2 Engine Parity (required before Phase 1)

```
[ ] G2.1 - Update bench/engine-parity/Cargo.toml with mistralrs + reqwest
[ ] G2.2 - Implement MistralrsAdapter (port local.rs 0.7→0.8)
[ ] G2.3 - Implement LlamaCppAdapter (HTTP to llama-server)
[ ] G2.4 - Add `run` CLI command
[ ] G2.5 - Smoke test Qwen3-0.6B parity
[ ] G2.6 - Full test Gemma-4 E4B tool parity
[ ] G2.7 - Document results → bench/engine-parity/results/g2-results.md
[ ] Owner sign-off: G2 passed
```

### Phase 1: Core Skeleton + Engine (post-G2)

```
[ ] Daemon skeleton (tokio, WebSocket, Unix socket)
[ ] Port LocalMistralrsAdapter 0.7→0.8 into daemon
[ ] Wire FallbackChain with LlamaCppAdapter
[ ] Load E4B (front) + Qwen3-14B (driver)
[ ] Acceptance: text turn → streamed tokens + tool call
```

### Phase 2: Voice Pipeline + Parity

```
[ ] V1 - Provider adapter 0.7→0.8 port
[ ] V2 - E4B unified STT path
[ ] V3 - cpal capture + playback
[ ] V4 - Pipeline coordinator
[ ] V5 - Silero ONNX VAD
[ ] V6 - Kokoro TTS via ort
[ ] V7 - Barge-in (deferred to P1)
[ ] V8 - Speaker ID gate (deferred to P2)
[ ] V9 - Echo suppression (deferred to P1)
[ ] Voice parity test: Rust ≤1.5× Swift on all SLOs
```

---

## 6. Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| **Gemma-4 26B-A4B MoE blocked** | High | Use Qwen3-14B dense as heavy driver; MoE is a nice-to-have |
| **llama.cpp sidecar complexity** | Medium | Use `llama-server` HTTP (proven); defer FFI |
| **TTS Kokoro latency** | Medium | Keep clause-level streaming; parallelize with LLM decode |
| **VAD false triggers** | Medium | Silero ONNX upgrade; speaker ID gate |
| **cpal + audio threading** | Medium | Existing code works; test on fresh daemon |
| **Model download sizes** | Low | Qwen3-0.6B for smoke; E4B 16GB one-time |

---

## 7. File References

### Existing Code (reuse/port)

| File | Purpose | Action |
|------|---------|--------|
| `bench/mistralrs-eval/src/main.rs` | S13 harness (0.8 API) | Reference |
| `bench/engine-parity/src/lib.rs` | Parity types/check | Extend |
| `legacy/rust-core/src/fae_llm/providers/local.rs` | mistralrs 0.7 adapter | Port to 0.8 |
| `legacy/rust-core/src/fae_llm/provider.rs` | `ProviderAdapter` trait | Copy |
| `legacy/rust-core/src/llm/fallback.rs` | `FallbackChain` | Copy |
| `legacy/rust-core/src/stt/mod.rs` | Parakeet STT | Copy |
| `legacy/rust-core/src/audio/capture.rs` | cpal mic | Copy |
| `legacy/rust-core/src/audio/playback.rs` | cpal speaker | Copy |
| `legacy/rust-core/src/vad/mod.rs` | Energy VAD | Copy + upgrade |

### Design Documents

| File | Purpose |
|------|---------|
| `docs/spikes/S13-mistralrs-eval.md` | Engine decision evidence |
| `docs/architecture/headless-core-impl-plan-2026-06-01.md` | Phase gates |
| `phase0/plans/g2-fallback-proof.md` | G2 detailed plan |
| `docs/adr/001-cascaded-voice-pipeline.md` | Voice architecture |

---

## 8. Summary

**G2 completion (~415 LOC):**
- Port `MistralrsAdapter` 0.7→0.8
- Implement `LlamaCppAdapter` (HTTP)
- Run parity test, document results

**Voice pipeline (~900 LOC):**
- Wire cpal → VAD → E4B STT → LLM → Kokoro TTS → playback
- Meet ADR-002 latency SLOs
- Voice parity gate: Rust ≤1.5× Swift

**Models:**
- Primary: Gemma-4 E4B (unified STT+VLM+LLM+tools)
- Heavy: Qwen3-14B dense (complex turns)
- Fallback: llama-server HTTP for llama.cpp

**No fork needed** for mistral.rs/candle — E4B path works, Qwen3-14B dense works, MoE is deferred.
