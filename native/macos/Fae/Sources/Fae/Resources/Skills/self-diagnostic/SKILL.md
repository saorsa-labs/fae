---
name: self-diagnostic
description: Deep pipeline diagnostic — lists every model loaded, system specs, audio config, speaker state, and flags anything missing or broken. Activate when asked to diagnose, debug, health check, or troubleshoot.
metadata:
  author: fae
  version: "2.0"
  tags:
    - system
    - diagnostics
    - debug
---

# Self-Diagnostic (Deep Pipeline Report)

You are running a comprehensive self-diagnostic. Work through EVERY section methodically. Report findings clearly in spoken language. Be specific about what IS loaded, what's MISSING, and what's BROKEN.

## 1. System Hardware

Use `bash` to gather machine specs:

```
bash "sysctl -n hw.model hw.memsize machdep.cpu.brand_string 2>/dev/null; echo '---'; system_profiler SPHardwareDataType 2>/dev/null | grep -E 'Model|Chip|Memory|Cores'"
```

Report:
- **Mac model** (e.g. Mac Studio M2 Max)
- **Chip** (M1/M2/M3/M4, Pro/Max/Ultra)
- **Total RAM** in GB (this determines model selection)
- **GPU cores** (affects inference speed)

```
bash "top -l 1 -n 0 | head -12; echo '---'; vm_stat | head -5"
```

Report: Current memory pressure, CPU load, swap usage. Flag if memory pressure is critical.

```
bash "df -h / | tail -1"
```

Report: Disk space. Flag if below 10 GB free (model downloads need space).

## 2. Full Model Pipeline — CRITICAL SECTION

This is the most important part. List EVERY model in the pipeline with its load status.

### 2a. Speech-to-Text (STT)

- **Model**: Qwen3-ASR-1.7B (MLX 4-bit)
- **Purpose**: Converts speech audio to text
- **Location**: Downloaded to `~/Library/Caches/fae/` by MLX on first launch
- Check: Am I understanding speech? If transcription is working, STT is loaded.
- If STT failed: I can only accept text input, not voice.

### 2b. Large Language Model (LLM) — the brain

- **Auto-selection based on RAM**:
  - ≥64 GB → Qwen3.5-35B-A3B MoE (128K context)
  - ≥32 GB → Qwen3.5-35B-A3B MoE (32K context)
  - ≥16 GB → Qwen3.5-4B (32K context)
  - <16 GB → saorsa-1.1-tiny 2B (32K context)
- **Purpose**: Conversation, reasoning, tool use
- Check: If I can respond to questions, LLM is loaded. Report which model.
- This is the CRITICAL engine — if it fails, nothing works.

### 2c. Text-to-Speech (TTS)

- **Model**: Kokoro-82M (KokoroSwift/MLX, float32)
- **Voice**: Pre-computed voice embeddings (fae.bin), 24 kHz output
- **Purpose**: Converts text responses to spoken audio
- Check: Am I speaking out loud? If yes, TTS is loaded.
- If TTS failed: I can only show text responses.

### 2d. Speaker Encoder (Voice Identity) — OFTEN BROKEN

- **Primary**: WeSpeaker ResNet34-LM (Core ML, 256-dim embeddings)
- **Legacy fallback**: ECAPA-TDNN (Core ML, 1024-dim)
- **Emergency fallback**: Mel-spectral statistics (640-dim) — DEGRADED, cannot distinguish speakers
- **Purpose**: Identifies WHO is speaking (owner vs stranger vs Fae echo)
- **Model file**: `wespeaker.mlmodelc` in Resources/Models/SpeakerEncoder/

```
bash "ls -la ~/Library/Application\\ Support/fae/speakers.json 2>/dev/null && python3 -c \"import json; d=json.load(open('$(echo ~/Library/Application\\ Support/fae/speakers.json)')); [print(f'{p[\\\"label\\\"]}: role={p[\\\"role\\\"]}, embeddings={len(p[\\\"embeddings\\\"])}, centroid_dim={len(p[\\\"centroid\\\"])}') for p in d]\" 2>/dev/null || echo 'No speaker profiles found'"
```

Check and report:
- Which encoder loaded? (WeSpeaker 256-dim = GOOD, mel-spectral 640-dim = BAD)
- Owner profile centroid dimension — does it match the loaded encoder?
- If dimensions mismatch: "Voice identity is broken — need to re-enroll"
- If mel-spectral fallback: "WeSpeaker model missing or failed to load — voice identity degraded, Fae responds to everyone"
- If no owner profile: "No voice enrolled — use the enrollment banner"

### 2e. Vision Language Model (VLM)

- **≥32 GB RAM**: Shares Qwen3.5-35B-A3B (same as LLM)
- **16 GB RAM**: Separate Qwen3-VL-4B
- **Purpose**: Camera observations, screenshot analysis
- Loaded on-demand (first camera/screenshot use)
- Check: Have I successfully analyzed any camera or screenshot images?

### 2f. Keyword Classifier (Barge-in)

- **Model**: 1D-CNN (~200K params, MLX float32)
- **Purpose**: Detects interrupt keywords during playback (5 classes: interrupt/wake/speech/silence/noise)
- Check: Can you interrupt me while I'm speaking? If yes, keyword detector works.

### 2g. Embedding Engine (Memory Search)

- **Model**: Hash-384 (MLX)
- **Purpose**: Semantic memory search (ANN vector similarity)
- Check: Can I recall relevant memories? If yes, embedding engine works.

### 2h. SileroVAD (Voice Activity Detection)

- **Model**: Silero VAD (ONNX)
- **Purpose**: Detects speech onset and offset in audio stream
- Check: Do I respond when you speak? If yes, VAD is working.

### 2i. Apple SoundAnalysis Classifier

- **Model**: Apple built-in (303 categories)
- **Purpose**: Rejects music, TV, and non-speech audio before speaker verification
- Check: Does Fae ignore TV/music in the background? If yes, classifier is active.

## 3. Audio Pipeline Configuration

```
bash "system_profiler SPAudioDataType 2>/dev/null | head -20"
```

Report:
- **Input device** (which microphone)
- **Sample rate** (should be 16 kHz after downsampling)

Check and report:
- **Apple Voice Processing**: Enabled or disabled? (Release builds = ON for noise suppression + AGC + AEC)
- **macOS Voice Isolation**: Is system mic mode set to "Voice Isolation"? (User controls via Control Center)
- **Software noise gate**: Active at 0.008 RMS floor
- **Echo suppressor**: Time-based (800ms) + text-overlap + fae_self voiceprint
- **Voiced detection threshold**: Floor at 0.008 (was 0.02 — check version)

## 4. Speaker Profile Status

Use `voice_identity check_status` to review:
- Is a primary user enrolled?
- How many profiles exist? (owner, fae_self, guests)
- Embedding dimensions for each profile
- Consistency score
- Any dimension mismatches with current encoder?

## 5. Scheduler & Awareness

```
scheduler_list
```

Report:
- Are camera presence checks running?
- Are screen activity checks running?
- Is overnight research enabled?
- Is enhanced morning briefing enabled?
- Any tasks in error state?

## 6. Memory Health

Report from context:
- Approximate record count
- Last digest time
- Entity graph status (persons/orgs/locations)
- Is embedding backfill complete?

## 7. Security & Permissions

```
bash "tail -10 ~/Library/Application\\ Support/fae/security-events.jsonl 2>/dev/null || echo 'No security log'"
```

Report: Recent security events. Flag any errors.

Check macOS permissions:
- Microphone access
- Camera access
- Screen Recording
- Accessibility (for computer use tools)

## 8. Summary Report

Structure your spoken summary as:

**"Here's my full diagnostic report:"**

1. **Machine**: [model, chip, RAM]
2. **Models loaded**: List each with status (✓ loaded / ⚠ fallback / ✗ missing)
   - STT: [status]
   - LLM: [model name, context size]
   - TTS: [status, voice]
   - Speaker: [encoder type, dimension] — **flag if mel-spectral**
   - VLM: [status]
   - VAD: [status]
   - Keyword: [status]
   - Embedding: [status]
3. **Audio**: [VP on/off, Voice Isolation on/off, noise gate active]
4. **Voice identity**: [owner enrolled, profile health, dimension match]
5. **Issues found**: List each with severity and fix
6. **Recommendations**: What the user should do

### Common Fixes to Suggest

| Issue | Fix |
|-------|-----|
| Mel-spectral fallback | "WeSpeaker model not loading — update to latest version or reinstall" |
| Dimension mismatch | "Re-enroll your voice — tap the enrollment banner" |
| No owner profile | "I need to learn your voice — tap 'Let me get to know you'" |
| Low disk space | "Free up disk space — I need room for model downloads" |
| Voice Isolation off | "Switch to Voice Isolation in Control Center for cleaner audio" |
| VP disabled (dev mode) | "You're in dev mode — Voice Processing is disabled for testing" |
| Stale scheduler tasks | "Some background tasks haven't run — try restarting me" |

End with: **"That's the full picture. Let me know if you want me to dig deeper into anything."**
