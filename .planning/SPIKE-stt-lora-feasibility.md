# Feasibility Spike: LoRA Fine-Tuning Qwen3-ASR with MLX

**Date**: 2026-03-31
**Phase**: 3.0 (Voice Experience Overhaul)
**Design doc**: `~/.gstack/projects/saorsa-labs-fae/davidirvine-main-design-20260331-151032.md`

---

## VERDICT: NOT_FEASIBLE

LoRA fine-tuning Qwen3-ASR on MLX is not feasible today. No MLX tooling supports fine-tuning encoder-decoder ASR models. The gap is architectural, not a missing flag.

---

## Evidence

### 1. mlx-lm LoRA: decoder-only, no encoder-decoder support

`mlx_lm.lora` exclusively supports causal (decoder-only) LLMs. The supported model list (`LORA.md`) is: Mistral, Llama, Phi2, Mixtral, Qwen2, Gemma, OLMo, MiniCPM, InternLM2. The entire `mlx_lm/models/` directory (100+ files) contains zero encoder-decoder architectures. The training loop assumes next-token prediction on text tokens with no provision for audio input encoding.

Qwen3-ASR-1.7B is `Qwen3ASRForConditionalGeneration` — a conditional generation (encoder-decoder) model with:
- An **audio encoder** (Whisper-style, `d_model: 1024`, conv layers, GELU)
- A **text decoder** (Qwen3-based causal LM via `thinker_config`)

This is architecturally incompatible with `mlx_lm.lora`.

### 2. mlx-audio: inference-only, no fine-tuning

mlx-audio (by Blaizzy, `pip install mlx-audio`) supports STT/TTS/STS inference but has zero training capability.

- **Issue #28** (Mar 2025, open): "Training?" — maintainer responded "Not yet. Still need to add a few models, add batch processing and create a standard trainer."
- **Issue #346** (Dec 2025, open): "Finetuning" — maintainer confirmed plans but was "waiting to see which type of models would become more common."
- As of March 2026: still not implemented.

### 3. mlx-tune: LLM-only, no ASR support

mlx-tune (ARahim3, 943 stars) supports SFT/DPO/GRPO and vision fine-tuning for LLMs. Zero mentions of Whisper, encoder-decoder, or ASR in issues or docs.

### 4. No existing Qwen3-ASR LoRA adapters

Searched HuggingFace for "qwen3-asr lora mlx", "qwen-asr mlx lora" — zero results. The mlx-community has quantized Qwen3-ASR variants (4-bit through bf16) but no LoRA adapters.

### 5. One unmerged community attempt (stale)

mlx-examples **Issue #483** (Feb 2024): a user (adhulipa) submitted a complete LoRA implementation for OpenAI Whisper on MLX, targeting both encoder and decoder attention layers. **Never merged.** The code is 14+ months old and targets OpenAI Whisper, not Qwen3-ASR (different encoder architecture). Would require significant adaptation and may not work with current MLX versions.

### 6. PyTorch PEFT alternative: feasible but wrong tradeoff

PyTorch + PEFT (HuggingFace transformers) can LoRA fine-tune Whisper-architecture models on MPS backend. However:
- Requires Python runtime dependency (violates Fae's pure-Swift constraint)
- No existing MLX weight conversion pipeline for encoder-decoder LoRA adapters
- Training on MPS is ~3-5x slower than MLX for equivalent operations
- Would need a separate `torch` + `transformers` + `peft` installation (~2GB)
- Adapter weight format conversion from PyTorch to MLX is non-trivial with no existing tooling for encoder-decoder models

**Not recommended** given the complexity-to-benefit ratio and architecture constraints.

---

## Why This Won't Change Soon

The gap is structural. MLX's training ecosystem is built around the causal LM paradigm (next-token prediction on a single sequence). Encoder-decoder models require:
1. A separate forward pass through the audio encoder
2. Cross-attention between encoder outputs and decoder layers
3. A training loop that processes (audio, transcript) pairs, not text continuations

Adding this requires new training abstractions in mlx-lm or mlx-audio, not a flag change. The mlx-audio maintainer has acknowledged this but given no timeline.

**Earliest realistic availability**: 6-12 months, based on the pace of mlx-audio development and the complexity of the feature.

---

## Fallback Plan for Phase 3

Phase 3's goal is "Fae gets better at understanding YOUR specific voice over time." Without STT model adaptation, we pursue this through three complementary strategies that collectively address vocabulary accuracy, proper noun recognition, and endpointing quality.

### Fallback A: Aggressive DynamicVocabularyCorrector Expansion (PRIMARY)

**What**: Massively expand the post-ASR correction pipeline to cover more vocabulary from more sources.

**Current state**: `DynamicVocabularyCorrector` generates phonetic variants from owner name, entity graph, and speaker profiles. `PersonalLexicon` was added in Phase 2 with `ingestLexicon()`. `ASRConfidenceDetector` detects spelling divergence across utterances.

**Proposed expansion**:

1. **Contact-sourced vocabulary**: Import all names from macOS Contacts (already have `contacts` tool). Generate phonetic variants for every contact name. Rebuild on contact changes.

2. **Calendar-sourced vocabulary**: Extract proper nouns from upcoming calendar event titles and attendee names. Rebuild daily.

3. **Notes/document vocabulary**: Scan Apple Notes for proper nouns, project names, technical terms. Tag as `lexicon:notes`.

4. **Typed correction learning**: When user types a correction in the input card (already captured by `CorrectionDetector`), weight those corrections highest. Current `addCorrectionPair()` does this but could track frequency to prioritize high-frequency corrections.

5. **Conversation-frequency weighting**: Track how often each name/term appears in conversation. High-frequency terms get priority in correction matching (sort by frequency, not just pattern length).

6. **Multi-word phrase correction**: Current corrector operates on single words. Extend to 2-3 word phrases (e.g., "San Francisco" misheard as "San Fran Cisco").

7. **ASR confidence → proactive spelling prompt**: When `ASRConfidenceDetector` flags divergent spellings, Fae asks "Could you type that name for me?" (already designed, currently limited to 1 prompt/conversation — increase to 3).

**Addresses**: Proper noun accuracy, vocabulary gaps. Does NOT address accent-related phoneme confusion on common words.

**Effort**: ~2-3 hours Claude Code time. Builds on existing infrastructure.

### Fallback B: Per-Speaker Endpointing Calibration (SECONDARY)

**What**: Tune VAD and endpointing thresholds based on observed speech patterns per speaker.

**Rationale**: Accented speakers often have different pause patterns, speaking rates, and prosody. A Scottish speaker may have longer inter-word pauses than an American English speaker. Fixed endpointing thresholds cause premature cutoffs or excessive waits.

**Implementation**:
1. Track per-speaker statistics: average pause duration, speaking rate (words/second), typical utterance length
2. Store in `SpeakerProfileStore` alongside embeddings
3. Adjust `SileroVAD` silence threshold and `PipelineCoordinator` endpointing window per speaker
4. Use `MLXTurnDetector` (already exists, Qwen2.5-0.5B-based) for semantic endpointing — this is accent-agnostic since it operates on token sequences, not acoustics

**Addresses**: Premature cutoffs and missed utterance boundaries for non-standard speech patterns.

**Effort**: ~1-2 hours Claude Code time.

### Fallback C: Correction-Pair Accumulation for Future Training (DEFERRED INVESTMENT)

**What**: Silently accumulate (wrong_transcript, correct_transcript) pairs from `CorrectionDetector` events, stored in `ImprovementStore`. When MLX tooling eventually supports encoder-decoder LoRA, the training data is ready.

**Implementation**:
1. On each `CorrectionDetector` event, store the audio segment hash + wrong transcript + correct transcript in `improvement.db`
2. Optionally store the raw audio segment (privacy-controlled, same lifecycle as `speech_cache/`)
3. Export as SFT pairs when training becomes feasible

**Addresses**: Future-proofing. Zero user-visible benefit today, but eliminates data collection as a blocker when the tooling catches up.

**Effort**: ~30 minutes Claude Code time.

---

## What We Lose Without STT LoRA

| Capability | With LoRA | Without LoRA (fallbacks) |
|------------|-----------|------------------------|
| Proper noun accuracy | Model learns your names | Post-ASR correction (Fallback A) — 80% as good |
| Accent phoneme adaptation | Model adapts to your vowels/consonants | NOT addressed — common words stay at base accuracy |
| Speaking rate adaptation | Model adjusts decoding speed | Per-speaker endpointing (Fallback B) — partial |
| Background noise robustness | Model learns your acoustic environment | Room noise profiles (Phase 3.4, deferred) |

The main gap is **accent phoneme adaptation** — words like "water", "bath", "schedule" that are pronounced differently across dialects. The post-ASR corrector can't fix these because the correct word IS in the transcript, just wrong. This gap remains until MLX tooling matures.

---

## Recommended Next Step

**Build Fallback A (aggressive vocabulary expansion) as Phase 3.1.** This delivers the most user-visible improvement with the least risk, building entirely on existing infrastructure (`DynamicVocabularyCorrector`, `PersonalLexicon`, `ASRConfidenceDetector`, `CorrectionDetector`).

Sequence:
1. **Phase 3.1**: Contact/Calendar/Notes vocabulary import into `PersonalLexicon` → `DynamicVocabularyCorrector`
2. **Phase 3.2**: Per-speaker endpointing calibration (Fallback B)
3. **Phase 3.3**: Correction-pair accumulation (Fallback C) — lightweight, deferred investment
4. **Phase 3.4**: Room noise profiles — still deferred pending shadow mode data

**Re-evaluate LoRA feasibility**: Set a calendar reminder for Q3 2026 to check mlx-audio training support status. If `mlx-audio` ships a trainer or `mlx-lm` adds encoder-decoder support, revisit with the accumulated training data from Fallback C.

---

## Monitoring: When to Re-Evaluate

| Signal | Action |
|--------|--------|
| mlx-audio ships `fine_tune()` or `lora()` | Re-run this spike |
| mlx-lm adds encoder-decoder LoRA | Re-run this spike |
| mlx-examples merges Whisper LoRA PR | Evaluate for Qwen3-ASR compatibility |
| Qwen team releases official MLX fine-tuning guide | Follow their approach |
| Apple ships ASR fine-tuning in Create ML / Core ML | Evaluate as alternative to MLX |
