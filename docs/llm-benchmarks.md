# LLM Benchmarks — Local Inference on Apple Silicon

Benchmark results for Qwen3 models running locally via mistral.rs with Metal acceleration.
These numbers directly inform Fae's model selection, context budget, and dual-channel
pipeline architecture.

**Hardware:** Apple Silicon, 96 GB unified memory
**Quantization:** Q4_K_M (GGUF)
**Backend:** mistral.rs 0.7 with Metal GPU offload
**Date:** 2026-02-23

---

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

### Models tested but incompatible with mistral.rs 0.7 + Metal

| Model | Architecture | GGUF Size | Error | Notes |
|---|---|---:|---|---|
| Phi-4-mini-instruct (3.8B) | phi3 | 2.5 GB | `Cannot find tensor info for output.weight` | Tied embeddings not handled by mistral.rs Phi3 GGUF loader |
| Qwen3-30B-A3B MoE (3B active) | qwen3moe | 18.6 GB | `indexed_moe_forward is not implemented` | MoE kernel only exists for CUDA, not Metal |
| Liquid LFM2 (all variants) | lfm2 | varies | Architecture not supported | Hybrid SSM — not in mistral.rs GGUF arch list |

**mistral.rs 0.7 supported GGUF architectures:** Llama, Mistral3, Phi2, Phi3, Starcoder2,
Qwen2, Qwen3, Qwen3MoE (MoE requires CUDA).

On Apple Silicon, only dense transformer models work. MoE models need NVIDIA GPUs.
Check [mistral.rs releases](https://github.com/EricLBuehler/mistral.rs/releases) for
future Metal MoE and Phi-4 tied-embedding support.
