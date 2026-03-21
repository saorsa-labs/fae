# Phase 4.3: Integration & Acoustic Testing

## Goal
Comprehensive regression testing and documentation of echo handling capabilities and limitations.

## Tasks

### Task 1: Synthetic Echo Test Scenarios
Create deterministic test cases with synthetic echo patterns:
- Simulated speaker bleedthrough at various delays and attenuation levels
- Near-field vs far-field echo simulation
- Overlapping user speech + echo scenarios

**Files**: `Tests/HandoffTests/EchoHandlingHardeningTests.swift`

### Task 2: Test Matrix Documentation
Document expected behavior for each audio output scenario:
- Headphones (wired/wireless): minimal echo, relaxed suppression
- MacBook built-in speakers: moderate echo, aggressive suppression
- External speakers: variable echo, adaptive suppression

### Task 3: Regression Test Suite
Ensure all existing echo suppression tests still pass. Add regression tests for known edge cases from milestones 1-3.

### Task 4: Milestone Closeout
Create `.planning/reviews/milestone-4-echo-handling.md` with:
- What shipped vs planned
- Measured improvements
- Known limitations (especially speaker-out)
- Recommendations for future work

### Task 5: Project Closeout
Create `.planning/reviews/project-closeout-voice-pipeline-hardening.md` covering all 4 milestones.

## Success Criteria
- Full test suite passes
- All scenarios documented
- Honest assessment of speaker-out limitations
- Project closeout complete
