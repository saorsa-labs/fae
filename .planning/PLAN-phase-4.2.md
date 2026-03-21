# Phase 4.2: WebRTC AEC3 Evaluation

## Goal
Evaluate feasibility of integrating WebRTC AEC3 for proper acoustic echo cancellation, and document findings.

## Tasks

### Task 1: Feasibility Analysis — Reference Signal Access
Document whether macOS AVAudioEngine provides access to the playback reference signal needed by AEC. Investigate AudioPlaybackManager's ability to tap the output buffer.

### Task 2: Feasibility Analysis — WebRTC AEC3 API Compatibility
Investigate WebRTC's AEC3 C/C++ API and whether it can be wrapped for Swift. Assess binary size, licensing, build complexity.

### Task 3: Enhanced Heuristics (if AEC infeasible)
If AEC3 integration is infeasible (likely), enhance the heuristic stack instead:
- Cross-correlation between capture and recent playback audio
- Spectral subtraction using known TTS output spectrum
- Adaptive echo tail based on measured speaker-to-mic delay

**Files**: `EchoSuppressor.swift`, `AudioPlaybackManager.swift`

### Task 4: Documentation
Create `.planning/reviews/aec3-feasibility.md` documenting the evaluation, findings, and chosen approach.

## Success Criteria
- Clear feasibility assessment documented
- If infeasible: enhanced heuristics implemented and tested
- `swift build` zero warnings, `swift test` all pass
