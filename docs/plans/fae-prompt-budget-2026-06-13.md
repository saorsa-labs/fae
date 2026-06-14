# Fae Prompt-Budget — cut prompt tokens to fix latency + the NaN bug

**Date:** 2026-06-13
**Why:** Fae's LLM is local (Gemma via mistral.rs) — there is **no API cost** to
save. But prompt *length* is load-bearing for two real problems:
- **Latency**: measured 50–82s TTFA driven by full re-prefill (prefix cache off)
  + history growth. Prefill time scales with prompt tokens.
- **The NaN bug** ([mistral.rs#2214]): NaN logits occur at specific *total*
  prompt lengths. Shorter, stabler prompts dodge the bad windows.

This is the "save tokens" lever that actually pays off for a local-first product
— done **natively** in Fae's pipeline, no third-party proxy/compression model.
(Evaluated `chopratejas/headroom` 2026-06-13: good for paid-API agents, but a
Python proxy + compression model is an architectural mismatch for a local
Rust/Swift turn path with no API bill; context-mode already covers our dev
workflow. We adopt the *idea*, not the dependency.)

## Current state (verified 2026-06-13)

1. **All 36 tool specs ship in every request.** `DaemonWire.injectTextPayload`
   (`ML/DaemonLLMEngine.swift:214`) sends `daemonTools(from: options.tools ?? [])`
   — every tool's `{name, description, parameters}` on every turn. The NaN repro
   payload carried all 36. This is the single largest, most cuttable chunk.
2. **Memory recall is result-count-capped, not byte-capped.**
   `MemoryOrchestrator.recall` (`Memory/MemoryOrchestrator.swift:76`) caps by
   `maxRecallResults` (default 6) but pulls from several sources
   (`recentRecords` ×3/×4, entity hits, etc.) and returns an unbounded string
   injected into the system prompt. The NaN repro's system prompt was ~30K chars.
3. **Prefix cache is fully disabled.** `crates/fae-engine/src/mistralrs_adapter.rs`
   lines 39 & 57: `.with_prefix_cache_n(None)` on both load paths. The comment
   cites audio-turn correctness, but it's off for *all* turns — so every turn
   re-prefills the entire (large) prompt from scratch.

## The three levers (in priority order)

### Lever 1 — Progressive tool disclosure (biggest win)

Today every turn sends all 36 full tool schemas. We already do progressive
disclosure for **skills** (names+descriptions in prompt; full SKILL.md body only
on `activate_skill`). Apply the same to **tools**:

- Send the model a compact **tool index** (name + one-line description) for all
  tools, plus the **full `parameters` schema only for a working set** — the tools
  plausibly relevant to the turn (e.g. always-core tools + any recently used +
  any the turn's intent suggests). The model requests a tool by name; if it picks
  one whose full schema wasn't sent, do a cheap second pass that includes that
  tool's full schema (mirrors `activate_skill`).
- Conservative first cut if dynamic selection is risky: keep full schemas for the
  ~8–10 core tools (`read/write/edit/bash/self_config/web_search/...`), index-only
  for the long tail (Apple/scheduler/vision/computer-use), expand on demand.
- Measure: log total daemon-payload token count per turn before/after. Target a
  large reduction in the tools array on a typical turn.

**Risk:** tool-calling accuracy must not regress. Gate on FaeBenchmark tool-call
score (the harness that scored Gemma 4 E4B 100% on tool calling). No net
accuracy loss permitted.

### Lever 2 — Byte-budget the memory recall injection

- Add a hard character/token budget to the string `MemoryOrchestrator.recall`
  returns (e.g. cap at N tokens; default sized from `recommendedMaxHistory`
  math). Truncate lowest-ranked records first; keep the highest-relevance hits.
- Prefer the hybrid 60% ANN / 40% FTS5 top results; drop the `recentRecords ×3/×4`
  padding when the budget is tight.
- Surface the budget as a config knob (`memory.maxRecallTokens`) consistent with
  the existing `memory.maxRecallResults`.

**Risk:** don't starve recall — memory strength is a core objective. Tune the
budget so typical turns are unaffected; only very large recalls get trimmed.

### Lever 3 — Re-enable prefix caching where safe

- The prefix cache is off entirely. Re-enable it for the **text/tool prefix**
  (system prompt + tools + stable history) while keeping it off (or scoped) for
  the **audio-bearing** portion that empirically corrupted audio turns
  (`with_prefix_cache_n(None)` was added for that reason — confirm the exact
  failure before changing).
- A stable prefix is also what `headroom`'s "CacheAligner" chases — here it's
  free if the system-prompt + tool-index prefix is byte-stable across turns
  (don't reorder tools, don't inject timestamps into the prefix).
- This is the highest-leverage *latency* fix (re-prefill is the 50–82s driver),
  but the riskiest — it touches the daemon engine and the audio-correctness
  fix. Do it last, behind a flag, with the audio turn regression explicitly
  re-tested.

**Risk:** must not reintroduce the audio-turn corruption that disabling it cured.
Keep audio turns on the safe path; only the text prefix gets cached.

## Acceptance / evidence

- Per-turn daemon-payload token count logged before/after each lever; report the
  reduction on a representative turn (typical chat + a tool turn + an audio turn).
- FaeBenchmark tool-call + capability scores: **no regression** from Lever 1.
- A turn that previously hit a NaN window: show prompt length moved out of it
  (or padded-retry frequency dropped).
- TTFA on a warm multi-turn conversation: before/after (Lever 3).
- `cd crates && just check` + `just check --skip VocabularyHarvestTests` green;
  audio-turn correctness re-verified for Lever 3.

## Sequencing

Lever 1 (tools) first — biggest token cut, lowest engine risk. Lever 2 (memory
budget) second. Lever 3 (prefix cache) last, behind a flag, with the audio
regression gate. Each lands as its own commit/PR with the evidence above. This
is independent of the P1–P5 cross-platform track and can run in parallel.

[mistral.rs#2214]: https://github.com/EricLBuehler/mistral.rs/issues/2214
