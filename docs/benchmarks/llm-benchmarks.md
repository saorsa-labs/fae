# LLM Benchmarks — Local Inference on Apple Silicon

Benchmark results for Qwen3 models running locally via mistral.rs with Metal acceleration.
These numbers directly inform Fae's model selection, context budget, and dual-channel
pipeline architecture.

**Hardware:** Apple Silicon, 96 GB unified memory
**Quantization:** Q4_K_M (GGUF)
**Backend:** mistral.rs 0.7.1-alpha.1 (built from master) with Metal GPU offload
**Date:** 2026-02-23

---

## Update — MLX local model scoreboard (2026-03-07)

A newer benchmark pass was run with the native Swift MLX stack used by current Fae benchmarking. This section is the current model-selection view for Fae.

**Important caveat:** the sections below this update are older `mistral.rs` Qwen3 measurements on a different backend. They are still useful historical context, but the scoreboard below should drive current local-model decisions.

### Generic apples-to-apples scoreboard

| Model | RAM | TTFT | 500 T/s | Tools | MMLU | Fae | JSON | XML | YAML |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| qwen3.5-0.8b | 654 MB | 51 ms | 41.3 | 50% | 46% | 65% | 100% | 0% | 33% |
| qwen3.5-2b | 1264 MB | 85 ms | 41.6 | 100% | 52% | 40% | 100% | 33% | 100% |
| qwen3.5-4b | 2527 MB | 165 ms | 31.0 | 100% | 0% | 0% | 100% | 0% | 0% |
| qwen3.5-9b | 5084 MB | 249 ms | 31.6 | 90% | 0% | 0% | 0% | 0% | 0% |
| qwen3.5-27b | 14632 MB | 748 ms | 14.2 | 100% | 0% | 0% | 0% | 0% | 0% |
| qwen3.5-35b-a3b | 18819 MB | 219 ms | 15.9 | 100% | 0% | 0% | 0% | 0% | 0% |
| LFM2.5-1.2B-Instruct-MLX-4bit | 770 MB | 43 ms | 136.8 | 20% | 46% | 50% | 100% | 33% | 100% |
| LFM2-24B-A2B-MLX-4bit | 12945 MB | 147 ms | 26.0 | 80% | 52% | 80% | 67% | 67% | 67% |

### Qwen-calibrated diagnostic scoreboard

Use this only as a diagnostic view for larger Qwen models. It adds longer answer budgets, Qwen-specific answer prompts, and post-`</think>` payload extraction. Throughput, RAM, and tool-calling are unchanged.

| Model | RAM | TTFT | 500 T/s | Tools | MMLU | Fae | JSON | XML | YAML |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| qwen3.5-0.8b | 654 MB | 51 ms | 41.3 | 50% | 46% | 65% | 100% | 0% | 33% |
| qwen3.5-2b | 1264 MB | 85 ms | 41.6 | 100% | 52% | 40% | 100% | 33% | 100% |
| qwen3.5-4b | 2527 MB | 165 ms | 31.0 | 100% | 14% | 30% | 100% | 33% | 100% |
| qwen3.5-9b | 5084 MB | 249 ms | 31.6 | 90% | 20% | 20% | 100% | 100% | 0% |
| qwen3.5-27b | 14632 MB | 748 ms | 14.2 | 100% | 20% | 35% | 0% | 67% | 0% |
| qwen3.5-35b-a3b | 18819 MB | 219 ms | 15.9 | 100% | 10% | 30% | 67% | 67% | 0% |
| LFM2.5-1.2B-Instruct-MLX-4bit | 770 MB | 43 ms | 136.8 | 20% | 46% | 50% | 100% | 33% | 100% |
| LFM2-24B-A2B-MLX-4bit | 12945 MB | 147 ms | 26.0 | 80% | 52% | 80% | 67% | 67% | 67% |

### Winner badges

- 🏆 **Best overall Fae default:** `LFM2-24B-A2B-MLX-4bit`
- 🛠️ **Best tool user:** `qwen3.5-2b` for small/fast, `qwen3.5-27b` and `qwen3.5-35b-a3b` for large-tool-routing strength
- 📏 **Best strict structured output:** `qwen3.5-2b` and `LFM2.5-1.2B-Instruct-MLX-4bit`
- ⚡ **Fastest model:** `LFM2.5-1.2B-Instruct-MLX-4bit`
- 🧠 **Best Fae-specific capability score:** `LFM2-24B-A2B-MLX-4bit`
- 🪶 **Best small Qwen balance:** `qwen3.5-2b`

### Recommended defaults by use case

| Use case | Recommended model | Why |
|---|---|---|
| General local Fae default | `LFM2-24B-A2B-MLX-4bit` | Best combined Fae-capability score with solid tools and acceptable speed |
| Tool-heavy assistant on tighter RAM | `qwen3.5-2b` | 100% tool score, low RAM, good TTFT, clean JSON/YAML |
| Ultra-fast fallback | `LFM2.5-1.2B-Instruct-MLX-4bit` | Best TTFT and throughput, but weak tool use |
| Qwen diagnostic / larger-model experiments | `qwen3.5-9b` or `qwen3.5-35b-a3b` with calibrated evals | Generic benchmark undercounts them due to long reasoning / delayed finalization |

### Caveats

- The generic scoreboard is the fair apples-to-apples comparison.
- The Qwen-calibrated scoreboard is not the default benchmark; it is a diagnostic best-effort path for long-thinking Qwen variants.
- Larger Qwen models were previously undercounted because answers and structured payloads sometimes appeared only after long reasoning blocks.
- Qwen does **not** appear to inherently dislike JSON; larger-model failures were mostly compliance / finalization issues.

## Model Summary

| Model | GGUF Size | Idle RAM | Peak T/s (raw) | Peak T/s (/no_think) | 8.5K ctx T/s |
|---|---|---:|---:|---:|---:|
| Qwen3-0.6B | ~400 MB | 2.2 GB | 129 | 114 | 56 |
| Qwen3-1.7B | ~1.1 GB | 4.3 GB | 95 | 85 | 27 |
| Qwen3-4B | ~2.5 GB | 6.5 GB | 57 | 53 | 16 |
| Qwen3-8B | ~5.0 GB | 10.9 GB | 43 | 39 | 11 |

"Peak T/s (raw)" = thinking ON, measures raw decode speed.
"Peak T/s (/no_think)" = Fae's production config, measures effective throughput.
"8.5K ctx T/s" = /no_think at full 6,379-word context.

## Speed by Context Size — /no_think (Fae production config)

These are the numbers that matter for Fae. System prompt includes `/no_think` injection.

| Context | 0.6B | 1.7B | 4B | 8B |
|---|---:|---:|---:|---:|
| Short (~20 tok) | 95 | 71 | 47 | 39 |
| ~200 tok | 114 | 83 | 52 | 37 |
| ~500 tok | 77 | 85 | 53 | 35 |
| ~1K tok | 92 | 81 | 52 | 33 |
| ~2K tok | 89 | 64 | 41 | 25 |
| ~4K tok | 83* | 46 | 35 | 20 |
| ~8.5K tok (6,379 words) | 56* | 27 | 16 | 11 |

*0.6B leaked thinking tokens at 4K+ context (1,346c at 4K, 1,043c at 8.5K) despite
`/no_think` — the model is too small to reliably follow the instruction. 4B had perfect
0c thinking across all sizes; 1.7B and 8B showed only 2c (negligible).

## Speed by Context Size — Raw Throughput (thinking ON)

Raw decode speed with thinking ON. Higher T/s because more tokens are generated
(amortizing prefill), but wall time is dramatically worse.

| Context | 0.6B | 1.7B | 4B | 8B |
|---|---:|---:|---:|---:|
| Short (~20 tok) | 129 | 95 | 57 | 43 |
| ~200 tok | 121 | 92 | 57 | 41 |
| ~500 tok | 116 | 89 | 56 | 40 |
| ~1K tok | 110 | 83 | 52 | 36 |
| ~2K tok | 99 | 77 | 46 | 32 |
| ~4K tok | 82 | 64 | 36 | 25 |
| ~8.5K tok (6,379 words) | 56 | 42 | 21 | 16 |

## Prefix Caching Results (Qwen3-1.7B)

mistral.rs has built-in sequence-level prefix caching (`--prefix-cache-n 16`). When the
system prompt is identical across turns, the KV cache for the prefix is reused.

### Single-turn with shared system prompt (~714 token prefix)

| Turn | User Message | Prompt Tok | Wall Time | Gen T/s |
|---|---|---:|---:|---:|
| 1 (cold) | What time is it? | 714 | 1.10s | **58** |
| 2 (cached) | What's the weather like? | 715 | 0.76s | **84** |
| 3 (cached) | Tell me a joke. | 714 | 0.76s | **84** |
| 4+ (cached) | Various queries | ~716 | 0.74s | **86-87** |

**~48% speedup from prefix caching on subsequent turns.**

### Multi-turn conversation (growing context, cached prefix)

| Turn | Prompt Tok | Wall Time | Gen T/s |
|---|---:|---:|---:|
| 1 (cold) | 714 | 1.06s | 60 |
| 2 | 738 | 0.76s | 84 |
| 4 | 808 | 0.78s | 82 |
| 6 | 870 | 0.76s | 84 |
| 8 | 955 | 0.77s | 83 |

Context grows but speed stays flat at 82-84 T/s — the cached prefix dominates.

### System prompt overhead (with vs without)

| Configuration | Prompt Tokens | Wall Time | Gen T/s |
|---|---:|---:|---:|
| No system prompt | 13 | 0.38s | **85** |
| System prompt only (no tools) | 401 | 0.40-0.55s | **58-81** |
| System prompt + tool schemas | 714 | 0.71-0.73s | **44** |

**Tool schemas add ~0.35s to first-token latency.** Strip them when not needed.

## Thinking ON vs OFF (Critical Finding)

Qwen3 has a built-in reasoning mode that generates invisible "thinking" tokens before
the visible answer. **All benchmarks above had thinking ON by default**, which
dramatically inflates completion token counts and wall time.

### Qwen3-1.7B — Thinking ON vs OFF comparison

| Question | Mode | Comp Tokens | Content | Reasoning | Wall Time | Overhead |
|---|---|---:|---:|---:|---:|---|
| Capital of France? | THINK ON | 242 | 271c | 750c | 2.61s | |
| | THINK OFF | 12 | 33c | 2c | 0.23s | 20x tokens, 11x time |
| Quantum computing? | THINK ON | 233 | 349c | 801c | 2.43s | |
| | THINK OFF | 48 | 241c | 2c | 0.53s | 5x tokens, 5x time |
| 17 * 23? | THINK ON | 256 | 0c | 686c | 2.70s | |
| | THINK OFF | 8 | 5c | 2c | 0.16s | 32x tokens, 17x time |

### What this means

1. **With thinking ON, the model generates 5-32x more tokens than needed.** For
   "what is 17*23?", it burned all 256 tokens on internal reasoning and produced
   zero visible output.

2. **The T/s numbers above measure total throughput (thinking + answer).** The raw
   generation speed (~93 T/s) is identical either way — but with thinking OFF, a
   simple answer takes 0.16-0.53s instead of 2.4-2.7s.

3. **Fae's `/no_think` injection is doing critical work.** Without it, every voice
   response would have 2-3 seconds of invisible reasoning before the user hears
   anything.

4. **The benchmark numbers remain valid as raw throughput baselines** — they show the
   model's generation speed. But the effective user-facing latency with `/no_think`
   is dramatically better than what the raw numbers suggest, because fewer tokens are
   generated per response.

5. **The real bottleneck for Fae is total tokens generated, not T/s.** With thinking
   off, a typical voice answer is 10-50 tokens (0.1-0.5s at 95 T/s). The context
   scaling numbers still matter for prefill, but generation is near-instant.

### Full /no_think results (all models, all context sizes)

| Model | Context | Prompt Tok | Gen Tok | Visible | Think | Wall Time | Gen T/s | RSS RAM |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| **Qwen3-0.6B** | Short (~20 tok) | 33 | 15 | 51c | 2c | 0.16s | **94.9** | 2,236 MB |
| | ~200 tok ctx | 194 | 85 | 537c | 2c | 0.75s | **113.8** | 2,239 MB |
| | ~500 tok ctx | 411 | 24 | 130c | 2c | 0.31s | **77.1** | 2,241 MB |
| | ~1K tok ctx | 850 | 95 | 558c | 2c | 1.04s | **91.7** | 2,244 MB |
| | ~2K tok ctx | 1,668 | 100 | 616c | 2c | 1.12s | **88.9** | 2,247 MB |
| | ~4K tok ctx | 3,309 | 256 | 0c | 1,346c | 3.10s | **82.7** | 2,258 MB |
| | ~8.5K tok | 7,026 | 256 | 343c | 1,043c | 4.61s | **55.5** | 2,186 MB |
| **Qwen3-1.7B** | Short (~20 tok) | 33 | 13 | 38c | 2c | 0.18s | **70.6** | 4,335 MB |
| | ~200 tok ctx | 194 | 63 | 341c | 2c | 0.76s | **83.0** | 4,337 MB |
| | ~500 tok ctx | 411 | 87 | 534c | 2c | 1.02s | **85.1** | 4,339 MB |
| | ~1K tok ctx | 850 | 217 | 1,169c | 2c | 2.69s | **80.7** | 4,344 MB |
| | ~2K tok ctx | 1,668 | 104 | 643c | 2c | 1.62s | **64.3** | 4,346 MB |
| | ~4K tok ctx | 3,309 | 94 | 591c | 2c | 2.04s | **46.1** | 4,361 MB |
| | ~8.5K tok | 7,026 | 112 | 635c | 2c | 4.08s | **27.4** | 4,435 MB |
| **Qwen3-4B** | Short (~20 tok) | 33 | 23 | 111c | 0c | 0.49s | **46.6** | 6,429 MB |
| | ~200 tok ctx | 194 | 96 | 598c | 0c | 1.83s | **52.3** | 6,431 MB |
| | ~500 tok ctx | 411 | 157 | 939c | 0c | 2.95s | **53.2** | 6,434 MB |
| | ~1K tok ctx | 850 | 256 | 1,350c | 0c | 4.96s | **51.6** | 6,438 MB |
| | ~2K tok ctx | 1,668 | 161 | 957c | 0c | 3.94s | **40.9** | 6,442 MB |
| | ~4K tok ctx | 3,309 | 237 | 1,301c | 0c | 6.73s | **35.2** | 6,449 MB |
| | ~8.5K tok | 7,026 | 155 | 812c | 0c | 9.84s | **15.7** | 6,518 MB |
| **Qwen3-8B** | Short (~20 tok) | 33 | 32 | 124c | 2c | 0.83s | **38.5** | 10,873 MB |
| | ~200 tok ctx | 194 | 88 | 528c | 2c | 2.36s | **37.4** | 10,875 MB |
| | ~500 tok ctx | 411 | 89 | 539c | 2c | 2.51s | **35.4** | 10,878 MB |
| | ~1K tok ctx | 850 | 119 | 709c | 2c | 3.60s | **33.1** | 10,882 MB |
| | ~2K tok ctx | 1,668 | 105 | 650c | 2c | 4.18s | **25.1** | 10,888 MB |
| | ~4K tok ctx | 3,309 | 135 | 821c | 2c | 6.91s | **19.5** | 10,904 MB |
| | ~8.5K tok | 7,026 | 137 | 768c | 2c | 12.98s | **10.6** | 10,978 MB |

### /no_think compliance by model

| Model | Think Leakage | Notes |
|---|---|---|
| Qwen3-0.6B | Leaks at 4K+ | 1,346c at 4K, 1,043c at 8.5K — too small to follow instruction |
| Qwen3-1.7B | 2c (negligible) | Clean compliance across all context sizes |
| Qwen3-4B | **0c (perfect)** | Best compliance — Instruct-2507 variant handles `/no_think` natively |
| Qwen3-8B | 2c (negligible) | Clean compliance across all context sizes |

### Effective voice latency (thinking OFF)

| Answer Length | Tokens | Time at 85 T/s (1.7B) | User Perception |
|---|---:|---:|---|
| Short (yes/no) | 5-10 | 0.06-0.12s | Instant |
| One sentence | 15-25 | 0.18-0.29s | Instant |
| Brief answer | 30-50 | 0.35-0.59s | Very fast |
| Detailed answer | 80-120 | 0.94-1.41s | Natural pause |
| Long explanation | 150-200 | 1.76-2.35s | Comfortable |

**With `/no_think` and prefix caching, generation time is no longer a bottleneck for
voice.** Prefill (processing the system prompt + history) dominates latency.

---

## Key Observations

1. **RAM is flat across context sizes.** KV cache lives on the Metal GPU, not in RSS.
   The RSS numbers reflect model weights + runtime overhead only. Context size impacts
   speed, not RAM.

2. **RAM scales linearly with model size.** Roughly 1.3-1.4 GB per billion parameters
   at Q4_K_M quantization.

3. **Voice threshold is ~60 T/s** for natural conversational flow (first-token latency
   under 1s, full response in 2-4s). Above this threshold, the user perceives continuous
   speech with no awkward pauses.

4. **Usable voice context window per model (/no_think):**
   - 0.6B: up to ~8.5K tokens (but leaks thinking above 4K)
   - 1.7B: up to ~1K tokens (85 T/s), drops to 64 at 2K
   - 4B: up to ~500 tokens (53 T/s), drops below 60 quickly
   - 8B: never reaches 60 T/s at any context length

5. **Context is the bottleneck, not parameters.** A 1.7B model at 1K context (81 T/s)
   outperforms a 4B model at 500 tokens (53 T/s) for voice use cases. This is the
   core insight behind Fae's dual-channel architecture.

6. **Prefix caching gives ~48% speedup** on repeated system prompts. Multi-turn
   conversations stay fast as long as the system prompt prefix is unchanged.

7. **Tool schemas cost ~0.35s per request** (313 extra tokens). For voice-only turns,
   stripping tools saves meaningful latency.

8. **Thinking tokens are the dominant latency source.** With thinking ON, even simple
   answers take 2-3s. With `/no_think`, the same answers take 0.1-0.5s. This single
   optimization is worth more than model size, context budget, and prefix caching
   combined for voice use cases.

## Implications for Fae's Architecture

### Dual-Channel Pipeline

These benchmarks drove the design of Fae's dual-channel LLM architecture:

- **Voice channel** (fast path): Slim prompt (~1.5K tokens), no tool schemas,
  `/no_think` mode. With thinking off and prefix caching, generation takes 0.1-0.6s
  for typical voice answers — effectively instant. The 1.7B model at ~500 tok context
  gives ~85 T/s.

- **Background channel** (async path): Full prompt with tool schemas (~8-18K tokens
  depending on active tools). Runs asynchronously while the user hears an immediate
  canned acknowledgment. May use thinking mode for complex reasoning tasks where
  quality matters more than speed.

### Model Selection Strategy

| System RAM | Voice Model | Background Model | Rationale |
|---|---|---|---|
| 8-16 GB | 0.6B | 0.6B | Only option that fits; usable voice up to 4K ctx |
| 16-32 GB | 1.7B | 1.7B | Best voice quality; 85 T/s at ~500 tok ctx |
| 32-64 GB | 1.7B | 4B | Fast voice + stronger tool reasoning |
| 64+ GB | 1.7B | 8B | Fast voice + best tool/coding capability |

The voice channel should always use a small, fast model regardless of available RAM.
Throwing a larger model at voice just slows it down without meaningful quality gains
for short conversational turns.

### Context Budget Guidelines

To maintain voice-quality speed (>60 T/s) with `/no_think`:

| Model | Max system prompt | Max history | Total budget | T/s at budget |
|---|---|---|---|---:|
| 0.6B | ~500 tok | ~1.5K tok | ~2K tok | ~89 |
| 1.7B | ~500 tok | ~500 tok | ~1K tok | ~81 |
| 4B | ~200 tok | ~300 tok | ~500 tok | ~53 |

The 1.7B drops from 85 T/s at 500 tok to 64 T/s at 2K — keep the voice prompt lean.
The background channel has no such constraint — it can use the full context window.

---

## Reproducing These Benchmarks

### Prerequisites

```bash
# Install mistral.rs CLI with Metal GPU support (~5 min compile)
cargo install mistralrs-cli --features metal

# Verify installation
mistralrs --version
```

### Download models

```bash
# Install Python huggingface_hub if not present
pip3 install huggingface_hub

# Download all four models (GGUF quantized + tokenizers)
python3 -c "
from huggingface_hub import hf_hub_download

models = [
    ('unsloth/Qwen3-0.6B-GGUF', 'Qwen3-0.6B-Q4_K_M.gguf', 'Qwen/Qwen3-0.6B'),
    ('unsloth/Qwen3-1.7B-GGUF', 'Qwen3-1.7B-Q4_K_M.gguf', 'Qwen/Qwen3-1.7B'),
    ('unsloth/Qwen3-4B-Instruct-2507-GGUF', 'Qwen3-4B-Instruct-2507-Q4_K_M.gguf', 'Qwen/Qwen3-4B-Instruct-2507'),
    ('unsloth/Qwen3-8B-GGUF', 'Qwen3-8B-Q4_K_M.gguf', 'Qwen/Qwen3-8B'),
]

for repo, gguf, tok_repo in models:
    print(f'Downloading {repo}...')
    hf_hub_download(repo, gguf)
    for f in ['tokenizer.json', 'tokenizer_config.json', 'generation_config.json']:
        hf_hub_download(tok_repo, f)
    print(f'  Done.')
"
```

### Quick single-model benchmark

Start a server, send requests, measure wall-clock time:

```bash
# Start the server (pick a model)
mistralrs serve \
  --format gguf \
  -m unsloth/Qwen3-1.7B-GGUF \
  -f Qwen3-1.7B-Q4_K_M.gguf \
  --tok-model-id Qwen/Qwen3-1.7B \
  --port 8787 \
  --max-seq-len 16384 \
  --prefix-cache-n 16

# Wait for "Server listening on http://0.0.0.0:8787"

# Send a test request (with /no_think to match Fae's production config)
time curl -s http://localhost:8787/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "default",
    "messages": [
      {"role":"system","content":"/no_think\n\nYou are a helpful assistant. Be concise."},
      {"role":"user","content":"What is the weather like today?"}
    ],
    "max_tokens": 128,
    "temperature": 0.7,
    "stream": false
  }' | python3 -c "
import json, sys
r = json.load(sys.stdin)
u = r.get('usage', {})
print(f'Prompt: {u.get(\"prompt_tokens\")} tok, Gen: {u.get(\"completion_tokens\")} tok')
"
```

### Full automated benchmark (all models, all context sizes, /no_think)

This script tests all four models across 7 context sizes with `/no_think` (Fae's
production config) and RAM tracking. Takes ~10-15 minutes total.

```bash
# Generate the test prompt corpus (~6,400 words of natural English)
python3 -c "
sentences = [
    'The history of artificial intelligence is a fascinating journey through decades of research and development.',
    'Machine learning algorithms have transformed how we process and understand data across many industries.',
    'Neural networks inspired by biological systems have become the foundation of modern deep learning approaches.',
    'Natural language processing enables computers to understand and generate human language with increasing accuracy.',
    'Computer vision systems can now identify objects and faces with superhuman performance in many benchmarks.',
    'Reinforcement learning has achieved remarkable results in game playing and robotics applications worldwide.',
    'The ethical implications of artificial intelligence deployment require careful consideration and governance frameworks.',
    'Transfer learning allows models trained on one task to be adapted efficiently for related problems and domains.',
    'Generative models can create realistic images text and audio that are increasingly difficult to distinguish from human work.',
    'Edge computing brings machine learning inference closer to data sources reducing latency and improving privacy.',
    'Federated learning enables training models across distributed devices without centralizing sensitive personal data.',
    'Quantum computing promises to accelerate certain machine learning algorithms exponentially in the coming decades.',
    'Autonomous vehicles rely on a combination of sensors machine learning and real time decision making systems.',
    'Healthcare applications of AI include medical image analysis drug discovery and personalized treatment planning.',
    'Climate modeling and environmental monitoring benefit from advanced machine learning prediction capabilities.',
    'Robotics and automation continue to evolve with improved perception planning and manipulation abilities.',
    'The democratization of AI tools has made machine learning accessible to developers without specialized training.',
    'Large language models have demonstrated emergent capabilities that were not explicitly programmed or expected.',
    'Data privacy regulations like GDPR impact how machine learning systems collect process and store information.',
    'The computational costs of training large models raise questions about environmental sustainability and access.',
]
text = ''
count = 0
while len(text.split()) < 6379:
    text += sentences[count % len(sentences)] + ' '
    count += 1
text += 'Given all of this context about artificial intelligence, what are the three most important developments?'
with open('/tmp/fae_bench_prompt.txt', 'w') as f:
    f.write(text)
print(f'Generated {len(text.split())} words')
"
```

```bash
# Run the full benchmark with /no_think (Fae production config)
python3 << 'BENCH_EOF'
import subprocess, json, time

# /no_think injection — same as Fae's local.rs does in production
SYSTEM_NO_THINK = "/no_think\n\nYou are a helpful assistant. Be concise."

MODELS = [
    ("Qwen3-0.6B",  "--format gguf -m unsloth/Qwen3-0.6B-GGUF -f Qwen3-0.6B-Q4_K_M.gguf --tok-model-id Qwen/Qwen3-0.6B"),
    ("Qwen3-1.7B",  "--format gguf -m unsloth/Qwen3-1.7B-GGUF -f Qwen3-1.7B-Q4_K_M.gguf --tok-model-id Qwen/Qwen3-1.7B"),
    ("Qwen3-4B",    "--format gguf -m unsloth/Qwen3-4B-Instruct-2507-GGUF -f Qwen3-4B-Instruct-2507-Q4_K_M.gguf --tok-model-id Qwen/Qwen3-4B-Instruct-2507"),
    ("Qwen3-8B",    "--format gguf -m unsloth/Qwen3-8B-GGUF -f Qwen3-8B-Q4_K_M.gguf --tok-model-id Qwen/Qwen3-8B"),
]

with open("/tmp/fae_bench_prompt.txt") as f:
    big = f.read().strip()

def prompt(n_words):
    w = big.split()
    return " ".join(w[:n_words]) + " Summarize." if n_words < len(w) else big

TESTS = [
    ("Short (~20 tok)",          "What is the weather like today?", 128),
    ("~200 tok ctx",             prompt(150),  256),
    ("~500 tok ctx",             prompt(350),  256),
    ("~1K tok ctx",              prompt(750),  256),
    ("~2K tok ctx",              prompt(1500), 256),
    ("~4K tok ctx",              prompt(3000), 256),
    ("~8.5K tok (6379 words)",   big,          256),
]

PORT = 8787

def get_ram_mb(pid):
    try:
        r = subprocess.run(f"ps -o rss= -p {pid}", shell=True, capture_output=True, text=True, timeout=5)
        return int(r.stdout.strip()) / 1024
    except:
        return None

def get_pid():
    r = subprocess.run(f"lsof -ti:{PORT}", shell=True, capture_output=True, text=True)
    pids = r.stdout.strip().split('\n')
    return pids[0] if pids and pids[0] else None

for name, args in MODELS:
    subprocess.run(f"lsof -ti:{PORT} | xargs kill 2>/dev/null", shell=True)
    time.sleep(3)

    server = subprocess.Popen(
        f"mistralrs serve {args} --port {PORT} --max-seq-len 16384 --prefix-cache-n 16",
        shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )

    for i in range(120):
        r = subprocess.run(f"curl -s http://localhost:{PORT}/health",
                           shell=True, capture_output=True, text=True, timeout=3)
        if r.stdout.strip():
            break
        time.sleep(1)

    pid = get_pid()
    idle_ram = get_ram_mb(pid)

    # Warmup with /no_think
    for _ in range(3):
        payload = json.dumps({"model":"default","messages":[
            {"role":"system","content":SYSTEM_NO_THINK},
            {"role":"user","content":"Hello"}
        ],"max_tokens":16,"temperature":0.7})
        with open("/tmp/bp.json","w") as f: f.write(payload)
        subprocess.run(f'curl -s http://localhost:{PORT}/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/bp.json',
                       shell=True, capture_output=True, timeout=30)
        time.sleep(0.3)

    print(f"\n{'='*80}")
    print(f"  {name} (Q4_K_M, /no_think) — Idle RAM: {idle_ram:.0f} MB" if idle_ram else f"  {name}")
    print(f"{'='*80}")
    print(f"  {'Test':<30} {'Prompt':>8} {'Gen':>5} {'Visible':>8} {'Think':>7} {'Time':>8} {'T/s':>8} {'RAM MB':>8}")
    print(f"  {'-'*84}")

    for label, text, max_tok in TESTS:
        payload = json.dumps({"model":"default","messages":[
            {"role":"system","content":SYSTEM_NO_THINK},
            {"role":"user","content":text}
        ],"max_tokens":max_tok,"temperature":0.7,"stream":False})
        with open("/tmp/bp.json","w") as f: f.write(payload)

        best_tps, best = 0, None
        for _ in range(2):
            start = time.time()
            r = subprocess.run(f'curl -s http://localhost:{PORT}/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/bp.json',
                               shell=True, capture_output=True, text=True, timeout=180)
            elapsed = time.time() - start
            ram = get_ram_mb(pid)
            try:
                resp = json.loads(r.stdout)
                u = resp["usage"]
                m = resp["choices"][0]["message"]
                content = m.get("content") or ""
                reasoning = m.get("reasoning_content") or ""
                tps = u["completion_tokens"] / elapsed
                if tps > best_tps:
                    best_tps = tps
                    best = (u["prompt_tokens"], u["completion_tokens"], len(content), len(reasoning), elapsed, tps, ram)
            except:
                pass
            time.sleep(0.3)

        if best:
            pt, ct, vis, think, el, tps, ram = best
            ram_s = f"{ram:.0f}" if ram else "?"
            print(f"  {label:<30} {pt:>8} {ct:>5} {vis:>7}c {think:>6}c {el:>7.2f}s {tps:>7.1f} {ram_s:>8}")

    server.kill()
    server.wait()
    time.sleep(3)
BENCH_EOF
```

### Prefix caching benchmark

Tests the effect of mistral.rs prefix caching on multi-turn voice conversations.

```bash
# Start 1.7B server
mistralrs serve \
  --format gguf \
  -m unsloth/Qwen3-1.7B-GGUF \
  -f Qwen3-1.7B-Q4_K_M.gguf \
  --tok-model-id Qwen/Qwen3-1.7B \
  --port 8787 \
  --max-seq-len 16384 \
  --prefix-cache-n 16

# In another terminal — send identical-prefix requests to measure cache effect:

SYSTEM="You are Fae, a personal AI companion. You are calm, practical, direct, and warm."

# Turn 1 (cold — no cache)
time curl -s http://localhost:8787/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"default\",\"messages\":[
    {\"role\":\"system\",\"content\":\"$SYSTEM\"},
    {\"role\":\"user\",\"content\":\"What time is it?\"}
  ],\"max_tokens\":64,\"temperature\":0.7}" | python3 -c "
import json,sys; u=json.load(sys.stdin)['usage']
print(f'Prompt: {u[\"prompt_tokens\"]} tok, Gen: {u[\"completion_tokens\"]} tok')"

# Turn 2+ (should hit prefix cache — faster)
time curl -s http://localhost:8787/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"default\",\"messages\":[
    {\"role\":\"system\",\"content\":\"$SYSTEM\"},
    {\"role\":\"user\",\"content\":\"Tell me a joke.\"}
  ],\"max_tokens\":64,\"temperature\":0.7}" | python3 -c "
import json,sys; u=json.load(sys.stdin)['usage']
print(f'Prompt: {u[\"prompt_tokens\"]} tok, Gen: {u[\"completion_tokens\"]} tok')"
```

Compare wall times: turn 2+ should be ~30-50% faster than turn 1 with the same
system prompt prefix.

### Tips for reliable results

- **Run models sequentially**, not concurrently — Metal GPU contention causes wild variance.
- **Allow 3s cooldown** between stopping one server and starting another.
- **Warmup with 2-3 throwaway requests** before measuring — Metal shader compilation
  happens on first inference.
- **Take the best of 2 runs** per test — the first run sometimes includes one-time costs.
- **Don't run other GPU-heavy apps** (browsers with WebGL, video editors) during benchmarks.
- **Check `ps -o rss=` for RAM**, not Activity Monitor — AM includes shared frameworks.
- **Always inject `/no_think`** in the system prompt to suppress Qwen3 thinking tokens.
  Without it, every response burns 2-3s on invisible reasoning. Fae does this automatically
  in `src/fae_llm/providers/local.rs`.

### Model reference

| Model | HuggingFace Repo | GGUF File | Tokenizer |
|---|---|---|---|
| Qwen3-0.6B | `unsloth/Qwen3-0.6B-GGUF` | `Qwen3-0.6B-Q4_K_M.gguf` | `Qwen/Qwen3-0.6B` |
| Qwen3-1.7B | `unsloth/Qwen3-1.7B-GGUF` | `Qwen3-1.7B-Q4_K_M.gguf` | `Qwen/Qwen3-1.7B` |
| Qwen3-4B | `unsloth/Qwen3-4B-Instruct-2507-GGUF` | `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | `Qwen/Qwen3-4B-Instruct-2507` |
| Qwen3-8B | `unsloth/Qwen3-8B-GGUF` | `Qwen3-8B-Q4_K_M.gguf` | `Qwen/Qwen3-8B` |

### Models tested but incompatible or unusable with mistral.rs + Metal

We extensively tested every current-gen sub-4B model available as of Feb 2026. This table
documents every model that was tested and why it didn't work for Fae.

| Model | Architecture | GGUF Size | Error / Issue | Notes |
|---|---|---:|---|---|
| **Ministral-3 3B** (Dec 2025) | mistral3 | 2.0 GB | **~5 T/s** (10x too slow) | Loads with patched mistral.rs (verify_arch_any bug fix), Metal kernels unoptimized for Mistral3 attention |
| **SmolLM3 3B** (Feb 2026) | smollm3 | 1.8 GB | `Unknown GGUF architecture 'smollm3'` | smollm3 only in non-GGUF arch list; GGUF enum doesn't include it |
| **Phi-4-mini-instruct** (3.8B) | phi3 | 2.5 GB | `Cannot find tensor info for output.weight` | Tied embeddings not handled by Phi3 GGUF loader |
| **Qwen3-30B-A3B MoE** (3B active) | qwen3moe | 18.6 GB | `indexed_moe_forward is not implemented` | MoE kernel only exists for CUDA, not Metal |
| **Liquid LFM2** (all variants) | lfm2 | varies | Architecture not supported | Hybrid SSM — not a transformer, not in any arch list |
| **IBM Granite 3.2 2B** | granite | N/A | Architecture not supported | `granite` not in GGUF arch list |
| **EXAONE 3.5 2.4B** | exaone | N/A | Architecture not supported | `exaone` not in GGUF arch list |
| **Gemma 3 1B/4B** | gemma3 | N/A | Architecture not in GGUF list | `gemma3` only available via non-GGUF ISQ path |
| **Qwen3.5-27B** (Feb 2026) | qwen35 | ~16 GB Q4_K_M | `Unknown GGUF architecture 'qwen35'` | Entirely new architecture: Gated Delta Networks + sparse MoE hybrid; 64 layers, interleaved linear attention and gated attention; not a Qwen3 descendant in GGUF terms |
| **Qwen3.5-35B-A3B MoE** (Feb 2026) | qwen35moe | ~22 GB Q4_K_M | `Unknown GGUF architecture 'qwen35moe'` | MoE variant of the qwen35 hybrid arch (35B total / 3B active); 256 experts, 8+1 active; same Gated DeltaNet hybrid; double incompatibility: unknown arch AND MoE kernel missing on Metal |

**Ministral-3 benchmark detail** (loaded successfully, but generation is crippled):

| Ctx Target | Prompt Tok | Compl Tok | T/s | RAM MB |
|---:|---:|---:|---:|---:|
| 20 | 25 | 119 | 4.8 | 4,466 |
| 100 | 25 | 88 | 5.7 | 4,466 |
| 500 | 472 | 101 | 4.5 | 4,467 |
| 1000 | 528 | 112 | 5.3 | 4,468 |
| 4000 | 3,528 | 100 | 3.4 | 4,473 |

The Llama GGUF loader handles Mistral3 tensor layout but the Metal kernels don't properly
optimize for Mistral3-specific features (sliding window attention, `temperature_scale: 0.1`).
Prompt processing is fast (~1,300 T/s) but generation is 10-20x slower than Qwen3 at the
same parameter count. This makes Ministral-3 unusable for voice (needs >60 T/s).

**mistral.rs 0.7.1-alpha.1 GGUF architecture list:** Llama, Mistral3, Phi2, Phi3,
Starcoder2, Qwen2, Qwen3, Qwen3MoE (MoE requires CUDA). Non-GGUF (safetensors/ISQ)
adds: SmolLM3, Gemma, Gemma2, GLM4, DeepSeekV2/V3, GraniteMoEHybrid, GPT-OSS, Qwen3Next.

**Qwen3.5 is a completely new architecture family, not an extension of Qwen3.**
Verified by reading the `general.architecture` field directly from the GGUF binary headers:

| Model | general.architecture |
|---|---|
| Qwen3-0.6B / 1.7B / 4B / 8B | `qwen3` |
| Qwen3-30B-A3B (MoE) | `qwen3moe` |
| Qwen3.5-27B | `qwen35` |
| Qwen3.5-35B-A3B (MoE) | `qwen35moe` |

The qwen35 architecture uses Gated Delta Networks (linear attention) interleaved with
standard gated attention, a fundamentally different compute pattern from Qwen3's
transformer-only design. mistral.rs has no Metal kernels for this pattern as of
0.7.1-alpha.1. Support would require upstream implementation of both the qwen35 GGUF
arch variant and the Gated DeltaNet forward pass — neither exists on master as of
Feb 2026.

**Conclusion: Qwen3 is the only viable model family for Fae on mistral.rs + Metal.**
No other current-gen small model (sub-4B) achieves usable voice-quality T/s on Apple
Silicon through mistral.rs. Older models (Llama 3.2, Qwen2.5) use the `llama`/`qwen2`
arch and would load, but are superseded by Qwen3 in quality and instruction following.
The Qwen3.5 series, while architecturally interesting, requires new backend support
that does not yet exist in mistral.rs.

### Qwen3.5 deep dive: fork vs wait analysis

**Qwen3.5 is not a variant of Qwen3.** The two model families use fundamentally different
attention mechanisms:

| Aspect | Qwen3 | Qwen3.5 |
|--------|-------|---------|
| Attention | Standard GQA (softmax) | **Hybrid: 75% Gated DeltaNet + 25% full attention** |
| Complexity | O(n²) per layer | O(n) for GDN layers, O(n²) for 1-in-4 full layers |
| KV cache | Grows with context | **No KV cache growth for GDN layers** |
| Positional encoding | RoPE | **Interleaved-MRoPE** |
| Multimodal | Separate VL variant | Native multimodal from pretraining |
| Languages | 119 | 201 |

**Gated Delta Networks (GDN)** is a real architectural innovation (ICLR 2025, from NVIDIA).
Each GDN block requires Q, K, V projections with 1D convolutions for short-context mixing,
delta rule state updates (selective modification, not O(n²) attention), gating projections
(`b_proj`, `a_proj`, `g_proj`), `FusedRMSNormSwishGate` activations, and interleaving with
1 full-attention block per 4 total blocks.

This is not a GGUF metadata issue that can be patched with a new enum entry — the forward
pass itself is incompatible. Plugging Qwen3.5 weights into the Qwen3 forward pass would
produce garbage output.

**Estimated implementation scope to add Qwen3.5 support to mistral.rs:**

| Component | Est. Lines | Notes |
|-----------|----------:|-------|
| Gated DeltaNet operator (CPU) | 1,000–1,500 | New from scratch |
| GDN Metal kernel (Apple Silicon) | 500–800 | No existing template |
| Hybrid attention scheduler | 300–500 | Interleave GDN + full attn blocks |
| Interleaved-MRoPE | 200–300 | New positional encoding variant |
| GGUF enum + model wiring | 200–300 | Straightforward plumbing |
| MoE routing (35B-A3B only) | +500 | Optional; separate model variant |
| **Total** | **~2,500–3,500** | **2–4 weeks, not 2 days** |

**Recommendation: wait for upstream.** GitHub issue #1939 was filed on mistral.rs
requesting Qwen3.5 support with the full architectural context. Upstream is incentivized
to add it (mistral.rs needs Qwen3.5 to stay competitive); estimated timeline is 4–8 weeks
based on past Qwen3 turnaround. A fork at this point creates ongoing rebase overhead
against a rapidly moving project with no urgency — Qwen3-8B is still excellent for Fae's
voice use case.

**When to reconsider forking:**
- No upstream activity on Qwen3.5 after 8 weeks
- A community fork with Metal GDN support already exists (free starting point)
- A specific Fae capability requires Qwen3.5 that Qwen3 cannot provide

**When upstream lands, benchmark:**
- Qwen3.5-27B (dense, ~16 GB Q4_K_M) — primary interest for 64GB+ systems
- Qwen3.5-35B-A3B (MoE, ~22 GB Q4_K_M) — secondary; MoE kernel must also land
- Follow the standard eval process: 7 context sizes, `/no_think` compliance, T/s ≥20 for voice
- Files to update: this doc (add benchmark rows), `src/config.rs` (`recommended_local_model()`), `Cargo.toml`

### mistral.rs verify_arch_any bug

While testing Ministral-3, we discovered a bug in mistral.rs 0.7.1-alpha.1 where
`verify_arch_any()` used `try_for_each` (requiring ALL architectures to match) instead
of `any()` (requiring ANY to match). The function at `mistralrs-core/src/utils/gguf_metadata.rs:153`
was patched locally:

```rust
// BUG: try_for_each requires ALL to match — should be ANY
pub fn verify_arch_any(&self, expected_archs: &[&str]) -> Result<()> {
    let actual_arch: String = self.metadata.get("general.architecture")...;
    if expected_archs.iter().any(|&arch| arch == actual_arch) {
        Ok(())
    } else {
        anyhow::bail!("Expected one of {:?}, got `{actual_arch}`.", expected_archs)
    }
}
```

This fix was required to load any GGUF model whose architecture is listed alongside
`llama` in `verify_arch_any` calls (e.g., Ministral-3 which reports `mistral3` but uses
the Llama loader). Without this fix, the model fails with `Expected 'llama' architecture,
got 'mistral3'`.

---

## Qwen3-1.7B Sampling Parameter Tuning

Systematic benchmark testing 9 sampling configurations against 15 prompts to optimize
voice quality, speed, conciseness, tool routing accuracy, and repetition avoidance.

**Hardware:** Apple Silicon, 96 GB unified memory
**Model:** Qwen3-1.7B Q4_K_M, server RAM: ~2.7 GB idle
**Server:** mistral.rs 0.7.1-alpha.1, `--max-seq-len 16384 --prefix-cache-n 16`
**Date:** 2026-02-23

### Critical bug found: penalty parameter misuse

`src/agent/mod.rs:863-864` feeds `repeat_penalty=1.15` as `frequency_penalty` and
`repeat_penalty * 0.5 = 0.575` as `presence_penalty`. Standard range for these OpenAI-style
penalties is 0.0-2.0 but typical values are 0.0-0.5. Using 1.15 as frequency_penalty is
extremely aggressive and degrades output quality.

The correct fix: zero out `frequency_penalty` and `presence_penalty`, use `repetition_penalty`
(a separate mistralrs sampler that operates on token repeats directly) instead.

### Sampling configurations tested

| ID | temp | top_p | top_k | min_p | freq | pres | rep_pen | max_tok | Description |
|----|------|-------|-------|-------|------|------|---------|---------|-------------|
| **S0** | 0.9 | 0.9 | - | - | 1.15 | 0.575 | - | 200 | Current production (penalty bug) |
| **S1** | 0.9 | 0.9 | - | - | 0.0 | 0.0 | 1.15 | 200 | Bug fix — proper repetition_penalty |
| **S2** | 0.6 | 0.9 | - | - | 0.0 | 0.0 | 1.15 | 200 | Lower temp for predictable voice |
| **S3** | 0.7 | 1.0 | - | 0.05 | 0.0 | 0.0 | 1.15 | 128 | min_p replaces top_p |
| **S4** | 0.7 | 0.9 | 40 | - | 0.0 | 0.0 | 1.1 | 128 | top_k as diversity limiter |
| **S5** | 0.8 | 1.0 | - | 0.1 | 0.0 | 0.0 | 1.1 | 128 | Aggressive min_p |
| **S6** | 0.7 | 0.9 | - | 0.05 | 0.0 | 0.0 | 1.0 | 128 | DRY anti-repetition |
| **S7** | 0.2 | 0.9 | - | - | 0.0 | 0.0 | 1.0 | 200 | TOOL_JUDGMENT_TEMPERATURE |
| **S8** | 0.0 | - | 1 | - | 0.0 | 0.0 | - | 128 | Greedy (speed ceiling) |

### Results: Overall performance

| Config | Avg T/s | Med T/s | Avg Visible | Avg Time | Think Leaks |
|--------|--------:|--------:|------------:|---------:|:-----------:|
| S0 (bug) | 82.7 | 84.7 | 161c | 0.46s | 0/13 |
| S1 (fix) | 83.3 | 86.2 | 143c | 0.43s | 0/14 |
| S2 (low temp) | 80.0 | 82.6 | 125c | 0.41s | 0/14 |
| S3 (min_p) | 81.9 | 85.0 | 150c | 0.48s | 0/14 |
| **S4 (top_k)** | **96.5** | **98.9** | 148c | 0.39s | 0/14 |
| S5 (min_p high) | 78.0 | 81.4 | 148c | 0.46s | 0/14 |
| S6 (DRY) | 78.3 | 81.3 | 139c | 0.43s | 0/14 |
| S7 (0.2 temp) | 92.1 | 95.9 | 139c | 0.37s | 0/14 |
| S8 (greedy) | 104.4 | 105.8 | 124c | 0.36s | 0/15 |

### Results: Quick voice (Category A — 5 factual questions)

| Config | Avg T/s | Avg Visible | Avg Time |
|--------|--------:|------------:|---------:|
| S0 (bug) | 71.6 | 65c | 0.27s |
| S1 (fix) | 77.3 | 70c | 0.31s |
| S2 (low temp) | 77.6 | 66c | 0.29s |
| S3 (min_p) | 76.0 | 77c | 0.34s |
| **S4 (top_k)** | **91.1** | 69c | 0.26s |
| S5 (min_p high) | 69.1 | 39c | 0.23s |
| S6 (DRY) | 70.7 | 42c | 0.22s |
| S7 (0.2 temp) | 80.4 | 44c | 0.20s |
| S8 (greedy) | 89.7 | 44c | 0.18s |

### Results: Repetition stress (D category)

| Config | D1 Scotland | D2 Camping |
|--------|------------:|-----------:|
| S0 (bug) | 379c | 129c |
| S1 (fix) | 243c | 157c |
| S2 (low temp) | 233c | 130c |
| S3 (min_p) | 352c | 168c |
| **S4 (top_k)** | 361c | 158c |
| S5 (min_p high) | 481c | 122c |
| S6 (DRY) | 338c | 140c |
| S7 (0.2 temp) | 444c | 168c |
| S8 (greedy) | 441c | 141c |

No repetition loops observed in any configuration. The 1.7B model handles free-form
generation without degenerate repetition across all tested sampling strategies.

### Results: Tool routing accuracy (Phase 3)

10 prompts with tool schemas (calendar, email, web_search, reminders). Tested at voice
temperature and at TOOL_JUDGMENT_TEMPERATURE (0.2).

| Config | Correct | Total | Accuracy |
|--------|--------:|------:|---------:|
| S4 voice temp (0.7) | 9 | 10 | **90%** |
| Tool temp (0.2) | 10 | 10 | **100%** |

At voice temp (0.7), the model missed one ambiguous prompt ("Can you look something up
for me about quantum computing?" — expected web_search, got no tool). At 0.2, all 10
prompts routed correctly. This confirms the dual-temperature approach is correct:
TOOL_JUDGMENT_TEMPERATURE=0.2 for tool decisions, higher temp for voice generation.

### Key findings

1. **Penalty bug impact is measurable but not catastrophic.** S0 (bug) vs S1 (fix):
   82.7 vs 83.3 T/s, 161c vs 143c avg visible. The bugged penalties make output ~12%
   more verbose but don't cause repetition loops. Still must be fixed — wrong parameters.

2. **S4 (top_k=40) is the clear winner for voice.** 96.5 avg T/s (16% faster than S0),
   91.1 T/s on quick voice (27% faster than S0), good conciseness, zero think leaks.
   The `top_k=40` constraint limits the sampling space efficiently.

3. **Greedy (S8) is the speed ceiling at 104 T/s** but produces deterministic output
   unsuitable for conversational voice (identical responses every time, no variety).

4. **Tool routing at 0.2 temp achieves 100% accuracy.** The dual-temperature approach
   (0.2 for tool judgment, 0.7 for voice) is validated.

5. **min_p and DRY don't help speed.** S5 (min_p=0.1) and S6 (DRY) both scored lower
   T/s than S4. The overhead of these samplers negates any benefit for a 1.7B model.

6. **Zero thinking leaks across all configs.** The `/no_think` injection works perfectly
   with 1.7B — no config tested showed any thinking tokens.

### Recommended defaults for Fae

```
# Voice channel (conversational generation)
temperature = 0.7
top_p = 0.9
top_k = 40
frequency_penalty = 0.0
presence_penalty = 0.0
repetition_penalty = 1.1
max_tokens = 128

# Tool judgment (already correct)
TOOL_JUDGMENT_TEMPERATURE = 0.2
```

### Code changes needed

1. **Fix penalty bug** in `src/agent/mod.rs:863-864`:
   - Remove `.with_frequency_penalty(config.repeat_penalty)` (was 1.15)
   - Remove `.with_presence_penalty(config.repeat_penalty * 0.5)` (was 0.575)
   - Add `.with_repetition_penalty(config.repeat_penalty)` if/when mistralrs exposes it

2. **Update defaults** in `src/config.rs`:
   - `temperature: 0.7` (was 0.9)
   - `repeat_penalty: 1.1` (was 1.15)
   - `max_tokens: 128` (was 200)

3. **Add `top_k` field** to `LlmConfig` and `LocalMistralrsConfig`:
   - Default: 40
   - Wire through to `set_sampler_topk()` in the request builder

### Benchmark script

The benchmark script is at `/tmp/fae_tuning_bench.py`. To re-run:

```bash
# Start the server
mistralrs serve \
  --format gguf \
  -m unsloth/Qwen3-1.7B-GGUF \
  -f Qwen3-1.7B-Q4_K_M.gguf \
  --tok-model-id Qwen/Qwen3-1.7B \
  --port 8787 \
  --max-seq-len 16384 \
  --prefix-cache-n 16

# Run the benchmark
python3 /tmp/fae_tuning_bench.py

# Results saved to /tmp/fae_tuning_results.json
```

---

## MLX Benchmark Results (Swift, Feb 2026)

Since v0.8.0, Fae runs on **MLX** (mlx-swift-lm) instead of mistral.rs. This
enables benchmarking models that were previously impossible — including the Qwen3.5
family (Gated DeltaNet architecture) which has no Metal kernels in mistral.rs.

**Hardware:** Apple Silicon (M4 Max), 96 GB unified memory
**Quantization:** 4-bit (MLX community conversions)
**Backend:** mlx-swift-lm (native Swift — same stack as Fae.app)
**Measurement:** MLX-internal generation T/s (`genTokens / generateTime`, excludes prompt prefill)
**Model cache:** `~/.cache/huggingface/hub/` (shared with Fae.app)

### Models tested

| Model | Hub ID | Type | Active Params | Disk (4-bit) |
|-------|--------|------|---------------|-------------|
| Qwen3-0.6B | `mlx-community/Qwen3-0.6B-4bit` | Dense | 0.6B | ~0.4 GB |
| Qwen3-1.7B | `mlx-community/Qwen3-1.7B-4bit` | Dense | 1.7B | ~1.1 GB |
| Qwen3-4B | `mlx-community/Qwen3-4B-4bit` | Dense | 4B | ~2.5 GB |
| Qwen3-8B | `mlx-community/Qwen3-8B-4bit` | Dense | 8B | ~5.0 GB |
| **Qwen3.5-35B-A3B** | `NexVeridian/Qwen3.5-35B-A3B-4bit` | MoE | **3B active** | ~19.5 GB |
| **Qwen3.5-27B** | `NexVeridian/Qwen3.5-27B-4bit` | Hybrid dense | ~27B | ~15.1 GB |

**Important: Qwen3.5 text-only model IDs.** The `mlx-community` Qwen3.5 conversions include
the vision tower (VL) and fail to load in `mlx-lm`. The `NexVeridian` conversions strip
the vision tower and load correctly as text-only models. Use NexVeridian IDs for text inference.

### Why MLX can run Qwen3.5

The mistral.rs section above documented that Qwen3.5 uses Gated Delta Networks —
a fundamentally different attention mechanism that mistral.rs has no Metal kernels for.
MLX handles this natively because:

1. **mlx-lm reads model architecture from `config.json`** — no hardcoded GGUF arch enum
2. **MLX compiles operations lazily** — GDN ops (1D conv, delta rule, gating) compose from MLX primitives
3. **Text-only MLX conversions** exist (NexVeridian, converted with mlx-lm 0.30.8)

This is the primary motivation for switching the benchmark from mistral.rs to MLX.

### Benchmark tool

The benchmark uses a **native Swift executable** (`FaeBenchmark`) that links directly
against `mlx-swift-lm` — the exact same inference library Fae.app uses. This ensures
benchmark numbers match real-world performance.

```bash
# Build the benchmark (from native/macos/Fae/)
cd native/macos/Fae
swift build --product FaeBenchmark

# Quick single-model test
just bench-model qwen3-8b

# Full sweep (all models)
just bench-all

# Specific model with caching (skips if results exist)
just bench-model qwen3.5-35b-a3b
```

Results are saved as JSON to `scripts/benchmark-results/` with timestamps and
symlinked `_latest.json` for easy access.

### Model Summary

| Model | Idle RAM | Gen T/s (/no_think) | Gen T/s (thinking) | ~500 tok T/s | 8.5K ctx T/s | Backend |
|---|---:|---:|---:|---:|---:|---|
| Qwen3-8B | 4,541 MB | 52.8 | 37.1 | 48.5 | 33.2 | Swift |
| **Qwen3.5-35B-A3B** | **18,804 MB** | **11.7** | **8.0** | **9.6** | **8.0** | **Swift** |
| **Qwen3.5-27B** | **14,899 MB** | **18.3** | **18.4** | **14.1** | **3.3** | Python* |

*Qwen3.5-27B numbers are from Python mlx-lm (wall-time T/s). Swift re-benchmark pending.
Dense model wall-time T/s is comparable to generation T/s at short contexts.

"Gen T/s" = MLX-internal generation speed (excludes prompt prefill time).
"~500 tok T/s" = generation speed at Fae's typical voice context (~500 tokens).
"8.5K ctx T/s" = generation speed at full 8.5K-token context.

**For reference:** Python mlx-lm (same MLX Metal kernels) achieves 85 T/s for
Qwen3.5-35B-A3B and 70 T/s for Qwen3-8B. The Swift gap is 1.3x for dense, 7.3x for MoE.
See "Python vs Swift performance gap" section below for root cause analysis.

### Speed by Context Size — /no_think (Fae production config)

| Context | 8B | **3.5-35B-A3B** | **3.5-27B*** |
|---|---:|---:|---:|
| Short (~20 tok) | 52.8 | **11.7** | **18.3** |
| ~200 tok | 50.2 | **11.0** | **17.3** |
| ~500 tok | 48.5 | **9.6** | **14.1** |
| ~1K tok | 46.2 | **8.9** | **12.2** |
| ~2K tok | 38.7 | **8.5** | **9.3** |
| ~4K tok | 35.7 | **8.2** | **6.1** |
| ~8.5K tok | 33.2 | **8.0** | **3.3** |

### Speed by Context Size — Thinking ON

| Context | 8B | **3.5-35B-A3B** | **3.5-27B*** |
|---|---:|---:|---:|
| Short (~20 tok) | 37.1 | **8.0** | **18.4** |
| ~200 tok | 36.3 | **7.8** | **16.9** |
| ~500 tok | 36.1 | **7.7** | **14.8** |
| ~1K tok | 33.7 | **7.6** | **11.9** |
| ~2K tok | 31.0 | **7.5** | **8.7** |
| ~4K tok | 30.8 | **7.4** | **5.9** |
| ~8.5K tok | 29.9 | **7.3** | **3.3** |

*Qwen3.5-27B from Python mlx-lm. Swift re-benchmark pending.

### Prompt processing speed (T/s)

| Context | 8B | **3.5-35B-A3B** |
|---|---:|---:|
| Short (~20 tok) | 147 | 63 |
| ~200 tok | 307 | 84 |
| ~500 tok | 360 | 81 |
| ~1K tok | 382 | 82 |
| ~2K tok | 390 | 80 |
| ~4K tok | 383 | 80 |
| ~8.5K tok | 365 | 77 |

Qwen3-8B processes prompts 4-5x faster than Qwen3.5-35B-A3B. The MoE model's prompt
processing is slower because all experts must process every prompt token.

### /no_think compliance

| Model | Compliant | Notes |
|---|---|---|
| Qwen3-8B | Yes | Zero thinking tokens in Swift benchmark |
| Qwen3.5-35B-A3B | Yes | Zero thinking tokens — perfect compliance |
| Qwen3.5-27B | Yes | Zero thinking tokens — perfect compliance |

All Qwen3.5 models show perfect /no_think compliance — zero thinking tokens leaked.

### RAM usage

| Model | Idle RAM | Peak RAM (8.5K ctx) | Type |
|---|---:|---:|---|
| Qwen3-8B | 4,541 MB | 4,558 MB | Dense |
| Qwen3.5-35B-A3B | 18,804 MB | 19,163 MB | MoE |
| Qwen3.5-27B | 14,899 MB | 14,929 MB | Hybrid |

RAM usage is very stable across context sizes — MLX's KV cache grows incrementally.
The MoE model uses 4x more RAM than Qwen3-8B despite having fewer active parameters,
because all 35B weights must be loaded even though only 3B are active per token.

### Tool calling

Tool calling was tested using the native `mlx-swift-lm` tool calling API with
OpenAI-format function definitions passed via `UserInput(chat:, tools:)`. The library
injects tool schemas into the chat template and parses `<tool_call>` events from the
generation stream.

| Model | Correct | Total | Accuracy | Native .toolCall events |
|---|---:|---:|---:|---:|
| **Qwen3-8B** | **10** | **10** | **100%** | **8** |
| Qwen3.5-35B-A3B | 2 | 10 | 20% | 0 |
| Qwen3.5-27B | 2 | 10 | 20% | 0 |

**Qwen3-8B has perfect tool calling** — 8/8 correct tool selections on tool-requiring
prompts and 2/2 correct abstentions on conversational prompts. All 8 tool calls were
emitted as native `.toolCall` events via the mlx-swift-lm API.

**Qwen3.5 models use a different tool calling format** — they DO correctly reason about
tools and emit `<tool_call>` tags, but use an **XML parameter format** instead of JSON:

```
# Qwen3 format (mlx-swift-lm parses this natively):
<tool_call>
{"name": "calendar", "arguments": {"action": "list_today"}}
</tool_call>

# Qwen3.5 format (not parsed by mlx-swift-lm):
<tool_call>
<function=calendar>
<parameter=action>list_week</parameter>
</function>
</tool_call>
```

This is how Qwen3.5 was trained by Alibaba — it's a model-level format choice, not a
quantization or conversion issue. Both Python and Swift show the same 20% score (2/10)
because only the 2 "no tool needed" prompts are correct; all 8 tool prompts emit the
right tool in the wrong format.

**Fix:** Fae can add an XML parameter parser alongside the JSON parser in
PipelineCoordinator to support both formats. The tool selection quality is perfect.

### Python vs Swift performance gap (verified)

Both Python `mlx-lm` and Swift `mlx-swift-lm` use the same underlying MLX C++/Metal
framework. Direct comparison using MLX-internal `tokensPerSecond` (excludes prompt prefill):

| Model | Python mlx-lm (internal) | Swift mlx-swift-lm (internal) | Ratio |
|---|---:|---:|---|
| Qwen3-8B (dense) | 70.2 T/s | 52.8 T/s | Python 1.33x faster |
| Qwen3.5-35B-A3B (MoE) | 85.1 T/s | 11.7 T/s | **Python 7.3x faster** |

**Verified:** Python numbers independently confirmed (3 consistent runs at 72 T/s wall-time,
85 T/s MLX-internal) using `mlx-lm v0.30.7` with `NexVeridian/Qwen3.5-35B-A3B-4bit`.

**Root cause: mlx-swift-lm's per-token synchronization amplified by MoE architecture.**

For dense models, the 1.33x gap comes from per-token GPU→CPU sync in Swift's
`TokenIterator.next()` and AsyncStream continuation overhead. For MoE models, this
penalty is amplified 5.5x because each token requires expert routing, multiple expert
MLP evaluations, and result combining — all serialized by the synchronous token extraction.

Key bottlenecks identified in mlx-swift-lm source (Evaluate.swift):
1. **Per-token sync** — `TokenIterator.next()` blocks waiting for integer token return,
   forcing GPU→CPU synchronization 128+ times per generation
2. **No graph caching** — Python uses `mx.stream()` contexts for kernel fusion; Swift doesn't
3. **Lock contention** — every `asyncEval()` acquires `evalLock` (NSRecursiveLock), 128+ times
4. **No prefetch pipelining** — Python schedules next token eval while current extracts;
   Swift processes strictly sequentially

**For dense models**, these overheads add ~33%. **For MoE models**, they compound to ~7x
because MoE routing generates many more intermediate tensors per forward pass.

**The Swift numbers are authoritative** for Fae because they reflect actual production
performance (same library, same code path). The Python numbers show what's theoretically
achievable if mlx-swift-lm optimizes its generation loop.

### Chat-readiness analysis

Fae is a chat companion, not a real-time voice assistant. Even 10 T/s is sufficient for
conversational use — Fae provides audio and visual feedback (thinking tone, orb animation)
while generating. Users see and hear that Fae is working, so perceived latency is low.

| Metric | Qwen3-8B | Qwen3.5-35B-A3B | Qwen3.5-27B |
|---|---:|---:|---:|
| Peak gen T/s (/no_think) | 52.8 | 11.7 | 18.3* |
| ~500 tok gen T/s | 48.5 | 9.6 | 14.1* |
| Idle RAM | 4,541 MB | 18,804 MB | 14,899 MB |
| /no_think compliance | Yes | Yes | Yes |
| Tool calling | 100% | 20% | 20% |

*Python mlx-lm numbers; Swift re-benchmark pending.

All three models are **chat-ready** — the thinking tone and orb animation bridge any
generation delay. Qwen3.5-35B-A3B at ~12 T/s produces ~85ms per token, which is
comfortable for conversational responses with visual feedback.

**Recommendation:**
- **64+ GB:** Qwen3.5-35B-A3B (auto) — best quality, 12 T/s with thinking feedback
- **48-63 GB:** Qwen3-8B (auto) — fast + perfect tool calling
- **32-47 GB:** Qwen3-4B (auto)
- **<32 GB:** Qwen3-1.7B (auto)

### Qwen3.5-27B analysis

The dense 27B model has good quality but higher RAM cost:

- 18 T/s peak — comfortable for chat
- 15 GB RAM — fits on 48+ GB systems
- /no_think compliance is perfect
- High quality responses (subjectively better than Qwen3-8B)

Available as a manual preset. Not auto-selected because Qwen3.5-35B-A3B offers better
quality-per-GB on 64+ GB systems (MoE activates only 3B params per token).

### Key findings

1. **Qwen3.5-35B-A3B is the default for 64+ GB systems** — best quality MoE model at
   12 T/s. Sufficient for chat with audio/visual thinking feedback. Qwen3-8B is the
   default for 48-63 GB (52.8 T/s, 100% tool calling).

2. **Qwen3.5-35B-A3B MoE is slow in mlx-swift-lm** — only 11.7 T/s vs 85 T/s in Python
   mlx-lm (7.3x slower, verified). The MoE expert dispatch path in the Swift library
   has per-token synchronization that compounds with MoE routing overhead. Dense models
   show only 1.33x gap. This model is not suitable for voice use in the Swift stack.

3. **Qwen3.5 has perfect /no_think compliance** — zero thinking token leakage, better
   than Qwen3 which shows 2c wrapper overhead.

4. **MoE RAM overhead is significant** — Qwen3.5-35B-A3B uses 18.8 GB despite only 3B
   active params, because all 35B weights must be resident. Only fits on 64+ GB systems.

5. **Swift benchmark is authoritative** — mlx-swift-lm is Fae's production backend.
   Python mlx-lm numbers are verified real (85 T/s for MoE) but reflect theoretical
   peak with optimal pipelining. The Swift library needs upstream MoE optimization to
   close the 7.3x gap.

6. **Qwen3.5 uses a different tool calling format, not broken** — Qwen3-8B uses JSON
   (`{"name": ..., "arguments": ...}`) which mlx-swift-lm parses natively. Qwen3.5 uses
   XML parameters (`<function=name><parameter=key>value`) — same correct tool selection,
   different serialization. Fae needs an XML parameter parser to support Qwen3.5 tools.

### Model selection (updated with Swift benchmark data)

| System RAM | Recommended Model | Preset | Gen T/s at ~500 tok | Notes |
|---|---|---|---:|---|
| 8-16 GB | Qwen3-0.6B | `qwen3_0_6b` | — | Only option; leaks thinking tokens |
| 16-32 GB | Qwen3-1.7B | `qwen3_1_7b` | — | Best quality at this tier |
| 32-48 GB | Qwen3-4B | `qwen3_4b` | — | Good balance of speed and quality |
| 48-63 GB | Qwen3-8B | `qwen3_8b` | 48.5 | Fast + 100% tool calling |
| 64+ GB | **Qwen3.5-35B-A3B** | `qwen3_5_35b_a3b` | **9.6** | **Best quality (MoE)** |

**Manual presets (not auto-selected):**
- Qwen3.5-27B (`qwen3_5_27b`) — 14.1 T/s at ~500 tok. High quality dense model.
- Qwen3-8B (`qwen3_8b`) — use on 64+ GB if you prefer speed over quality.

**Note:** Qwen3 0.6B/1.7B/4B T/s values pending Swift re-benchmark. Auto-selection tiers
for those models remain based on RAM fit and prior testing.

### Preset reference (FaeConfig.swift)

| Preset | Model ID | Context Size |
|---|---|---:|
| `auto` | RAM-based selection | varies |
| `qwen3_0_6b` | `mlx-community/Qwen3-0.6B-4bit` | 4,096 |
| `qwen3_1_7b` | `mlx-community/Qwen3-1.7B-4bit` | 8,192 |
| `qwen3_4b` | `mlx-community/Qwen3-4B-4bit` | 16,384 |
| `qwen3_8b` | `mlx-community/Qwen3-8B-4bit` | 32,768 |
| `qwen3_5_27b` | `NexVeridian/Qwen3.5-27B-4bit` | 65,536 |
| `qwen3_5_35b_a3b` | `NexVeridian/Qwen3.5-35B-A3B-4bit` | 65,536 |

### Raw JSON results

Benchmark data saved as JSON for reproducibility:
- `scripts/benchmark-results/qwen3-8b_latest.json` — Qwen3-8B (Swift)
- `scripts/benchmark-results/qwen3.5-35b-a3b_latest.json` — Qwen3.5-35B-A3B (Swift)
- `scripts/benchmark-results/qwen3.5-27b_latest.json` — Qwen3.5-27B (Python)
