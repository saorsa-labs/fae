# Post-Training Strategy And Evaluation

> Canonical guide for Fae post-training methods, experiment gates, and planned `mlx-tune` adoption.
>
> Last updated: March 13, 2026.

---

## Why this document exists

Fae already has a strong local runtime, a benchmark harness, and a clear separation between weights, `SOUL.md`, and the system prompt.

What failed in practice was simpler: some earlier fine-tuned models improved style, but regressed badly on tool calling.

That means post-training for Fae cannot be treated as "train first, benchmark later." It has to be:

1. freeze a baseline
2. train against a specific hypothesis
3. re-run the same evaluations
4. compare base vs candidate
5. only promote a model if it clears the gates

This document is the current source of truth for that loop.

---

## Current product reality

Fae's current recommended local path is still the base Qwen3.5 family:

- `Qwen3.5 4B` on `16–31 GB` systems
- `Qwen3.5 9B` on `32+ GB` systems
- `Qwen3.5 27B` as the current highest loadable manual quality tier

Current runtime note:

- External PARO baselines are promising at `9B` and `27B`, but Fae's Swift-native runtime cannot load PARO checkpoints yet, so they are benchmark-only for now.
- For fresh cloud-scale `9B` / `27B` post-training, see [HF Jobs Training](hf-jobs-training.md).

That product direction is reflected in:

- [README.md](../../README.md)
- [Local model strategy](local-model-strategy.md)
- [Local model switching](model-switching.md)

Fine-tuned `saorsa1-*` models are currently experimental, not the default runtime path.

### Why we are tightening the evaluation loop

Historical benchmark evidence already shows why:

- On March 12, 2026, base `Qwen3.5 4B` scored `10/10` on the tool diagnostic benchmark.
- On March 12, 2026, base `Qwen3.5 9B` scored `9/10` on the same tool diagnostic benchmark.
- On March 12, 2026, the earlier `saorsa1` runs scored materially worse on tool calling:
  - `saorsa1-tiny`: `2/10`
  - `saorsa1-worker`: `3/10`
  - `saorsa1-concierge`: `7/10`

The lesson is straightforward: improved tone is not enough. If tool behavior regresses, the candidate does not ship.

---

## The three layers

Fae still uses the same three-layer model:

- **Weights**: stable response habits that should survive prompt drift
- **`SOUL.md`**: character contract and relationship stance
- **System prompt**: runtime context, tool policy, memory, time, speaker, capabilities

Post-training should only move behavior into weights when:

- it is stable across users
- it is stable across releases
- it shows up in many turns
- prompting alone keeps fighting the base model

Do not use post-training for:

- app mechanics that change frequently
- exact tool schema wording
- runtime approval policy
- memory storage semantics
- user-specific facts

---

## Post-training methods Fae can use

This section is about methods, not libraries.

### Prompting, `SOUL.md`, and memory are not post-training

These are still the first tools to reach for when the change is:

- fast-moving
- user-specific
- operational
- easy to A/B test

Examples:

- changing how much warmth Fae shows with one user
- changing approval wording
- changing scheduler semantics
- changing the exact tool-use policy

If a behavior belongs here, do not train it into weights.

### SFT

**Supervised fine-tuning** teaches the target output distribution directly from demonstrations.

Good for Fae:

- answer shape
- brevity
- anti-sycophancy tone
- calm uncertainty
- TTS-safe prose habits
- natural memory tone

Strengths:

- easiest to reason about
- easiest to debug
- best first post-training step

Weaknesses:

- can blur tool behavior if the data over-indexes on plain text turns
- does not directly teach "prefer this over that" the way preference methods do

Fae stance:

- **Yes**
- usually the first pass
- preferably done as adapter training, not full fine-tuning

### Response-only SFT

This is still SFT, but the trainer masks prompt tokens and optimizes only the assistant response.

Why it matters for Fae:

- it usually preserves the user prompt and system/tool scaffolding better
- it can reduce accidental overfitting to prompt text
- it is a strong fit for style and answer-shape work

Fae stance:

- **Yes**
- preferred over naive full-sequence SFT when the training stack supports it

### DPO

**Direct Preference Optimization** trains on `chosen` vs `rejected` responses for the same prompt.

Good for Fae:

- suppressing hollow affirmations
- preferring concise over padded answers
- preferring one clear pushback over repeated nagging
- preferring grounded tool replies over made-up results

Strengths:

- directly attacks unwanted behaviors
- sharper than SFT for preference-level style correction

Weaknesses:

- dataset quality matters a lot
- formatting mismatches can make the training signal noisy
- can still damage tool behavior if preference pairs ignore native tool formats

Fae stance:

- **Yes**
- best used after or alongside a carefully scoped SFT pass

### ORPO

**Odds Ratio Preference Optimization** combines supervised and preference pressure in one step.

Why it is interesting:

- simpler pipeline than SFT then DPO
- potentially cheaper to run and iterate

Risk for Fae:

- harder to isolate whether a change came from supervised behavior shaping or preference shaping
- less clear debugging story when tool calling regresses

Fae stance:

- **Maybe**
- worth experimenting with after the harness is tighter
- not the first default path

### SimPO and KTO

These are alternative preference-learning methods.

Why they exist:

- different tradeoffs around reference-model pressure and preference shaping

Why they are not the current default:

- Fae's immediate problem is not a lack of preference method options
- the bottleneck is evaluation discipline and tool-preserving data design

Fae stance:

- **Low priority**
- useful later if DPO or ORPO prove unstable or insufficient

### GRPO

**Group Relative Policy Optimization** is aimed at reward-driven reasoning behavior.

Good for:

- math
- code verification
- structured reward loops
- chain-heavy reasoning models

Why it is not the right current focus for Fae:

- Fae's immediate gap is not "more reasoning traces"
- the current regression is tool calling and operator reliability
- GRPO can easily optimize for the wrong surface if the reward function is weak

Fae stance:

- **Not now**
- maybe later for narrow reasoning experiments, not for the main operator path

### Full fine-tuning

Full-weight fine-tuning updates the whole model instead of just adapters.

Pros:

- maximum capacity
- no adapter merge step

Cons for Fae:

- slower
- heavier
- riskier
- much easier to create hard-to-explain regressions

Fae stance:

- **No for the current loop**
- adapters first

---

## Training forms and delivery forms

The training method and the artifact form are different decisions.

### Recommended training form

For Fae today:

- adapter training (`LoRA` / `QLoRA`-style)
- merged into standard MLX/Hugging Face weights for runtime use

Why:

- cheaper to iterate
- easier to compare runs
- easier to keep the runtime independent from the training stack

### Artifact forms

#### Adapter only

Good for:

- quick experiments
- resuming training

Not ideal for:

- production delivery to the app

#### Merged MLX / Hugging Face weights

Good for:

- actual Fae runtime loading
- benchmark parity with production
- shipping a candidate to testers

This is the preferred runtime artifact.

#### GGUF

Useful for:

- external tooling
- llama.cpp / Ollama / LM Studio ecosystems

Not required for:

- the current Fae runtime

Fae runtime does not need GGUF to evaluate or ship a local model.

---

## What the benchmark harness already gives us

`FaeBenchmark` already measures the right broad surfaces:

- throughput
- TTFT
- RAM
- `/no_think` compliance
- tool calling
- MMLU-style mini eval
- Fae-specific capability eval
- assistant-fit eval
- freeform eval
- structured serialization eval

Relevant files:

- [FaeBenchmark main](../../native/macos/Fae/Sources/FaeBenchmark/main.swift)
- [Shared local inference target](../../native/macos/Fae/Sources/FaeInference)
- [MCQ eval suites](../../native/macos/Fae/Sources/FaeBenchmark/EvalSuites.swift)
- [Freeform eval suites](../../native/macos/Fae/Sources/FaeBenchmark/FreeformEvalSuites.swift)
- [Native benchmark recipes](../../native/macos/Fae/justfile)

The current gap is orchestration, not existence:

- results are spread across timestamped files
- run profiles are not obvious unless you know which command produced them
- there is no single canonical pre-train vs post-train comparison artifact

### Benchmark runtime alignment

As of March 13, 2026, `FaeBenchmark` no longer carries its own local MLX loading/generation path.

Both the app and the benchmark now compile against the same shared SwiftPM target:

- `Sources/FaeInference/LLMShared.swift`
- `Sources/FaeInference/MLXLLMEngine.swift`

That is intentional. Qwen-family tool-call parsing, `enable_thinking` handling, warmup behavior, session reuse, and other MLX/Qwen fixes must land in one place and affect both production and evaluation immediately.

Operationally, that means:

- build and run the benchmark through the Xcode / `just` path, not `swift run FaeBenchmark`
- update `mlx-swift-lm` before serious base-vs-candidate runs when upstream MLX/Qwen support changes
- treat benchmark/runtime drift as a bug

The repository already tracks the official [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) package on `branch: "main"` in [`native/macos/Fae/Package.swift`](../../native/macos/Fae/Package.swift), but SwiftPM still resolves that to a pinned revision locally. So "keeping up to date" still requires a package update step before important experiments.

### Current command surface

From [`native/macos/Fae`](../../native/macos/Fae):

```bash
just build-benchmark
just benchmark qwen3.5-4b
just benchmark qwen3.5-9b
just benchmark-tools qwen3.5-4b
just benchmark-custom <hf-model-id> <short-name>
just benchmark-compare <base-short-name> <candidate-short-name>
```

Before any benchmark series meant to compare a fine-tuned candidate against a shipping baseline, refresh package resolution for `mlx-swift-lm`, then rebuild the benchmark via the commands above.

```bash
cd native/macos/Fae
swift package update
just build-benchmark
```

From the repository root, the current app-level validation entry points are:

```bash
just test-serve
bash scripts/test-comprehensive.sh
```

These commands exist today. What is still missing is the higher-level experiment wrapper around them.

---

## Current benchmark contract for post-training

### Models in scope

For the current loop, we should only target:

- `Qwen3.5 4B`
- `Qwen3.5 9B`

Why:

- these are the product-relevant operator tiers today
- they are the models worth spending training and validation time on
- they are the right place to test whether post-training can beat shipping baselines

### Required baseline run

Before training a candidate:

1. run the benchmark on the base model
2. save the exact output JSON
3. record the model ID, date, machine, prompt profile, and command used

The baseline must be captured before the candidate is evaluated. Do not compare a new candidate against an old, mismatched benchmark run and call it conclusive.

One operational detail also matters: `mlx_lm fuse` may fail late while trying to
fetch the source model card `README.md` from Hugging Face. That fetch is for
packaging metadata, not the fused weights themselves. For Fae experiments,
prefer fusing from a resolved local base-model snapshot so the benchmarked
candidate artifact is deterministic and does not depend on Hub model-card
availability.

### Required post-train run

After training:

1. run the same benchmark dimensions
2. on the same machine when possible
3. with the same benchmark profile
4. with the same model family and size
5. on a fused local candidate artifact, not only the raw adapter
6. on the selected checkpoint, not just the final training step

That means:

- `Qwen3.5 4B` vs fine-tuned `Qwen3.5 4B`
- `Qwen3.5 9B` vs fine-tuned `Qwen3.5 9B`

Not:

- `Qwen3.5 4B` vs a fine-tuned `2B`
- or `Qwen3.5 9B` vs a stylistically different 24B model

### Benchmark profiles

#### Fast gate

Run these first:

- tool calling
- assistant-fit
- freeform
- serialization

Why:

- these are the fastest high-signal checks for the failure mode we already saw

#### Full gate

Then run:

- throughput
- RAM
- `/no_think`
- intelligence
- Fae capabilities

Why:

- a candidate that preserves tools but becomes too slow, too memory-heavy, or too structurally unreliable is still not a clear win

### App-level validation

Model-only benchmarking is necessary, but not sufficient.

Every serious candidate also needs:

- the live test server path
- the comprehensive app-level test run
- at least some real app interaction for tool-heavy flows

Relevant files:

- [test-comprehensive.sh](../../scripts/test-comprehensive.sh)
- [App release validation checklist](../checklists/app-release-validation.md)
- [Main and Cowork live scenarios](../checklists/main-and-cowork-live-test-scenarios.md)

### Promotion gates

A fine-tuned model should stay experimental unless it clears all of the following:

- no tool-calling regression relative to the frozen baseline
- no regression in assistant-fit categories tied to tool judgment or tool-result handling
- no regression in serialization correctness
- acceptable latency and RAM tradeoff for its tier
- acceptable app-level behavior in the live path

If tool calling regresses, the model does not graduate to default use, even if the tone is better.

---

## How we should improve the harness

The current tool benchmark is useful, but too narrow. It mostly answers:

- did the model choose the right tool name

It should also score:

- correct abstention when no tool is needed
- correct argument structure for the tool
- staying in the model's native tool-call format
- correct user-facing reply after the tool result
- grounded behavior when a tool returns no result or permission is missing

The comparison workflow also needs a wrapper around the current benchmark binary:

- freeze baseline
- run candidate
- generate a single delta report
- record the experiment manifest

The manifest should include:

- date
- machine / RAM
- base model ID
- candidate model ID
- training data revision
- training script or trainer version
- hyperparameters
- benchmark command / profile
- output files

---

## `mlx-tune`: why we care

Relevant project:

- [`ARahim3/mlx-tune`](https://github.com/ARahim3/mlx-tune)

As of March 13, 2026, `mlx-tune` is interesting for Fae because it offers:

- Mac-native MLX training
- SFT
- DPO
- ORPO
- GRPO
- KTO
- SimPO
- response-only training helpers
- Qwen3.5 examples
- Hugging Face and GGUF export paths

That matters because Fae's current local training scripts were originally designed around:

- adapter SFT first
- preference optimization later
- merged MLX weights for runtime use

The main reason to evaluate `mlx-tune` is local preference optimization on Apple Silicon.

### Why `mlx-tune` is not a drop-in replacement today

There are still real caveats:

- it is a young project and moving quickly
- its DPO path currently prefers flat string `prompt` / `chosen` / `rejected` examples
- Fae's current DPO data preserves chat-message structure

So the likely integration path is:

- keep Fae's existing dataset preparation logic as the source of truth
- add export adapters for `mlx-tune`-friendly SFT and DPO formats
- use `mlx-tune` for experiments
- keep merged MLX/HF weights as the runtime artifact

Fae should not depend on `mlx-tune` at runtime. It is a training-time tool, not part of the shipping app path.

---

## Current plan for `mlx-tune`

### What we keep

- [prepare_training_data.py](../../scripts/prepare_training_data.py) remains the canonical data extraction step
- `FaeBenchmark` remains the canonical model benchmark surface
- app-level validation remains required
- merged model artifacts remain the runtime output

The current dataset split is now more explicit:

- `claude-post-train-data.md` provides the broad DPO preference corpus
- `codex-post-train-data.md` provides seed SFT examples
- `tool-post-train-data.md` provides tool-call, tool-result, approval, and permission examples aligned to the current macOS runtime

One detail matters here: the extractor now derives additional SFT examples from DPO `chosen` responses, but deliberately excludes tool-sensitive prompts from that conversion. That prevents the SFT set from relearning exactly the bad pattern seen in earlier runs, where the model would say things like "reminder set" or "checking your calendar now" without emitting a tool call.

### What we add

1. exporters that turn Fae's training data into `mlx-tune`-friendly SFT and DPO formats
2. a benchmark wrapper that captures pre-train and post-train runs as one experiment
3. a delta report that compares candidate vs baseline
4. stronger tool benchmarks

### First experiments

The first `mlx-tune` experiments should be:

1. response-only SFT on `Qwen3.5 4B`
2. response-only SFT on `Qwen3.5 9B`
3. DPO or ORPO follow-up only after the SFT candidates preserve tools

The first hypothesis should be narrow:

- improve style and answer shape
- preserve or improve tool calling
- preserve or improve assistant-fit

Not:

- teach the whole app contract in weights
- optimize for chain-heavy reasoning
- introduce new runtime assumptions

---

## Immediate next steps

1. Freeze canonical base-model benchmark runs for `Qwen3.5 4B` and `Qwen3.5 9B`.
2. Add a pre-train/post-train comparison workflow around `FaeBenchmark`.
3. Expand the tool benchmark beyond tool-name selection.
4. Keep tool-focused source data growing around current macOS capabilities, approval popups, and permission failures.
5. Add `mlx-tune` export adapters for the current Fae dataset.
6. Re-run training only after the benchmark contract is in place.

---

## Related documents

- [Companion model training strategy](companion-training-strategy.md)
- [Local model strategy](local-model-strategy.md)
- [LLM benchmark overview / scoreboard](../benchmarks/llm-benchmarks.md)
- [Local model benchmark report — 2026-03-07](../benchmarks/local-model-eval-2026-03-07.md)
- [Fae-priority local model evaluation — 2026-03-07](../benchmarks/fae-priority-eval-2026-03-07.md)
