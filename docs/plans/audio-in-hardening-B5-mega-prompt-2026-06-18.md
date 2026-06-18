# Mega-prompt — audio-in hardening + STT reliability decision (P2 / gap B5)

> ## ✅ Round-1 PARTIAL landed (commit a6338649, 2026-06-18) — CONTINUATION scope below
> Done + committed: the **degraded-path gate** (`assessAudioTranscript`, 14 tests, reviewer-verified —
> bad transcript → "(unclear audio) … say it again", never a confident mis-heard answer); a
> **reproducible evaluator + 28-clip corpus** (`autoresearch/asr_b5_eval.py`, `asr_corpus/`); the
> **measurement + decision**: Gemma/mmproj FAILS (overall WER 17%, clean 20.8%, vocab 57.1%) — real
> correction-proof failures (`France→Paris` answer-not-transcribe, `Call Sarah→call sar`,
> `F A E→Stella F A A`); context-budget check. **REMAINING (do these in order):**
> 2. ✅ **DONE (commit d28f701d): stricter pass-1 verbatim prompt.** Fixed `France→Paris`
>    (answer-not-transcribe); overall WER 17→15.1%, clean 20.8→12.5% (still fails). BUT vocab regressed
>    57.1→42.9% (literal prompt worsens names: `David→Dayed`); and `Stop→"start"` now passes the gate
>    (was safely rejected). Confirms prompt tuning alone can't reach the bar.
> 1. ⛔ **THE GATING NEXT STEP (skipped twice — DO THIS BEFORE ANY FALLBACK WIRING): re-measure through
>    the FULL APP path** (TestServer audio inject) so `DynamicVocabularyCorrector` (owner/entity/speaker
>    vocab) is applied. Every WER/vocab number so far is daemon-only and OMITS the corrector that is
>    built to fix exactly the `David→Dayed`/dropped-`Fae` garbles driving the vocab failure — so the real
>    vocab accuracy is unknown. The bar is judged on THIS table, not the daemon eval. Either drive the
>    corpus through the running app (TestServer audio) and read the final post-correction `[heard]`, OR
>    instantiate `DynamicVocabularyCorrector` in the eval harness with a representative owner/entity vocab.
> 3. **Only if #1 still fails the bar:** wire the integrity-gated **Qwen3-ASR or whisper.cpp** fallback
>    under the llama.cpp sidecar (SHA-pinned, fail-closed), re-measure on the same corpus. (Note: some
>    failures — truncations like `Call Sarah→call sa`, `Stop→start` — won't be fixed by correction and
>    do argue for the fallback; #1 quantifies how many remain.)
> 4. **Live bundled-app proof**: real audio turns → correct `[heard]` → answer → TTS + `ORB_MODE`→Speaking.
> The original prompt below is the full context.

# (original prompt) Mega-prompt — audio-in hardening + STT reliability decision (P2 / gap B5)

Paste into a fresh session. Self-contained; **verify every claim against the repo and live/measured
output** — static-only review has missed a release-blocking bug on this work, and agents have fabricated
reports. The reviewer re-runs your evidence.

---

## Workflow — read first

**You (the team) implement AND test to completion, then HAND BACK for review. You do NOT commit/push.**
The reviewer verifies against measured data + live output, then commits + publishes.

1. **Measure first, then decide, then harden** (see "The work").
2. **Evidence floor**: `git diff --stat`; `env -u RUSTFLAGS` fmt/clippy `-D warnings`/nextest for touched
   crates; `swift build` clean; and the **measured WER/accuracy table** + the **live app audio turn**.
3. **Heed the bundling trap** (full bundle/embed/sign chain). Confirm live behaviour, not the diff.
4. **Hand back** a report with the measurement table, the decision + its data, and deviations. Flag
   anything unverifiable; do not paper over it. This is a **correctness-first** phase — a voice assistant
   that mis-hears is worse than one that asks again.

---

## Objective

Make Fae's **audio-in (push-to-talk → `[heard]` transcript) reliable and cross-platform**, and **decide
the STT path with data**. Today the daemon transcribes via Gemma-4's BF16 audio mmproj (two-pass). It's
wired and loads, but it has only ever been proven on **single clean clips** — there is no reliability
measurement, and the upstream path is known-finicky (llama.cpp #21820 bad transcripts, #21868 server
routing; WER ~4.17% clean, worse on noisy/spontaneous mic). B5 establishes a measured bar, picks the
path (keep Gemma mmproj, or fall back to **Qwen3-ASR / whisper.cpp** — both cross-platform under
llama.cpp), and defines safe degraded behaviour. (Roadmap phase P2; B1.5 landed, so the app now runs on
the llama.cpp daemon — audio turns go app→daemon.)

---

## What exists (build on it — DO NOT rebuild)

- **Two-pass audio** (`DaemonLLMEngine.runAudioTurn`, ~line 829): pass 1 transcribes the WAV via the
  Gemma mmproj → `flattenTranscript` → `[heard]: <transcript>`; pass 2 reasons on that transcript as
  text. **Two-pass is deliberate** (Gemma buries the transcript in reasoning/tool markup on single-pass
  — see `project_daemon_audio_asr_rootcause`). Do NOT revert to single-pass.
- **mmproj loaded** (B1): daemon log shows `process_mtmd` + `loaded multimodal model … mmproj-BF16.gguf`.
- **Replay harnesses**: `crates/fae-engine/examples/asr_isolation.rs` + `asr_replay.rs` — replay a WAV
  through the engine/mmproj WITHOUT a live mic. This is your measurement path (no microphone needed).
- **Vocab correction on `[heard]`**: `Pipeline/TextProcessing.swift` (static name fixes) +
  `DynamicVocabularyCorrector.swift` (phonetic variants from owner/entity/speaker names) +
  `CorrectionDetector.swift`. **Measure WER on the FINAL post-correction `[heard]`** — that's what the
  user and memory actually see.
- **Audio inject for live test**: the test-server / `FaeCore` audio-inject command (used in B1.5 with
  `/tmp/fae-p1-audio.wav`) drives a WAV turn through the real app pipeline.

---

## The work

### 1. Build a representative WAV corpus + measure (no live mic needed)
- Assemble a WAV test set that reflects real Fae use, not one clean clip:
  - **clean** short commands/questions; **noisy** (background/room); **accented**; **spontaneous**
    (disfluencies, restarts); and **Fae-specific vocab** — the owner's name, "Fae", tech/command terms,
    contact/calendar entities — exactly the words that must not garble.
  - Reuse any existing corpus (e.g. the Swift `CorpusEval` set) + add cases; keep the WAVs in-repo or a
    documented path so the measurement is reproducible.
- Replay each through the Gemma mmproj path (via `asr_replay.rs` and/or the app audio-inject) and compute
  **WER / exact-match on the FINAL `[heard]`** (post vocab-correction). Produce a table: clip → expected
  → `[heard]` → WER, with clean/noisy/vocab subtotals.

### 2. Decide the STT path — with the data
- Set an explicit **reliability bar** (e.g. clean ≤ X% WER, Fae-vocab exact-match ≥ Y%, no catastrophic
  garbles). State the numbers you chose and why.
- If the Gemma mmproj path clears the bar → **keep it** (simplest, unified, already wired) and say so
  with the table.
- If it doesn't → wire a fallback and re-measure it on the same corpus:
  - **Qwen3-ASR** or **whisper.cpp** (both merged in llama.cpp, cross-platform). Decide the integration:
    **(a)** replace pass-1 transcription wholesale, or **(b)** keep Gemma but fall back to the dedicated
    ASR when Gemma's transcript is low-confidence/empty/garbled. Pin + integrity-gate any new model
    (SHA, fail-closed, FAE_DEV escape) exactly like the B1 GGUF/mmproj.
- Whatever you choose, it must be **cross-platform** (no Apple-only STT) — this feeds P5 (portable voice).

### 3. Harden the degraded path (correctness-first — the most important behaviour)
- Define + implement what happens on a **bad/empty/low-confidence `[heard]`**: Fae must NOT fabricate an
  answer to a wrong transcript. Acceptable: ask the user to repeat, or surface "I didn't catch that"
  — never a confident answer to a mis-heard request. Fail loud, not silent.
- Verify the **context budget** doesn't truncate audio (historical mistral.rs-era bug: audio tokens
  landed past the window after a large system prompt → model "heard nothing"). Confirm on llama.cpp that
  the audio + ~3k-token system prompt fit `FAE_LLAMA_CTX`; if not, address it.

### 4. Prove through the APP + sweep the B1.5 audio follow-ups
- Drive real audio turns through the bundled app (B1.5 path: app→daemon llama.cpp) for a few corpus
  clips: correct `[heard]` → sensible answer → TTS + `ORB_MODE`→Speaking. Capture the daemon-log
  attribution (`process_mtmd`, the `[heard]` line).
- While here, address the B1.5-flagged audio-adjacent issues if they appear on audio turns:
  **thinking-enabled turns needing a retry-with-thinking-disabled** (adds latency — decide if audio
  turns should default thinking off), and the benign noisy MTP-draft warning
  (`Gemma4Assistant requires ctx_other … normal during memory fitting`) — quiet it if cheap.

---

## Gotchas
- **Two-pass is deliberate** — do not collapse to single-pass.
- **Measure the post-correction `[heard]`**, not the raw model output.
- **No live mic needed for measurement** — use `asr_replay.rs` + WAV corpus; reserve the app audio-inject
  for the end-to-end proof.
- **Integrity-gate** any new STT model (SHA-pinned, fail-closed) like B1.
- **ADR-010**: keep the llama.cpp sidecar; Qwen3-ASR/whisper also run under llama-server, not in-process.
- **Cross-platform**: no Apple-only STT (that's the point — feeds P5).
- `env -u RUSTFLAGS` for crate builds; **quit the dev app before any local `swift test`**; bundling trap.
- **autoresearch.jsonl** is unrelated churn — keep it out of your diff.

## Done criteria
1. A **measured WER/accuracy table** for the Gemma mmproj `[heard]` path over a representative corpus
   (clean + noisy + accented + spontaneous + Fae-vocab), reproducible via the harness.
2. An explicit **reliability bar** + a **documented decision** (keep Gemma, or fall back to
   Qwen3-ASR/whisper) justified by the table; if a fallback was wired, its measured numbers too, and its
   model integrity-gated.
3. **Degraded path** implemented + proven: a garbled/empty clip yields a safe "didn't catch that"/repeat,
   NOT a confident wrong answer.
4. **Context budget** confirmed: audio + system prompt fit the ctx window (no truncation).
5. **Live app proof**: real audio turns through the app on the llama.cpp daemon — correct `[heard]`,
   answer, TTS, `ORB_MODE`→Speaking — daemon-log-attributed.
6. Green: `swift build`; touched crates clippy `-D warnings` + nextest.
7. **Hand back** the report (do NOT commit/push). Reviewer validates, commits, updates open-gaps (B5) +
   memory + Obsidian.

## Suggested order
1. Corpus + harness measurement of the Gemma path (the data). 2. Bar + decision (+ fallback measure if
   needed). 3. Degraded-path hardening + context-budget check. 4. Live app proof + B1.5 audio sweep.
   5. Hand back.

> Scope: P2/B5 only — audio-in reliability + STT decision. Next: P3 (training→llama.cpp consumption),
> P4 (packaging/CI), then the portability phases. Full plan:
> `docs/plans/cross-platform-completion-roadmap-2026-06-18.md`.
