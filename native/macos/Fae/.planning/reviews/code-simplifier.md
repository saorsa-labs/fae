# Code Simplification Review
**Date**: 2026-03-30
**Mode**: gsd — Phase 1.1

## Phase diff analysis (planning files only):
+193 added lines in planning files
-356 removed lines in planning files

## Existing generate() complexity in MLXLLMEngine.swift:
The generate() function is ~265 lines with two near-identical branches (shouldParseToolCalls).
Simplification opportunity: extract shared setup logic into a helper.

## Plan spec simplification concerns:
- PLAN-phase-1.1.md Task 1 spec says unloadAdapter uses 'self.currentAdapter!' force-unwrap — should be 'guard let adapter = currentAdapter else { return }' for zero-tolerance compliance
- swapAdapter spec (Task 4) has 3 conditional paths that could be written as early returns
- ModelManager wiring (Task 3) spec checks 3 conditions before loading — clean guard let pattern would simplify

## Findings
- [CRITICAL] No code to simplify — implementation not written yet.
- [LOW] When implementing, avoid duplicating the KV cache reset logic across loadAdapter, unloadAdapter, and swapAdapter — extract to private resetSessionForAdapterChange()
- [LOW] Consider MLXLLMEngine+Adapters.swift extension to keep the file manageable (<1000 lines)

## Grade: INCOMPLETE (no new code to simplify)
