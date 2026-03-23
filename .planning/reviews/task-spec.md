# Task Specification Review
**Date**: 2026-03-21
**Phase**: 1.2 — Decode Path Hardening
**Task**: Review of task diff (autoresearch STATE.json updates + new Python ASR evaluation scripts)

## GSD State Analysis
{
  "version": 1,
  "project": "parakeet-streaming-asr",
  "active": true,
  "milestone": {
    "number": 1,
    "name": "Parakeet Streaming ASR — Production Ready"
  },
  "phase": {
    "number": "1.2",
    "name": "Decode Path Hardening",
    "plan": null
  },
  "progress": {
    "total_tasks": 0,
    "completed_tasks": 0,
    "current_task": null
  },
  "review": {
    "status": "reviewing",
    "iteration": 2,
    "last_verdict": null
  },
  "status": "reviewing",
  "last_updated": "2026-03-21T12:05:00Z",
  "phase_1_1_summary": "Tasks 1,2,4 implemented+committed. modelLoaded event, isCached check, env var gate testable. 7 new tests. Review in progress."
}

## Diff Assessment
The task diff contains:
1. `.planning/STATE.json` — GSD review state update (status: reviewing, iteration++)
2. `autoresearch/STATE.json` — Autoresearch metrics updated after 6 more evaluation runs (runCount 6→12)
3. `default.profraw` — Deleted binary profiling artifact (GOOD — should not be committed)

New untracked files:
- `asr_accuracy_eval.py` — ASR accuracy comparison script (Qwen3-ASR vs Parakeet)
- `asr_corpus/` — Test corpus (24 WAV+TXT pairs)
- `asr_generate_corpus.py` — Corpus generation script
- `asr_record_clips.py` — Audio recording script
- `asr_streaming_eval.py` — Streaming ASR evaluation

## Spec Compliance
Phase 1.2 (Decode Path Hardening) has no plan yet (plan: null).
The autoresearch work (ASR evaluation tooling) is complementary research, not task implementation.

Key metrics from autoresearch STATE.json:
- [CONCERN] barge_in score REGRESSED: 71.0 → 42.3 (pass_rate: 7%, latency 5.5s→25.7s)
- [POSITIVE] tool_execution improved: 23.8 → 41.9 (pass_rate: 13.9% → 69.4%)
- [POSITIVE] memory improved: 48.5 → 53.6 (pass_rate: 13.3% → 73.3%)
- [POSITIVE] voice_pipeline improved: 43.7 → 48.6 (pass_rate: 60% → 75%)

- [x] GSD state updated correctly
- [x] Profraw artifact deleted
- [ ] Phase 1.2 plan not yet created (plan: null) — expected pre-task

## Grade: B
