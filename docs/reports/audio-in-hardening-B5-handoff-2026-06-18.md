# Audio-In Hardening B5 Partial Handback — 2026-06-18

## Scope

P2 / B5 measurement-and-decision work for Fae push-to-talk audio-in. This is **not B5 complete**: it measures the existing llama.cpp Gemma-4 E4B + BF16 mmproj pass-1 ASR path, adds a reproducible evaluator/corpus extension, and hardens the degraded path so bad pass-1 transcripts are stopped before pass-2 reasoning. Remaining required work is an integrity-gated Qwen3-ASR/whisper fallback and full bundled-app proof.

## Reliability bar

Chosen before interpreting the run:

- Overall WER ≤ 20%.
- Clean WER ≤ 10%.
- Fae-vocab/entity exact-match ≥ 90%.
- Catastrophic / quality-gate garbles = 0.

Rationale: audio-in is correctness-critical. The assistant should ask again rather than answer confidently from a misheard command/name.

## Measurement command

Daemon was launched directly from the repo-built `fae-daemon` with the bundled llama.cpp runtime and the pinned local Gemma artifacts already installed:

```bash
cd crates
env -u RUSTFLAGS FAE_DEV=1 FAE_MODELS_LOCK=off \
  FAE_LLAMACPP_RUNTIME_DIR="$PWD/../native/macos/Fae/Resources/LlamaCpp" \
  cargo run -p fae-daemon > /tmp/fae-b5-daemon.log 2>&1

cd native/macos/Fae
uv run autoresearch/asr_b5_eval.py --corpus autoresearch/asr_corpus
```

Evaluator: `native/macos/Fae/autoresearch/asr_b5_eval.py`.
Corpus: `native/macos/Fae/autoresearch/asr_corpus` (28 WAV/TXT pairs after adding noisy + accented clips; manifest at `manifest.json`).
Latest raw output: `native/macos/Fae/autoresearch/results/b5_asr_gemma_20260618_181214.{json,md}`.

The evaluator sends each WAV to the daemon `conversation.inject_text` ASR-only pass, flattens the returned transcript, applies the static post-correction layer used by `TextProcessing.correctNameRecognition` (`Fae`/command fixes), computes WER/exact-match, and runs the new degraded-path quality gate.

Important limitation: this is **not** the full app's final post-correction `[heard]` because it does not instantiate `DynamicVocabularyCorrector` with owner/entity/speaker vocabulary. It is sufficient to show Gemma/mmproj fails the bar, but the reviewer/follow-up should use the app/TestServer audio path for the final B5 acceptance table.

## Result summary

- Overall WER: **17.0%** (passes overall bar)
- Exact-match: **75.0%**
- Clean WER: **20.8%** (fails clean bar)
- Fae-vocab exact-match: **57.1%** (fails vocab bar)
- Catastrophic/quality-gate garbles: **1** (fails degraded bar)
- Decision against bar: **FAIL**

## Per-clip table

| Clip | Category | Expected | Daemon ASR + static-corrected `[heard]` | WER | Exact | Quality |
|------|----------|----------|----------------------------------|-----|-------|---------|
| accented_01.wav | accented | Hello Fae | Hello | 50.0% | no | ok |
| accented_02.wav | accented | Open the terminal and run git status | Open the terminal and run git status | 0.0% | yes | ok |
| casual_01.wav | spontaneous | So yeah I was wondering if you could help me with something | So yeah I was wondering if you could help me with something | 0.0% | yes | ok |
| casual_02.wav | spontaneous | Okay so basically what happened was | Okay, so basically what happened was | 0.0% | yes | ok |
| command_01.wav | clean | What time is it | What time is it? | 0.0% | yes | ok |
| command_02.wav | clean | Set a timer for five minutes | Set a timer for five minutes | 0.0% | yes | ok |
| command_03.wav | clean | Search the web for weather forecast | search the web for weather forecast | 0.0% | yes | ok |
| conv_01.wav | spontaneous | I was thinking about going to the store later | I was thinking about going to the store later. | 0.0% | yes | ok |
| conv_02.wav | spontaneous | Can you remind me to call the dentist tomorrow | Can you remind me to call the dentist tomorrow? | 0.0% | yes | ok |
| conv_03.wav | spontaneous | What did we talk about yesterday | What did we talk about yesterday? | 0.0% | yes | ok |
| greeting_01.wav | clean | Hello Fae | Hello | 50.0% | no | ok |
| greeting_02.wav | clean | Good morning | good morning | 0.0% | yes | ok |
| greeting_03.wav | clean | Hey there how are you | Hey there, how are you? | 0.0% | yes | ok |
| name_01.wav | vocab | My name is David | My name is David. | 0.0% | yes | ok |
| name_02.wav | vocab | Call Sarah | call sar | 50.0% | no | ok |
| name_03.wav | vocab | Send a message to James | Send a message to James | 0.0% | yes | ok |
| noisy_01.wav | noisy | Hello Fae check my calendar | Hello, Fae check my calendar. | 0.0% | yes | ok |
| noisy_02.wav | noisy | Set a reminder to call David tomorrow | Set a reminder to call David tomorrow. | 0.0% | yes | ok |
| number_01.wav | vocab | The number is four one five two three six | The number is 415-236 | 66.7% | no | ok |
| question_01.wav | clean | What is the capital of France | Paris | 100.0% | no | ok |
| question_02.wav | clean | Tell me about quantum computing | Tell me about quantum computing | 0.0% | yes | ok |
| question_03.wav | clean | How do I make pasta carbonara | How do I make pasta carbonara? | 0.0% | yes | ok |
| short_01.wav | clean | Yes | Yes | 0.0% | yes | ok |
| short_02.wav | clean | No thanks | No thanks | 0.0% | yes | ok |
| short_03.wav | clean | Stop | sta | 100.0% | no | reject:short_fragment |
| spell_01.wav | vocab | Spell it F A E | Stella F A A | 60.0% | no | ok |
| tech_01.wav | vocab | Open the terminal and run git status | Open the terminal and run git status. | 0.0% | yes | ok |
| tech_02.wav | vocab | Check the pull request on GitHub | check the pull request on github | 0.0% | yes | ok |

## Decision

Do **not** keep Gemma/mmproj as the sole STT path. It fails the clean and Fae-vocab bars, and it produces correctness-critical substitutions such as:

- `Hello Fae` → `Hello` (wake/name omission)
- `Call Sarah` → `call sar` (entity corruption)
- `What is the capital of France` → `Paris` (answers instead of transcribing)
- `Spell it F A E` → `Stella F A A` (Fae-specific spelling failure)
- `Stop` → `sta` (caught by the new quality gate, but still a pass-1 failure)

The data points to a dedicated ASR fallback/primary path. Existing historical MLX-side Qwen3-ASR results on the older 24-clip corpus were much stronger (`asr_comparison_20260321_112131.md`: Qwen WER 1.6%, Parakeet 7.9%), but that is **not** an acceptable production fallback for B5 because B5 requires cross-platform llama.cpp-sidecar STT with integrity-gated model artifacts. The next implementation step should wire Qwen3-ASR or whisper.cpp under the ADR-010 sidecar boundary, pin hashes in the model lock, then re-run this same 28-clip corpus.

The new quality gate is a safety net, not an ASR substitute: it catches empty/markup/repetition/non-Latin/short-fragment outputs, but it cannot detect semantic failures like `What is the capital of France` → `Paris` or entity corruption like `Call Sarah` → `call sar` without a better ASR path.

## Degraded-path hardening implemented

Changed `native/macos/Fae/Sources/Fae/ML/DaemonLLMEngine.swift`:

- Adds `assessAudioTranscript(_:)` after pass-1 `flattenTranscript` and before pass-2 reasoning.
- Rejects empty transcripts, no-speech markers, model apologies, tool/thinking markup, low-alphanumeric garbage, high non-Latin transcripts, repeated-token loops, and suspicious short fragments.
- On reject, does **not** call pass 2. It returns:

```text
[heard]: (unclear audio)
I didn't catch that — please say it again.
```

This is the correctness-critical change: a bad/empty transcript now produces a safe re-ask rather than a confident answer to a misheard request.

Added tests in `native/macos/Fae/Tests/IntegrationTests/DaemonLLMEngineTests.swift` covering accepted short commands, rejected empty/no-speech/markup/repeated/non-Latin/fragment transcripts, and the exact safe re-ask response.

## Context-budget check

The current two-pass design avoids the historical truncation failure mode:

- Pass 1 sends the WAV with a tiny ASR-only system prompt and `maxTokens <= 256`; it does **not** send the full Fae system prompt/tool list.
- Pass 2 sends only text (`audioWAVBase64 = nil`) with the normal system/tool context.

The daemon logs prompt-budget metrics for each `conversation.inject_text`; audio is no longer placed behind a large prompt in a single multimodal context.

## Validation run

Passed:

```bash
cd native/macos/Fae
swift test --filter DaemonAudioTwoPassTests
swift build
```

Full `swift test` was attempted but is not green in this checkout due apparently unrelated existing failures:

- `IntegrationTests.ToolAnalyticsAndMCPStaticTests.testRecordAndTotalRecords`: expected 3 records, got 0.
- Later MLX default metallib load error during `ToolProgramPromptTests`.

Rust crates were not modified. I did launch the daemon with `env -u RUSTFLAGS` for measurement. No Rust code changes were made.

Measurement caveat: the daemon was launched with `FAE_DEV=1 FAE_MODELS_LOCK=off` because this was a local dev measurement against already-installed artifacts. Production acceptance should re-run with normal integrity gates enabled.

## Continuation check: stricter pass-1 prompt

Reviewer requested trying a cheaper prompt fix before wiring a second STT engine. I strengthened the ASR-only prompt to explicitly forbid answering questions:

```text
Transcribe the user's audio verbatim. Output only the exact words spoken — no labels, quotation marks, preamble, commentary, summaries, or answers. If the user asks a question, transcribe the question words; never answer it. If nothing is said, output nothing.
```

Rerun:

```bash
cd native/macos/Fae
uv run autoresearch/asr_b5_eval.py --corpus autoresearch/asr_corpus
```

Latest output: `native/macos/Fae/autoresearch/results/b5_asr_gemma_20260618_190859.{json,md}`.

Summary after stricter prompt:

- Overall WER: **15.1%** (improved from 17.0%)
- Clean WER: **12.5%** (improved from 20.8%, still fails ≤10%)
- Vocab exact-match: **42.9%** (worse than 57.1%, still fails ≥90%)
- Catastrophic/quality-gate garbles: **0** (improved from 1)
- Decision against bar: **FAIL**

The prompt fix corrected the `What is the capital of France` → `Paris` failure, but Gemma/mmproj still corrupts Fae/name/vocab clips (`Hello Fae`→`hello`, `My name is David`→`My name is Dayed`, `Call Sarah`→`call sa`, `Spell it F A E`→`Stella F F A`, `Stop`→`start`). The fallback decision still holds.

## Full app dynamic-vocabulary measurement (orb-shell TestServer)

Reviewer correctly flagged that the first app-path run was launched through the old `test-serve` recipe, which did **not** embed/start the Rust orb UI shell. I fixed `just test-serve` so it now matches the orb-first dev bundle shape:

- builds `fae-ui-shell`
- builds `fae-daemon` with `env -u RUSTFLAGS`
- embeds `Contents/MacOS/fae-ui-shell`
- embeds `Contents/MacOS/fae-daemon`
- launches with `FAE_DEV=1`, `FAE_TEST_SERVER=1`, and `FAE_UI_SHELL_BIN=<bundle>/Contents/MacOS/fae-ui-shell`

Verification for the accepted run:

```text
Fae.app/Contents/MacOS/Fae --test-server
Fae.app/Contents/MacOS/fae-ui-shell
Fae.app/Contents/MacOS/fae-daemon
```

and app log showed:

```text
FaeAppDelegate: orb host active — main window stays hidden
TestServer: listening on 127.0.0.1:7433
```

I then re-ran the full app evaluator:

```bash
cd native/macos/Fae
uv run autoresearch/asr_b5_app_eval.py --corpus autoresearch/asr_corpus --timeout-s 300
```

Latest accepted output: `native/macos/Fae/autoresearch/results/b5_asr_app_20260618_200143.{json,md}`.

This run used a controlled `fae-dev/personal_lexicon.json` containing only the B5 seed entries (`David`, `Sarah`, `James`, `GitHub`, `Fae`) and `config.toml` userName `David`. The previous harvested-contact lexicon caused false dynamic corrections such as `run`→`Rune Bondal` and `set`→`Sat Panesar`, so it is useful as a separate DVC false-positive finding, but not the controlled acceptance table. Backups were written under `~/Library/Application Support/fae-dev/*.b5-backup-20260618195803` before the controlled seed was installed.

Summary of controlled full-app final `[heard]` table:

- Overall WER: **20.2%**
- Exact-match: **78.6%**
- Clean WER: **25.0%**
- Vocab exact-match: **57.1%**
- Safe re-ask / quality-gate transcripts: **1**
- Decision against bar: **FAIL**

Key full-app observations:

- Dynamic correction fixed/kept several important cases: `Hello Fae`, `My name is David`, `Send a message to James`, `GitHub`, noisy `Hello Fae check my calendar`.
- Residual correction-proof failures remain:
  - `Call Sarah` → `call ser`
  - `The number is four one five two three six` → `The number is 415236`
  - `Yes` → `(unclear audio)`
  - `Stop` → `Stap`
  - `Spell it F A E` → `Stellar FA`
- Full app dynamic-vocab measurement therefore still fails the bar. The fallback decision remains justified.

Degraded-path live proof through the same orb-shell TestServer path:

```text
HEARD PTT [heard]: (unclear audio)
REASK True
conversation user: (unclear audio)
conversation assistant: I didn't catch that, please say it again.
```

## Not completed / reviewer follow-up

- I did **not** wire the Qwen3-ASR/whisper.cpp fallback yet; the full-app measurement says it is required.
- I did **not** complete a bundled app/test-server live audio turn with TTS + `ORB_MODE`→Speaking in this pass. The measured path is daemon live ASR over the same control-plane command the Swift app uses underneath, but the full app proof remains for reviewer/follow-up.
- The B1.5 thinking/MTP warning sweep was not changed; audio pass 1 already suppresses thinking, and no cheap MTP warning-only patch was identified during this pass.
