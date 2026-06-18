# Audio-In Hardening B5 Handback — 2026-06-18

## Scope

P2 / B5 measurement-and-decision work for Fae push-to-talk audio-in. This report preserves the initial Gemma/mmproj failure evidence, then documents the completed daemon-side Qwen3-ASR fallback, DVC false-positive hardening, and final orb-shell TestServer app-path acceptance run.

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

## Follow-up implementation: fallback scaffold, DVC guard, expanded corpus

Implemented next B5 step after the full-app FAIL:

### Integrity-gated fallback wiring

Added `native/macos/Fae/Sources/Fae/ML/AudioFallbackTranscriber.swift` and wired it into `DaemonLLMEngine.runAudioTurn`.

Contract:

- this is **interface/scaffold only** until an approved ASR binary/model is added to `models.lock`
- runtime env may select `FAE_AUDIO_FALLBACK_BIN` and `FAE_AUDIO_FALLBACK_MODEL`, but expected SHA-256 values come from a trusted lock entry, not from env
- `FAE_AUDIO_FALLBACK_BIN_ARTIFACT_ID` must resolve in `models.lock`
- if a model path is configured via `FAE_AUDIO_FALLBACK_MODEL`, `FAE_AUDIO_FALLBACK_MODEL_ARTIFACT_ID` must also resolve in `models.lock`
- default args support `whisper.cpp`-style CLIs: `-m {model} -f {wav} -nt -np`
- wrapper/Qwen3-ASR CLIs can provide `FAE_AUDIO_FALLBACK_ARGS` with `{wav}` and `{model}` placeholders
- mode is `FAE_AUDIO_FALLBACK_MODE=quality_fail|fragile|always`, default `fragile`
- fail-closed behavior: missing lock entry / hash mismatch / timeout / bad fallback transcript keeps the primary path and, if primary is still unusable, returns the safe re-ask

`fragile` mode attempts fallback for:

- quality-gate failures
- short/ambiguous turns such as `Stap`
- numeric dictation collapsed to digits
- spelling-like failures (`Stellar FA` etc.)
- short `call <name>` turns such as `call ser`

This deliberately addresses the real app-path failures that passed the coarse quality gate but were too fragile to trust.

Important: no arbitrary Qwen3-ASR/whisper asset was downloaded or trusted. A real post-fallback corpus run still needs an approved binary/model pair added to `models.lock`.

### DVC false-positive fix

Changed `DynamicVocabularyCorrector` to protect ordinary command/control words from broad phonetic corrections. This prevents harvested multi-token contact names from rewriting command verbs, e.g.:

- `run` → `Rune Bondal` no longer happens
- `set` → `Sat Panesar` no longer happens

The guard still allows explicit vocabulary variants such as `ser` → `Sarah`.

Live orb-shell TestServer proof after the fix:

```text
HEARD PTT [heard]: Set a timer for five minutes.
ASSISTANT_LAST Let me check that for you. What should I label the five-minute timer?
```

No `Sat Panesar` false correction occurred.

### Corpus expansion

Expanded `native/macos/Fae/autoresearch/asr_corpus` with eight additional clips:

- `short_04`: `Start`
- `short_05`: `Run`
- `dvc_01`: `Set a timer for five minutes`
- `dvc_02`: `Open the terminal and run git status`
- `dvc_03`: `Run git status`
- `name_04`: `Call Sarah now`
- `spell_02`: `Spell F A E slowly`
- `number_02`: `Four one five two three six`

`manifest.json` now marks `dvc_*.wav` as `dvc_guard` clips.

### Validation

Targeted tests passed:

```bash
cd native/macos/Fae
swift test --filter 'DynamicVocabularyCorrectorTests|DaemonAudioTwoPassTests'
# 38 tests, 0 failures
swift build
# passed
```

Full `swift test` is still not green in this checkout due unrelated pre-existing failures (examples from `/tmp/fae-swift-test-b5.log`: `AgentAndMetaOptStaticTests.testEncodeScoresAllNilStillValid`, `AudioAndBackupStaticTests` SQLite backup cases, `BuiltinToolsStaticTests.testParseFormValuesNilWhenAllEmpty`, plus Contacts/CoreData XPC errors). The B5-targeted tests pass.

`just test-serve` also rebuilt and launched the orb-first bundle with the embedded daemon forced via `FAE_DAEMON_BIN`:

```text
Fae.app/Contents/MacOS/Fae --test-server
Fae.app/Contents/MacOS/fae-ui-shell
Fae.app/Contents/MacOS/fae-daemon
health {'pipeline': 'running', 'status': 'ok'}
```

## Qwen3-ASR asset selection progress

Owner selected Qwen3-ASR as the fallback direction. I searched existing local assets/locks first; no Qwen3-ASR GGUF is currently installed under `~/Library/Application Support/fae*/models`, and no Qwen3-ASR entries existed in `models.lock`.

Selected exact upstream candidate for the next locked run:

- repo: `ggml-org/Qwen3-ASR-1.7B-GGUF`
- revision: `36a678687ba7d07a74ca70ccb0e36902e005fb80`
- model: `Qwen3-ASR-1.7B-Q8_0.gguf`
  - size: `2165034944`
  - sha256: `58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57`
- audio projector: `mmproj-Qwen3-ASR-1.7B-Q8_0.gguf`
  - size: `355709344`
  - sha256: `46c1d533af3f354ceb37ce855dbceff7da7fa7cf1e6a523df3b13440bd164c0d`
- license: Apache-2.0 inherited from base model `Qwen/Qwen3-ASR-1.7B`

I appended lock entries for those two ASR artifacts to `native/macos/Fae/Sources/Fae/Resources/Models/models.lock`, plus an `asr_binary` entry for the already-pinned macOS-arm64 `llama-server` binary from `scripts/llamacpp-runtime.lock.json`:

- `llamacpp-b9692-llama-server-macos-arm64`
- `ggml-org-qwen3-asr-1-7b-q8-0-gguf`
- `ggml-org-qwen3-asr-1-7b-mmproj-q8-0-gguf`

No Qwen3-ASR artifact was downloaded yet, and no fallback corpus run was attempted yet. The next safe step is adding a daemon-side resolver/downloader for these locked ASR artifact ids and a daemon-side `audio.transcribe_fallback` command (or equivalent) that supervises the Qwen3-ASR llama.cpp sidecar under ADR-010.

## Final implementation: daemon-side Qwen3-ASR fallback

The production fallback is now daemon-side, not Swift app-side process spawning.

Implemented:

- `audio.transcribe_fallback` control-plane command, requiring `ConversationWrite`.
- Daemon `SessionBackends.asr_fallback` with fail-closed handling:
  - missing fallback provider: `fallback_unavailable`
  - bad payload: `bad_request`
  - provider error: `fallback_failed`
  - empty normalized transcript: `empty_transcript`
- Daemon-owned lazy Qwen3-ASR `llama-server` sidecar using the ADR-010 sidecar boundary:
  - model: `Qwen3-ASR-1.7B-Q8_0.gguf`
  - mmproj: `mmproj-Qwen3-ASR-1.7B-Q8_0.gguf`
  - no MTP/drafter for the ASR sidecar
  - default port `18081`, cache under the llama cache `asr/`
  - disabled only with `FAE_AUDIO_FALLBACK=0|false`
- Pinned artifact download/verification reuses the existing `RemoteModelArtifact` path. Expected size/SHA for Qwen3-ASR model, mmproj, and the ASR `llama-server` binary is resolved from the installed `models.lock`, not env-provided hashes or duplicated code constants.
- Swift `DaemonLLMEngine` now defaults to no app-side `AudioFallbackTranscriber`; production fallback calls daemon command `audio.transcribe_fallback` and unwraps `result.transcript`.
- Qwen3-ASR output normalization strips the model's `language English<asr_text>` prefix before transcript quality checks.

Live sidecar proof through the canonical orb-shell TestServer path:

```text
Fae.app/Contents/MacOS/Fae --test-server
Fae.app/Contents/MacOS/fae-ui-shell
Fae.app/Contents/MacOS/fae-daemon
llama-server ... --alias qwen3-asr --port 18081 --reasoning off --reasoning-format none
```

Injected `short_03.wav` (`Stop`) produced:

```text
HEARD_EVENT PTT [heard]: Stop.
conversation user: Stop.
conversation assistant: Stopping the current session.
```

Lock-on smoke was also run outside `FAE_DEV`/`FAE_MODELS_LOCK=off`:

```bash
env -u FAE_DEV -u FAE_MODELS_LOCK \
  FAE_TEST_SERVER=1 \
  FAE_UI_SHELL_BIN=<bundle>/Contents/MacOS/fae-ui-shell \
  FAE_DAEMON_BIN=<bundle>/Contents/MacOS/fae-daemon \
  <bundle>/Contents/MacOS/Fae --test-server
```

Result:

```text
HEARD_EVENT PTT [heard]: Stop.
LOCK_ON_NO_SKIP_WARNINGS
```

No `skipping artifact digest verification` warning was present in the lock-on smoke log.

## Final B5 acceptance measurement

Final full-app run, through `just test-serve` orb-shell bundle and `TestServer test.inject_audio`:

```bash
cd native/macos/Fae
uv run autoresearch/asr_b5_app_eval.py --seed-dev-vocab --seed-only
# from repo root: just test-serve
uv run autoresearch/asr_b5_app_eval.py --base-url http://127.0.0.1:7433 --timeout-s 180
```

Output:

- `native/macos/Fae/autoresearch/results/b5_asr_app_20260618_235312.json`
- `native/macos/Fae/autoresearch/results/b5_asr_app_20260618_235312.md`

Summary:

- Overall WER: **2.5%** ✅ (bar ≤ 20%)
- Exact-match: **94.4%**
- Clean WER: **0.0%** ✅ (bar ≤ 10%)
- Vocab exact-match: **90.0%** ✅ (bar ≥ 90%)
- Safe re-ask / quality-gate transcripts: **0** ✅
- Decision against bar: **PASS**

Notable residual miss: `spell_02.wav` (`Spell F A E slowly`) heard as `Star fade slowly`, but the aggregate vocab exact bar still passes at 90.0%. This should stay on the watchlist for future ASR corpus expansion.

## Final DVC hardening

Additional false-positive fixes after the Qwen3-ASR run:

- Protected conjunction/filler words (`and`, `or`, articles/prepositions) and number words (`zero`…`nine`) from generated contact-name corrections.
- Stopped generating phonetic variants for broad harvested `contact` lexicon entries. Explicit variants still apply, but contacts no longer rewrite preferred seeded spellings; this prevents `Sarah` from being rewritten to harvested contact `Sara`.
- Added tests for `and`→`Andy Lim`, `three`→`Wellness Tree`, and contact `Sara` not overriding seeded `Sarah`.

## Final validation

Passed:

```bash
cd crates
cargo fmt --all
cargo test -p fae-control-plane -p fae-daemon
# fae-control-plane: 23 passed; fae-daemon: 44 passed
cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo check --workspace --all-targets

cd native/macos/Fae
swift test --filter 'DynamicVocabularyCorrectorTests|DaemonAudioTwoPassTests'
swift build
python3 -m py_compile autoresearch/asr_b5_app_eval.py
uv run autoresearch/asr_b5_app_eval.py --base-url http://127.0.0.1:7433 --timeout-s 180
```

`swift test` full-suite was attempted again but timed out after 1200s in this checkout; earlier full-suite attempts also had unrelated pre-existing static/SQLite/CoreData failures. The B5-targeted tests and final app-path corpus acceptance run pass.

## Remaining reviewer/release follow-up

- Full release-style real-mic/TTS validation remains pending; this handback proves TestServer-injected audio through the canonical orb-shell app path.
- Keep `spell_02` on the watchlist despite aggregate PASS.
- Full corpus reliability PASS was measured with `just test-serve` (`FAE_DEV=1`); a separate lock-on smoke verified the Qwen3-ASR fallback path without `FAE_MODELS_LOCK=off` and with no digest-skip warnings.
