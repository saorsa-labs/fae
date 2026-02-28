#!/usr/bin/env python3
"""
MLX LLM Benchmark — Fae Model Evaluation

Benchmarks Qwen3 and Qwen3.5 models on Apple Silicon via mlx-lm.
Replaces the mistral.rs-based eval with native MLX inference.

Usage:
    # Single model quick test
    python scripts/mlx_benchmark.py --model mlx-community/Qwen3-1.7B-4bit

    # Full sweep (all models)
    python scripts/mlx_benchmark.py --all

    # Specific dimensions
    python scripts/mlx_benchmark.py --model mlx-community/Qwen3-8B-4bit --throughput --ram --tools

Prerequisites:
    pip install mlx-lm huggingface_hub psutil

Model cache:
    Models are downloaded to the standard HuggingFace hub cache at
    ~/.cache/huggingface/hub/ (controlled by HF_HOME env var).
    This is the SAME location Fae's Swift app uses via MLXLMCommon,
    so models downloaded here are shared with the app — no duplicate downloads.
"""

import argparse
import json
import os
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

try:
    import psutil
except ImportError:
    print("ERROR: psutil required. Install with: pip install psutil", file=sys.stderr)
    sys.exit(1)

try:
    import mlx.core as mx
    from mlx_lm import generate, load
    from mlx_lm.sample_utils import make_sampler
except ImportError:
    print("ERROR: mlx-lm required. Install with: pip install mlx-lm", file=sys.stderr)
    sys.exit(1)

try:
    from huggingface_hub import constants as hf_constants
    HF_CACHE_DIR = hf_constants.HF_HUB_CACHE
except Exception:
    HF_CACHE_DIR = os.path.expanduser("~/.cache/huggingface/hub")


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

MODELS = {
    "qwen3-0.6b": "mlx-community/Qwen3-0.6B-4bit",
    "qwen3-1.7b": "mlx-community/Qwen3-1.7B-4bit",
    "qwen3-4b": "mlx-community/Qwen3-4B-4bit",
    "qwen3-8b": "mlx-community/Qwen3-8B-4bit",
    # NexVeridian's text-only conversion (mlx-lm 0.30.8) — vision tower stripped.
    # The mlx-community versions are VL (vision-language) and won't load in mlx-lm.
    "qwen3.5-35b-a3b": "NexVeridian/Qwen3.5-35B-A3B-4bit",
    "qwen3.5-27b": "NexVeridian/Qwen3.5-27B-4bit",
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).parent
PROMPTS_PATH = SCRIPT_DIR / "mlx_benchmark_prompts.json"


def load_prompts() -> dict:
    """Load test prompts from companion JSON file."""
    with open(PROMPTS_PATH) as f:
        return json.load(f)


def build_filler_text(target_words: int) -> str:
    """Generate filler text of approximately `target_words` words."""
    sentences = [
        "The history of artificial intelligence is a fascinating journey through decades of research and development.",
        "Machine learning algorithms have transformed how we process and understand data across many industries.",
        "Neural networks inspired by biological systems have become the foundation of modern deep learning approaches.",
        "Natural language processing enables computers to understand and generate human language with increasing accuracy.",
        "Computer vision systems can now identify objects and faces with superhuman performance in many benchmarks.",
        "Reinforcement learning has achieved remarkable results in game playing and robotics applications worldwide.",
        "The ethical implications of artificial intelligence deployment require careful consideration and governance frameworks.",
        "Transfer learning allows models trained on one task to be adapted efficiently for related problems and domains.",
        "Generative models can create realistic images text and audio that are increasingly difficult to distinguish from human work.",
        "Edge computing brings machine learning inference closer to data sources reducing latency and improving privacy.",
        "Federated learning enables training models across distributed devices without centralizing sensitive personal data.",
        "Quantum computing promises to accelerate certain machine learning algorithms exponentially in the coming decades.",
        "Autonomous vehicles rely on a combination of sensors machine learning and real time decision making systems.",
        "Healthcare applications of AI include medical image analysis drug discovery and personalized treatment planning.",
        "Climate modeling and environmental monitoring benefit from advanced machine learning prediction capabilities.",
        "Robotics and automation continue to evolve with improved perception planning and manipulation abilities.",
        "The democratization of AI tools has made machine learning accessible to developers without specialized training.",
        "Large language models have demonstrated emergent capabilities that were not explicitly programmed or expected.",
        "Data privacy regulations like GDPR impact how machine learning systems collect process and store information.",
        "The computational costs of training large models raise questions about environmental sustainability and access.",
    ]
    text = ""
    idx = 0
    while len(text.split()) < target_words:
        text += sentences[idx % len(sentences)] + " "
        idx += 1
    return text.strip()


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------


@dataclass
class ThroughputResult:
    context_label: str
    prompt_tokens: int
    generated_tokens: int
    visible_chars: int
    thinking_chars: int
    wall_time_s: float
    tokens_per_second: float
    ram_mb: float


@dataclass
class NoThinkResult:
    prompt: str
    think_on_tokens: int
    think_on_time_s: float
    think_off_tokens: int
    think_off_time_s: float
    overhead_tokens: str
    overhead_time: str
    compliant: bool


@dataclass
class ToolCallResult:
    prompt: str
    expected_tool: str
    actual_tool: str
    correct: bool
    temperature: float


@dataclass
class ModelBenchmark:
    model_id: str
    model_short: str
    idle_ram_mb: float = 0.0
    throughput_no_think: list = field(default_factory=list)
    throughput_think_on: list = field(default_factory=list)
    no_think_compliance: list = field(default_factory=list)
    tool_calling: list = field(default_factory=list)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def get_ram_mb() -> float:
    """Return current process RSS in MB."""
    proc = psutil.Process(os.getpid())
    return proc.memory_info().rss / (1024 * 1024)


def format_chat(tokenizer, system: str, user: str) -> str:
    """Apply chat template to produce a prompt string."""
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]
    return tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )


def timed_generate(
    model, tokenizer, prompt_text: str, max_tokens: int = 256, temperature: float = 0.7
) -> tuple:
    """
    Generate text and return (output_text, num_tokens, wall_time_s, prompt_token_count).

    Uses mlx_lm.generate which handles tokenization internally.
    """
    # Tokenize the prompt to count tokens
    prompt_tokens = tokenizer.encode(prompt_text)
    prompt_token_count = len(prompt_tokens)

    sampler = make_sampler(temp=temperature)

    start = time.perf_counter()
    output = generate(
        model,
        tokenizer,
        prompt=prompt_text,
        max_tokens=max_tokens,
        sampler=sampler,
        verbose=False,
    )
    elapsed = time.perf_counter() - start

    # Count output tokens
    output_tokens = tokenizer.encode(output)
    num_tokens = len(output_tokens)

    return output, num_tokens, elapsed, prompt_token_count


def count_thinking_chars(text: str) -> tuple:
    """
    Split output into visible and thinking chars.
    Qwen3 thinking is wrapped in <think>...</think> tags.
    Returns (visible_chars, thinking_chars).
    """
    import re

    think_pattern = re.compile(r"<think>(.*?)</think>", re.DOTALL)
    thinking_parts = think_pattern.findall(text)
    thinking_chars = sum(len(p) for p in thinking_parts)
    visible = think_pattern.sub("", text).strip()
    return len(visible), thinking_chars


# ---------------------------------------------------------------------------
# Benchmark dimensions
# ---------------------------------------------------------------------------


def measure_throughput(
    model,
    tokenizer,
    system_prompt: str,
    user_prompt: str,
    max_tokens: int,
    label: str,
    temperature: float = 0.7,
    runs: int = 2,
) -> ThroughputResult:
    """Measure throughput (T/s) for a given prompt. Takes best of N runs."""
    prompt_text = format_chat(tokenizer, system_prompt, user_prompt)

    best_tps = 0.0
    best_result = None

    for _ in range(runs):
        output, num_tokens, elapsed, prompt_count = timed_generate(
            model, tokenizer, prompt_text, max_tokens=max_tokens, temperature=temperature
        )
        if num_tokens > 0 and elapsed > 0:
            tps = num_tokens / elapsed
        else:
            tps = 0.0

        if tps > best_tps:
            best_tps = tps
            visible, thinking = count_thinking_chars(output)
            ram = get_ram_mb()
            best_result = ThroughputResult(
                context_label=label,
                prompt_tokens=prompt_count,
                generated_tokens=num_tokens,
                visible_chars=visible,
                thinking_chars=thinking,
                wall_time_s=round(elapsed, 2),
                tokens_per_second=round(tps, 1),
                ram_mb=round(ram, 0),
            )

    return best_result


def run_context_sweep(
    model, tokenizer, think_mode: str = "no_think"
) -> list:
    """
    Run throughput benchmark at 7 context sizes.
    think_mode: "no_think" or "think_on"
    """
    if think_mode == "no_think":
        system = "/no_think\n\nYou are a helpful assistant. Be concise."
    else:
        system = "You are a helpful assistant. Be concise."

    filler = build_filler_text(6500)
    words = filler.split()

    tests = [
        ("Short (~20 tok)", "What is the weather like today?", 128),
        ("~200 tok ctx", " ".join(words[:150]) + " Summarize.", 256),
        ("~500 tok ctx", " ".join(words[:350]) + " Summarize.", 256),
        ("~1K tok ctx", " ".join(words[:750]) + " Summarize.", 256),
        ("~2K tok ctx", " ".join(words[:1500]) + " Summarize.", 256),
        ("~4K tok ctx", " ".join(words[:3000]) + " Summarize.", 256),
        ("~8.5K tok", filler + " Given all of this context, what are the three most important developments?", 256),
    ]

    results = []
    for label, user_prompt, max_tok in tests:
        print(f"    {label}...", end="", flush=True)
        result = measure_throughput(
            model, tokenizer, system, user_prompt, max_tok, label
        )
        if result:
            print(f" {result.tokens_per_second} T/s, {result.ram_mb:.0f} MB")
            results.append(result)
        else:
            print(" FAILED")

    return results


def run_no_think_test(model, tokenizer) -> list:
    """Test /no_think compliance — compare thinking ON vs OFF."""
    prompts_data = load_prompts()
    test_prompts = prompts_data.get("no_think_test", [
        "What is the capital of France?",
        "Explain quantum computing in one sentence.",
        "What is 17 * 23?",
    ])

    system_on = "You are a helpful assistant. Be concise."
    system_off = "/no_think\n\nYou are a helpful assistant. Be concise."

    results = []
    for user_prompt in test_prompts:
        print(f"    Testing: {user_prompt[:50]}...", flush=True)

        # Thinking ON
        prompt_on = format_chat(tokenizer, system_on, user_prompt)
        out_on, tok_on, time_on, _ = timed_generate(
            model, tokenizer, prompt_on, max_tokens=256
        )
        _, think_chars_on = count_thinking_chars(out_on)

        # Thinking OFF
        prompt_off = format_chat(tokenizer, system_off, user_prompt)
        out_off, tok_off, time_off, _ = timed_generate(
            model, tokenizer, prompt_off, max_tokens=256
        )
        _, think_chars_off = count_thinking_chars(out_off)

        tok_overhead = f"{tok_on / max(tok_off, 1):.0f}x" if tok_off > 0 else "N/A"
        time_overhead = f"{time_on / max(time_off, 0.001):.0f}x" if time_off > 0.001 else "N/A"

        results.append(NoThinkResult(
            prompt=user_prompt,
            think_on_tokens=tok_on,
            think_on_time_s=round(time_on, 2),
            think_off_tokens=tok_off,
            think_off_time_s=round(time_off, 2),
            overhead_tokens=tok_overhead,
            overhead_time=time_overhead,
            compliant=think_chars_off <= 10,  # <=10 chars = negligible leakage
        ))

    return results


def run_tool_calling_test(model, tokenizer, temperature: float = 0.2) -> list:
    """Test tool calling accuracy with tool schemas in the prompt."""
    prompts_data = load_prompts()
    tool_tests = prompts_data.get("tool_calling", [])

    if not tool_tests:
        print("    No tool calling prompts found in prompts file, skipping.")
        return []

    tool_schemas = prompts_data.get("tool_schemas", "")

    system = f"""/no_think

You are Fae, a personal AI companion running on macOS. When the user's request requires a tool, \
call the appropriate tool. For simple conversation, just respond directly without tools.

Tool usage:
- When a task requires a tool, output a tool call in this exact format:
  <tool_call>{{"name":"tool_name","arguments":{{"key":"value"}}}}</tool_call>
- Wait for the tool result before continuing
- After receiving a tool result, respond naturally in spoken language
- Only use tools when the user's request genuinely needs one
- For simple conversation, just respond directly without tools
- Keep your spoken responses concise (1-4 sentences)
- NEVER expose raw tool call markup or JSON to the user

Available tools:

{tool_schemas}"""

    results = []
    for test in tool_tests:
        user_prompt = test["prompt"]
        expected = test["expected_tool"]

        print(f"    Tool test: {user_prompt[:50]}...", end="", flush=True)

        prompt_text = format_chat(tokenizer, system, user_prompt)
        output, _, _, _ = timed_generate(
            model, tokenizer, prompt_text, max_tokens=256, temperature=temperature
        )

        # Check if the expected tool was called
        actual = "none"
        if "<tool_call>" in output:
            # Extract tool name from the output
            import re
            match = re.search(r'"name"\s*:\s*"([^"]+)"', output)
            if match:
                actual = match.group(1)

        correct = actual == expected
        print(f" {'OK' if correct else 'MISS'} (expected={expected}, got={actual})")

        results.append(ToolCallResult(
            prompt=user_prompt,
            expected_tool=expected,
            actual_tool=actual,
            correct=correct,
            temperature=temperature,
        ))

    return results


def run_ram_measurement(model, tokenizer) -> float:
    """Measure idle RAM after model load (before any inference)."""
    mx.eval(model.parameters())
    return get_ram_mb()


# ---------------------------------------------------------------------------
# Markdown output
# ---------------------------------------------------------------------------


def results_to_markdown(benchmarks: list) -> str:
    """Convert benchmark results to markdown tables."""
    lines = []
    lines.append("## MLX Benchmark Results (Feb 2026)")
    lines.append("")
    lines.append("**Hardware:** Apple Silicon, 96 GB unified memory")
    lines.append("**Quantization:** 4-bit (MLX community)")
    lines.append("**Backend:** mlx-lm (Python API, no server)")
    lines.append(f"**Date:** {time.strftime('%Y-%m-%d')}")
    lines.append("")

    # Model summary table
    lines.append("### Model Summary")
    lines.append("")
    lines.append("| Model | Idle RAM | Peak T/s (raw) | Peak T/s (/no_think) | 8.5K ctx T/s |")
    lines.append("|---|---:|---:|---:|---:|")

    for b in benchmarks:
        peak_raw = max((r.tokens_per_second for r in b.throughput_think_on), default=0)
        peak_no_think = max((r.tokens_per_second for r in b.throughput_no_think), default=0)
        ctx_8k = next(
            (r.tokens_per_second for r in b.throughput_no_think if "8.5K" in r.context_label),
            0,
        )
        lines.append(
            f"| {b.model_short} | {b.idle_ram_mb:.0f} MB | {peak_raw:.0f} | {peak_no_think:.0f} | {ctx_8k:.0f} |"
        )

    lines.append("")

    # /no_think throughput table
    lines.append("### Speed by Context Size — /no_think (Fae production config)")
    lines.append("")
    headers = ["Context"] + [b.model_short for b in benchmarks]
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("|" + "|".join(["---"] + ["---:"] * len(benchmarks)) + "|")

    # Collect all context labels
    all_labels = []
    for b in benchmarks:
        for r in b.throughput_no_think:
            if r.context_label not in all_labels:
                all_labels.append(r.context_label)

    for label in all_labels:
        row = [label]
        for b in benchmarks:
            val = next(
                (r.tokens_per_second for r in b.throughput_no_think if r.context_label == label),
                None,
            )
            row.append(f"{val:.0f}" if val else "-")
        lines.append("| " + " | ".join(row) + " |")

    lines.append("")

    # Raw throughput table
    lines.append("### Speed by Context Size — Raw Throughput (thinking ON)")
    lines.append("")
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("|" + "|".join(["---"] + ["---:"] * len(benchmarks)) + "|")

    for label in all_labels:
        row = [label]
        for b in benchmarks:
            val = next(
                (r.tokens_per_second for r in b.throughput_think_on if r.context_label == label),
                None,
            )
            row.append(f"{val:.0f}" if val else "-")
        lines.append("| " + " | ".join(row) + " |")

    lines.append("")

    # Detailed /no_think results
    lines.append("### Full /no_think results (all models, all context sizes)")
    lines.append("")
    lines.append("| Model | Context | Prompt Tok | Gen Tok | Visible | Think | Wall Time | Gen T/s | RSS RAM |")
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|")

    for b in benchmarks:
        first = True
        for r in b.throughput_no_think:
            name = f"**{b.model_short}**" if first else ""
            first = False
            lines.append(
                f"| {name} | {r.context_label} | {r.prompt_tokens} | {r.generated_tokens} | "
                f"{r.visible_chars}c | {r.thinking_chars}c | {r.wall_time_s:.2f}s | "
                f"**{r.tokens_per_second:.1f}** | {r.ram_mb:.0f} MB |"
            )

    lines.append("")

    # /no_think compliance
    has_compliance = any(b.no_think_compliance for b in benchmarks)
    if has_compliance:
        lines.append("### /no_think compliance by model")
        lines.append("")
        lines.append("| Model | Compliant | Notes |")
        lines.append("|---|---|---|")
        for b in benchmarks:
            if b.no_think_compliance:
                all_ok = all(r.compliant for r in b.no_think_compliance)
                status = "Yes" if all_ok else "Leaks thinking tokens"
                lines.append(f"| {b.model_short} | {status} | |")
        lines.append("")

    # Tool calling
    has_tools = any(b.tool_calling for b in benchmarks)
    if has_tools:
        lines.append("### Tool calling accuracy")
        lines.append("")
        lines.append("| Model | Correct | Total | Accuracy |")
        lines.append("|---|---:|---:|---:|")
        for b in benchmarks:
            if b.tool_calling:
                correct = sum(1 for r in b.tool_calling if r.correct)
                total = len(b.tool_calling)
                pct = (correct / total * 100) if total > 0 else 0
                lines.append(f"| {b.model_short} | {correct} | {total} | {pct:.0f}% |")
        lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def benchmark_model(
    model_id: str,
    short_name: str,
    do_throughput: bool = True,
    do_no_think: bool = True,
    do_ram: bool = True,
    do_tools: bool = True,
) -> ModelBenchmark:
    """Run all requested benchmarks for a single model."""
    print(f"\n{'=' * 70}")
    print(f"  Loading {short_name} ({model_id})")
    print(f"{'=' * 70}")

    model, tokenizer = load(model_id)

    bench = ModelBenchmark(model_id=model_id, model_short=short_name)

    # RAM measurement
    if do_ram:
        print("\n  Measuring idle RAM...")
        bench.idle_ram_mb = round(run_ram_measurement(model, tokenizer), 0)
        print(f"    Idle RAM: {bench.idle_ram_mb:.0f} MB")

    # Warmup
    print("\n  Warming up (3 throwaway generations)...")
    warmup_prompt = format_chat(
        tokenizer,
        "/no_think\n\nYou are a helpful assistant.",
        "Hello",
    )
    warmup_sampler = make_sampler(temp=0.7)
    for _ in range(3):
        generate(model, tokenizer, prompt=warmup_prompt, max_tokens=16, sampler=warmup_sampler, verbose=False)

    # Throughput — /no_think
    if do_throughput:
        print("\n  Throughput (/no_think):")
        bench.throughput_no_think = run_context_sweep(model, tokenizer, "no_think")

        print("\n  Throughput (thinking ON):")
        bench.throughput_think_on = run_context_sweep(model, tokenizer, "think_on")

    # /no_think compliance
    if do_no_think:
        print("\n  /no_think compliance:")
        bench.no_think_compliance = run_no_think_test(model, tokenizer)

    # Tool calling
    if do_tools:
        print("\n  Tool calling (temp=0.2):")
        bench.tool_calling = run_tool_calling_test(model, tokenizer, temperature=0.2)

    # Cleanup
    del model
    del tokenizer
    mx.clear_cache()

    return bench


def main():
    parser = argparse.ArgumentParser(description="MLX LLM Benchmark for Fae")
    parser.add_argument(
        "--model",
        type=str,
        help="HuggingFace model ID (e.g., mlx-community/Qwen3-1.7B-4bit)",
    )
    parser.add_argument(
        "--all", action="store_true", help="Benchmark all models in the sweep"
    )
    parser.add_argument(
        "--qwen3-only",
        action="store_true",
        help="Benchmark only Qwen3 models (skip Qwen3.5)",
    )
    parser.add_argument(
        "--qwen35-only",
        action="store_true",
        help="Benchmark only Qwen3.5 models",
    )
    parser.add_argument(
        "--throughput",
        action="store_true",
        default=False,
        help="Run throughput benchmark",
    )
    parser.add_argument(
        "--no-think", action="store_true", default=False, help="Run /no_think test"
    )
    parser.add_argument(
        "--ram", action="store_true", default=False, help="Run RAM measurement"
    )
    parser.add_argument(
        "--tools", action="store_true", default=False, help="Run tool calling test"
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="Output JSON file path (default: scripts/mlx_benchmark_results.json)",
    )
    parser.add_argument(
        "--markdown",
        type=str,
        default=None,
        help="Output markdown file path (prints to stdout if not specified)",
    )

    args = parser.parse_args()

    # If no specific dimensions selected, run all
    run_all_dims = not any([args.throughput, args.no_think, args.ram, args.tools])
    do_throughput = args.throughput or run_all_dims
    do_no_think = args.no_think or run_all_dims
    do_ram = args.ram or run_all_dims
    do_tools = args.tools or run_all_dims

    # Determine which models to run
    if args.model:
        # Single model specified by hub ID
        short = next(
            (k for k, v in MODELS.items() if v == args.model),
            args.model.split("/")[-1],
        )
        model_list = [(args.model, short)]
    elif args.all:
        model_list = [(v, k) for k, v in MODELS.items()]
    elif args.qwen3_only:
        model_list = [
            (v, k) for k, v in MODELS.items() if not k.startswith("qwen3.5")
        ]
    elif args.qwen35_only:
        model_list = [(v, k) for k, v in MODELS.items() if k.startswith("qwen3.5")]
    else:
        parser.print_help()
        print("\nSpecify --model <id>, --all, --qwen3-only, or --qwen35-only")
        sys.exit(1)

    print(f"MLX LLM Benchmark — {len(model_list)} model(s)")
    print(f"Hardware: {os.uname().machine}, {psutil.virtual_memory().total // (1024**3)} GB RAM")
    print(f"Model cache: {HF_CACHE_DIR}")
    print(f"  (Same as Fae.app — models are shared, no duplicate downloads)")
    print(f"Dimensions: throughput={do_throughput}, no_think={do_no_think}, ram={do_ram}, tools={do_tools}")

    benchmarks = []
    for model_id, short_name in model_list:
        try:
            bench = benchmark_model(
                model_id,
                short_name,
                do_throughput=do_throughput,
                do_no_think=do_no_think,
                do_ram=do_ram,
                do_tools=do_tools,
            )
            benchmarks.append(bench)
        except Exception as e:
            print(f"\n  ERROR benchmarking {short_name}: {e}")
            import traceback
            traceback.print_exc()

    if not benchmarks:
        print("\nNo benchmarks completed.")
        sys.exit(1)

    # Output JSON
    output_path = args.output or str(SCRIPT_DIR / "mlx_benchmark_results.json")
    results_dict = {
        "hardware": {
            "arch": os.uname().machine,
            "ram_gb": psutil.virtual_memory().total // (1024**3),
        },
        "date": time.strftime("%Y-%m-%d"),
        "backend": "mlx-lm",
        "models": [],
    }

    for b in benchmarks:
        model_dict = {
            "model_id": b.model_id,
            "model_short": b.model_short,
            "idle_ram_mb": b.idle_ram_mb,
            "throughput_no_think": [asdict(r) for r in b.throughput_no_think],
            "throughput_think_on": [asdict(r) for r in b.throughput_think_on],
            "no_think_compliance": [asdict(r) for r in b.no_think_compliance],
            "tool_calling": [asdict(r) for r in b.tool_calling],
        }
        results_dict["models"].append(model_dict)

    with open(output_path, "w") as f:
        json.dump(results_dict, f, indent=2)
    print(f"\nJSON results saved to: {output_path}")

    # Output markdown
    md = results_to_markdown(benchmarks)
    if args.markdown:
        with open(args.markdown, "w") as f:
            f.write(md)
        print(f"Markdown results saved to: {args.markdown}")
    else:
        print("\n" + "=" * 70)
        print("MARKDOWN OUTPUT")
        print("=" * 70)
        print(md)


if __name__ == "__main__":
    main()
