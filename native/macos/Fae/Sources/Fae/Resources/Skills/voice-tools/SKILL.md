---
name: voice-tools
description: Audio processing utilities for voice samples. Normalize audio levels, prepare voice samples for cloning, compare voice similarity, and check recording quality.
metadata:
  author: fae
  version: "1.0"
---

Voice tools for audio processing and voice sample preparation.

## Available Scripts

### audio_normalize
Normalize audio to target LUFS (-16 dB), convert to 24kHz mono WAV.

Usage: `run_skill` with name `voice-tools` and input `{"script": "audio_normalize", "input": "/path/to/audio.wav"}`

Optional params: `audio_output_dir` (default: /tmp)

### prepare_voice_sample
Convert any audio to 24kHz mono PCM WAV and extract the best 3-second voiced segment for voice cloning.

Usage: `run_skill` with name `voice-tools` and input `{"script": "prepare_voice_sample", "input": "/path/to/audio.wav"}`

### voice_compare
Compare two audio files using MFCC + DTW and return a similarity score (0-1).

Usage: `run_skill` with name `voice-tools` and input `{"script": "voice_compare", "input": "/path/a.wav, /path/b.wav"}`

### voice_quality_check
Analyze voice recording quality: SNR, clipping, silence ratio, frequency range (F0).

Usage: `run_skill` with name `voice-tools` and input `{"script": "voice_quality_check", "input": "/path/to/audio.wav"}`

## When to Use

- User wants to prepare audio for voice cloning → `prepare_voice_sample`
- User wants to normalize audio levels → `audio_normalize`
- User wants to compare two voice recordings → `voice_compare`
- User asks about recording quality or troubleshoots audio → `voice_quality_check`
