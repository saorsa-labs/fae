# TODOS

## Prerequisites for Autonomous Self-Improvement Loop

### TODO: Add adapter deployment mechanism (deploy path)
**What:** Add `training.personalAdapterPath` to SelfConfigTool adjustable keys + FaeCore.patchConfig case + PipelineCoordinator adapter reload observer.
**Why:** Codex found deploy.py is dead code (prints instructions for a config key that doesn't exist). Without this, trained adapters can never be deployed, manually or automatically. Hard blocker.
**Pros:** Unblocks both manual and automatic adapter deployment. Small change (~3 files: BuiltinTools.swift, FaeCore.swift, PipelineCoordinator.swift).
**Cons:** None. Required prerequisite.
**Context:** SelfConfigTool (BuiltinTools.swift:284) has a whitelist of adjustable keys. `training.personalAdapterPath` is not in it. FaeCore.patchConfig() has switch cases for each adjustable key but no adapter path case. PipelineCoordinator derives the active model from voiceModelPreset (line 1482) and has no mechanism to observe adapter path changes and reload the engine.
**Depends on:** MLXLLMEngine LoRA adapter loading support.
**Added:** 2026-03-30 (eng review)

### TODO: Add --adapter flag to FaeBenchmark
**What:** Add `--adapter <path>` CLI flag to FaeBenchmark that loads a LoRA adapter on top of the base model and runs the full eval suite for before/after comparison.
**Why:** The improvement loop needs to measure whether training actually improved the model. FaeBenchmark currently only accepts `--model` (HuggingFace model ID). Without adapter comparison, the eval gate (core safety mechanism) can't function.
**Pros:** Enables the eval gate. Reuses existing FaeBenchmark infrastructure (same test suites, same JSON output format).
**Cons:** FaeBenchmark is built via xcodebuild, slightly more build complexity than a simple CLI tool.
**Context:** FaeBenchmark/main.swift already parses `--model` and `--output` flags. Add `--adapter` that passes the path to MLXLLMEngine.load(modelID:adapterPath:). Run eval twice (base, then adapter), output comparison JSON with per-metric deltas.
**Depends on:** MLXLLMEngine LoRA adapter loading support.
**Added:** 2026-03-30 (eng review)

## Post-MVP Improvements

### TODO: Improvement Dashboard in Settings
**What:** Settings tab showing a timeline of Fae's self-improvement: every training cycle (date, data size, eval scores), every adapter deployed (before/after metrics), every directive amendment (what changed, why), every capability gap detected.
**Why:** Invisible improvement needs VISIBLE evidence to build trust. A parent should be able to open Settings and see "Fae has improved 14 times since you installed her. Here's how." Closes the trust-through-transparency loop.
**Pros:** Builds user confidence in the improvement system. Makes the "learning companion" value proposition tangible. Read-only UI over existing ImprovementStore data.
**Cons:** Adds a Settings tab. Needs design work for the timeline presentation.
**Context:** ImprovementStore (improvement.db) already tracks all cycle data. Settings infrastructure exists (16 Settings tab files). This is a read-only SwiftUI view over existing data. Follow DESIGN.md for Scottish palette, Instrument Serif headers.
**Effort estimate:** M (human) → S with CC+gstack (~3-4 hours)
**Priority:** P2
**Depends on:** ImprovementCycleCoordinator + ImprovementStore (Phase 1 of improvement loop)
**Added:** 2026-03-30 (CEO review, deferred from selective expansion)
