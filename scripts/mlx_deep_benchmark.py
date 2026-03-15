#!/usr/bin/env python3
"""
MLX Deep Memory & KV Cache Benchmark — Fae Model Evaluation

Measures actual total memory footprint (weights + KV cache) for each model
at each realistic context size, with KV quantization comparisons.

Answers: why does 27B kill the machine? What's the max safe context per model?
Is the auto-selection ladder correct?

Usage:
    # Full sweep (~4h)
    python3 scripts/mlx_deep_benchmark.py --all

    # Quick smoke test (~2 min)
    python3 scripts/mlx_deep_benchmark.py --models qwen3.5-2b --context-sizes 1 4 --kv-bits 4 --skip-accuracy

    # Specific models
    python3 scripts/mlx_deep_benchmark.py --models qwen3.5-2b qwen3.5-9b

    # Memory only (no generation)
    python3 scripts/mlx_deep_benchmark.py --models qwen3.5-27b --memory-only

    # Accuracy only
    python3 scripts/mlx_deep_benchmark.py --models qwen3.5-2b --accuracy-only

    # Custom context sizes and KV bits
    python3 scripts/mlx_deep_benchmark.py --models qwen3.5-9b --kv-bits none 8 4 --context-sizes 4 8 16 32

Prerequisites:
    pip install mlx-lm huggingface_hub psutil
    (mlx-lm depends on mlx which requires Apple Silicon — cannot run via uv isolated venvs)

Model cache:
    Models are downloaded to the standard HuggingFace hub cache at
    ~/.cache/huggingface/hub/ (controlled by HF_HOME env var).
    This is the SAME location Fae's Swift app uses via MLXLMCommon,
    so models downloaded here are shared with the app — no duplicate downloads.
"""

import argparse
import gc
import json
import os
import re
import signal
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
    from mlx_lm import load, stream_generate
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
    "saorsa-1.1-tiny":  "saorsa-labs/saorsa-1.1-tiny",
    "qwen3.5-4b":       "mlx-community/Qwen3.5-4B-4bit",
    "qwen3.5-35b-a3b":  "NexVeridian/Qwen3.5-35B-A3B-4bit",
}

# Historical models (no longer in auto ladder, kept for reference benchmarks)
MODELS_HISTORICAL = {
    "qwen3.5-0.8b":     "mlx-community/Qwen3.5-0.8B-4bit",
    "qwen3.5-2b":       "mlx-community/Qwen3.5-2B-4bit",
    "qwen3.5-9b":       "mlx-community/Qwen3.5-9B-4bit",
    "qwen3.5-27b":      "mlx-community/Qwen3.5-27B-4bit",
}

# Context sizes in K tokens
DEFAULT_CONTEXT_SIZES_K = [1, 2, 4, 8, 16, 32, 128]

# KV quantization options: None = fp16, 8, 4
DEFAULT_KV_BITS = [None, 8, 4]

# Fae's RAM tiers for system load table
RAM_TIERS_GB = [8, 16, 24, 32, 64, 96]

# Estimated headroom for STT + TTS + VLM + system (GB)
ESTIMATED_HEADROOM_GB = 4.0

SCRIPT_DIR = Path(__file__).parent
PROMPTS_PATH = SCRIPT_DIR / "mlx_benchmark_prompts.json"
RESULTS_DIR = SCRIPT_DIR / "benchmark-results"


# ---------------------------------------------------------------------------
# Timeout handling
# ---------------------------------------------------------------------------

class TimeoutError(Exception):
    pass


def timeout_handler(signum, frame):
    raise TimeoutError("Measurement timed out")


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class WeightMemory:
    metal_bytes: int
    rss_mb: float


@dataclass
class ContextMeasurement:
    context_size_k: int
    context_size_tokens: int
    kv_bits: int | None  # None = fp16
    ttft_ms: float
    generation_tps: float
    prompt_tps: float
    kv_cache_delta_bytes: int
    peak_metal_bytes: int
    rss_mb: float
    status: str  # "ok", "oom", "timeout", "skipped_estimated_oom"


@dataclass
class AccuracyResult:
    category: str  # "tool_calling", "no_think", "json", "xml", "yaml", "instruction_following"
    prompt: str
    passed: bool
    detail: str


@dataclass
class ModelResult:
    model_short: str
    model_id: str
    weight_memory: WeightMemory | None = None
    memory_sweep: list = field(default_factory=list)  # list[ContextMeasurement]
    accuracy: list = field(default_factory=list)  # list[AccuracyResult]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_ram_mb() -> float:
    proc = psutil.Process(os.getpid())
    return proc.memory_info().rss / (1024 * 1024)


def bytes_to_gb(b: int) -> float:
    return b / (1024 ** 3)


def bytes_to_mb(b: int) -> float:
    return b / (1024 ** 2)


def format_bytes(b: int) -> str:
    if b >= 1024 ** 3:
        return f"{bytes_to_gb(b):.1f} GB"
    return f"{bytes_to_mb(b):.0f} MB"


def get_model_config(model) -> dict:
    """Extract model architecture config for KV cache estimation.

    Handles Qwen3.5 nested config (model.args.text_config dict) and
    standard HF config layouts.
    """
    cfg = {}

    # Qwen3.5 MLX models: model.args is a ModelArgs with text_config dict
    if hasattr(model, 'args'):
        args = model.args
        if hasattr(args, 'text_config') and isinstance(args.text_config, dict):
            cfg = args.text_config
        elif hasattr(args, '__dict__'):
            cfg = vars(args)

    # Fallback: model.config
    if not cfg and hasattr(model, 'config'):
        c = model.config
        cfg = c if isinstance(c, dict) else vars(c) if hasattr(c, '__dict__') else {}

    config = {}
    config['num_layers'] = cfg.get('num_hidden_layers', cfg.get('n_layer', 32))
    config['num_kv_heads'] = cfg.get('num_key_value_heads', cfg.get('n_head_kv', cfg.get('num_attention_heads', 32)))
    config['head_dim'] = cfg.get('head_dim', cfg.get('hidden_size', 4096) // max(cfg.get('num_attention_heads', 32), 1))

    # Qwen3.5 has mixed attention: only full_attention layers use KV cache
    layer_types = cfg.get('layer_types', [])
    if layer_types:
        config['num_kv_layers'] = sum(1 for t in layer_types if t == 'full_attention')
    else:
        config['num_kv_layers'] = config['num_layers']

    return config


def estimate_kv_bytes(model_config: dict, context_tokens: int, kv_bits: int | None) -> int:
    """Estimate KV cache memory: 2 * kv_layers * kv_heads * head_dim * context * bytes_per_element.

    Uses num_kv_layers (only full_attention layers for Qwen3.5) rather than
    total num_layers.
    """
    layers = model_config.get('num_kv_layers', model_config['num_layers'])
    kv_heads = model_config['num_kv_heads']
    head_dim = model_config['head_dim']

    if kv_bits is None:
        bytes_per_element = 2  # fp16
    elif kv_bits == 8:
        bytes_per_element = 1
    elif kv_bits == 4:
        bytes_per_element = 0.5
    else:
        bytes_per_element = 2

    # 2 for K and V
    return int(2 * layers * kv_heads * head_dim * context_tokens * bytes_per_element)


def get_max_metal_memory() -> int:
    """Get Metal device max recommended working set size."""
    try:
        info = mx.device_info()
        return info.get("max_recommended_working_set_size", info.get("recommendedMaxWorkingSetSize", 0))
    except Exception:
        return 0


def format_chat(tokenizer, system: str, user: str) -> str:
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]
    return tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )


def load_prompts() -> dict:
    with open(PROMPTS_PATH) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Context filler generation
# ---------------------------------------------------------------------------

FILLER_PARAGRAPHS = [
    "The history of artificial intelligence is a fascinating journey through decades of research and development. From early symbolic systems to modern deep learning, the field has evolved dramatically.",
    "Machine learning algorithms have transformed how we process and understand data across many industries. Neural networks inspired by biological systems have become the foundation of modern AI approaches.",
    "Natural language processing enables computers to understand and generate human language with increasing accuracy. Computer vision systems can now identify objects and faces with superhuman performance.",
    "Reinforcement learning has achieved remarkable results in game playing and robotics applications. The ethical implications of AI deployment require careful consideration and governance frameworks.",
    "Transfer learning allows models trained on one task to be adapted for related problems efficiently. Generative models can create realistic images, text, and audio that are increasingly difficult to distinguish.",
    "Edge computing brings machine learning inference closer to data sources, reducing latency and improving privacy. Federated learning enables training across distributed devices without centralizing sensitive data.",
    "Quantum computing promises to accelerate certain machine learning algorithms exponentially. Autonomous vehicles rely on a combination of sensors, ML, and real-time decision making systems.",
    "Healthcare applications include medical image analysis, drug discovery, and personalized treatment planning. Climate modeling and environmental monitoring benefit from advanced ML prediction capabilities.",
    "Robotics and automation continue to evolve with improved perception, planning, and manipulation abilities. The democratization of AI tools has made machine learning accessible to many developers.",
    "Large language models have demonstrated emergent capabilities that were not explicitly programmed. Data privacy regulations impact how ML systems collect, process, and store information.",
]


def build_filler_tokens(tokenizer, target_tokens: int) -> tuple:
    """
    Generate filler text calibrated to produce approximately target_tokens tokens.
    Returns (filler_text, actual_token_count).
    """
    # Calibrate: tokenize a sample to get chars/token ratio
    sample = " ".join(FILLER_PARAGRAPHS[:3])
    sample_tokens = tokenizer.encode(sample)
    chars_per_token = len(sample) / len(sample_tokens) if sample_tokens else 4.0

    # Estimate chars needed
    target_chars = int(target_tokens * chars_per_token * 1.05)  # slight overshoot

    # Build text by repeating paragraphs with numbering for variety
    text = ""
    para_idx = 0
    block_num = 1
    while len(text) < target_chars:
        para = FILLER_PARAGRAPHS[para_idx % len(FILLER_PARAGRAPHS)]
        text += f"[Section {block_num}] {para} "
        para_idx += 1
        block_num += 1

    # Trim to approximate target and verify
    actual_tokens = tokenizer.encode(text)
    while len(actual_tokens) > target_tokens and len(text) > 100:
        # Trim last paragraph
        last_section = text.rfind("[Section ")
        if last_section > 0:
            text = text[:last_section].rstrip()
        else:
            text = text[:int(len(text) * 0.95)]
        actual_tokens = tokenizer.encode(text)

    return text, len(actual_tokens)


# ---------------------------------------------------------------------------
# Measurement functions
# ---------------------------------------------------------------------------

def measure_weight_memory(model) -> WeightMemory:
    """Measure model weight memory after loading."""
    mx.reset_peak_memory()
    mx.eval(model.parameters())
    metal_bytes = mx.get_active_memory()
    rss_mb = get_ram_mb()
    return WeightMemory(metal_bytes=metal_bytes, rss_mb=round(rss_mb, 1))


def measure_context(
    model, tokenizer, context_size_k: int, kv_bits: int | None,
    max_gen_tokens: int, timeout_secs: int, verbose: bool = False,
) -> ContextMeasurement:
    """Measure memory and speed for a given context size and KV quantization."""
    context_tokens = context_size_k * 1024

    # Pre-flight OOM estimate
    model_config = get_model_config(model)
    estimated_kv = estimate_kv_bytes(model_config, context_tokens, kv_bits)
    max_metal = get_max_metal_memory()
    current_metal = mx.get_active_memory()

    if verbose:
        print(f"      Est KV: {format_bytes(estimated_kv)} "
              f"(kv_layers={model_config.get('num_kv_layers', '?')}, "
              f"heads={model_config['num_kv_heads']}, "
              f"dim={model_config['head_dim']})")

    # Pre-flight OOM check: weights + KV + 50% headroom for intermediates
    estimated_total = current_metal + int(estimated_kv * 1.5)
    if max_metal > 0 and estimated_total > int(max_metal * 0.85):
        if verbose:
            print(f"      Skip: {format_bytes(current_metal)} weights + "
                  f"{format_bytes(int(estimated_kv * 1.5))} est > "
                  f"85% of {format_bytes(max_metal)}")
        return ContextMeasurement(
            context_size_k=context_size_k,
            context_size_tokens=context_tokens,
            kv_bits=kv_bits,
            ttft_ms=0, generation_tps=0, prompt_tps=0,
            kv_cache_delta_bytes=estimated_kv,
            peak_metal_bytes=0, rss_mb=0,
            status="skipped_estimated_oom",
        )

    # Build context-filling prompt
    system = "You are a helpful assistant. Be concise. Respond in one sentence."
    # Reserve tokens for system prompt + chat template overhead
    filler_target = max(context_tokens - 200, 100)
    filler_text, actual_filler_tokens = build_filler_tokens(tokenizer, filler_target)
    user_prompt = filler_text + "\n\nGiven everything above, what is the main theme?"

    prompt_text = format_chat(tokenizer, system, user_prompt)
    prompt_tokens = tokenizer.encode(prompt_text)
    actual_prompt_tokens = len(prompt_tokens)

    if verbose:
        print(f"      Prompt: {actual_prompt_tokens} tokens (target: {context_tokens})")

    # Clear caches
    mx.clear_cache()
    gc.collect()

    # Set timeout
    old_handler = signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(timeout_secs)

    try:
        # Record pre-generation metal memory
        pre_metal = mx.get_active_memory()
        mx.reset_peak_memory()

        # Generate using stream_generate for TTFT measurement
        sampler = make_sampler(temp=0.7)

        # Build generate kwargs for KV quantization and prefill chunking
        kv_kwargs = {}
        if kv_bits is not None:
            kv_kwargs["kv_bits"] = kv_bits
            kv_kwargs["kv_group_size"] = 64

        # Chunk prefill for large contexts to avoid Metal command buffer crashes.
        # Default mlx-lm prefill_step_size is 2048; use 512 for 32K+, 256 for 128K+.
        if context_size_k >= 128:
            kv_kwargs["prefill_step_size"] = 256
        elif context_size_k >= 32:
            kv_kwargs["prefill_step_size"] = 512

        prefill_start = time.perf_counter()
        ttft = None
        gen_tokens = 0
        gen_text = ""

        for response in stream_generate(
            model, tokenizer,
            prompt=prompt_text,
            max_tokens=max_gen_tokens,
            sampler=sampler,
            **kv_kwargs,
        ):
            if ttft is None:
                ttft = (time.perf_counter() - prefill_start) * 1000  # ms
            gen_tokens += 1
            gen_text += response.text

        gen_end = time.perf_counter()

        # Measure post-generation metal memory
        # Use peak - pre as the delta (active_memory may not reflect KV cache
        # that stream_generate allocated internally, but peak always captures it)
        post_metal = mx.get_active_memory()
        peak_metal = mx.get_peak_memory()
        kv_delta = max(peak_metal - pre_metal, post_metal - pre_metal)

        # Calculate speeds
        total_time = gen_end - prefill_start
        ttft_val = ttft if ttft is not None else 0
        prefill_time = ttft_val / 1000.0  # seconds

        prompt_tps = actual_prompt_tokens / prefill_time if prefill_time > 0 else 0
        gen_time = total_time - prefill_time
        gen_tps = gen_tokens / gen_time if gen_time > 0 and gen_tokens > 0 else 0

        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)

        return ContextMeasurement(
            context_size_k=context_size_k,
            context_size_tokens=actual_prompt_tokens,
            kv_bits=kv_bits,
            ttft_ms=round(ttft_val, 1),
            generation_tps=round(gen_tps, 1),
            prompt_tps=round(prompt_tps, 1),
            kv_cache_delta_bytes=kv_delta,
            peak_metal_bytes=peak_metal,
            rss_mb=round(get_ram_mb(), 1),
            status="ok",
        )

    except TimeoutError:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)
        return ContextMeasurement(
            context_size_k=context_size_k,
            context_size_tokens=context_tokens,
            kv_bits=kv_bits,
            ttft_ms=0, generation_tps=0, prompt_tps=0,
            kv_cache_delta_bytes=0, peak_metal_bytes=0, rss_mb=0,
            status="timeout",
        )
    except Exception as e:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)
        if verbose:
            print(f"      Error: {e}")
        # Clear cache after error to recover Metal state
        try:
            mx.clear_cache()
            gc.collect()
        except Exception:
            pass
        return ContextMeasurement(
            context_size_k=context_size_k,
            context_size_tokens=context_tokens,
            kv_bits=kv_bits,
            ttft_ms=0, generation_tps=0, prompt_tps=0,
            kv_cache_delta_bytes=0, peak_metal_bytes=0, rss_mb=0,
            status=f"error: {str(e)[:80]}",
        )


# ---------------------------------------------------------------------------
# Accuracy tests
# ---------------------------------------------------------------------------

def run_accuracy_tests(model, tokenizer, verbose: bool = False) -> list:
    """Run accuracy suite: tool calling, no-think, structured output, instruction following."""
    results = []
    prompts_data = load_prompts()
    sampler = make_sampler(temp=0.2)

    def quick_generate(prompt_text: str, max_tokens: int = 256) -> str:
        output = ""
        for response in stream_generate(
            model, tokenizer, prompt=prompt_text,
            max_tokens=max_tokens, sampler=sampler,
            kv_bits=4, kv_group_size=64,
        ):
            output += response.text
        return output

    # 1. Tool calling (10 prompts)
    tool_tests = prompts_data.get("tool_calling", [])
    tool_schemas = prompts_data.get("tool_schemas", "")
    system_tools = f"""You are Fae, a personal AI companion. When a task requires a tool, output a tool call:
<tool_call>{{"name":"tool_name","arguments":{{"key":"value"}}}}</tool_call>
For simple conversation, just respond directly.

Available tools:

{tool_schemas}"""

    for test in tool_tests:
        prompt = test["prompt"]
        expected = test["expected_tool"]
        if verbose:
            print(f"    Tool: {prompt[:50]}...", end="", flush=True)

        prompt_text = format_chat(tokenizer, system_tools, prompt)
        output = quick_generate(prompt_text)

        actual = "none"
        if "<tool_call>" in output:
            match = re.search(r'"name"\s*:\s*"([^"]+)"', output)
            if match:
                actual = match.group(1)

        passed = actual == expected
        if verbose:
            print(f" {'OK' if passed else 'MISS'} (expected={expected}, got={actual})")

        results.append(AccuracyResult(
            category="tool_calling", prompt=prompt,
            passed=passed, detail=f"expected={expected}, got={actual}",
        ))

    # 2. No-think compliance (5 prompts)
    no_think_prompts = prompts_data.get("no_think_test", [])
    system_no_think = "You are a helpful assistant. Be concise."

    for prompt in no_think_prompts:
        if verbose:
            print(f"    No-think: {prompt[:50]}...", end="", flush=True)

        # Generate with thinking suppressed via enable_thinking=false
        prompt_text = format_chat(tokenizer, system_no_think, prompt)
        output = quick_generate(prompt_text)

        think_match = re.findall(r"<think>(.*?)</think>", output, re.DOTALL)
        think_chars = sum(len(t) for t in think_match)
        passed = think_chars <= 10

        if verbose:
            print(f" {'OK' if passed else 'LEAK'} (think_chars={think_chars})")

        results.append(AccuracyResult(
            category="no_think", prompt=prompt,
            passed=passed, detail=f"think_chars={think_chars}",
        ))

    # 3. Structured output (JSON, XML, YAML)
    structured_tests = prompts_data.get("structured_output", [])
    system_struct = "You are a helpful assistant. Follow the output format exactly."

    for test in structured_tests:
        fmt = test["format"]
        prompt = test["prompt"]
        validator = test["validator"]
        if verbose:
            print(f"    {fmt.upper()}: {prompt[:50]}...", end="", flush=True)

        prompt_text = format_chat(tokenizer, system_struct, prompt)
        output = quick_generate(prompt_text, max_tokens=512)

        # Strip thinking tags
        output_clean = re.sub(r"<think>.*?</think>", "", output, flags=re.DOTALL).strip()

        passed = False
        detail = ""

        if validator == "json":
            try:
                # Extract JSON from markdown code blocks if present
                json_match = re.search(r"```(?:json)?\s*\n?(.*?)\n?```", output_clean, re.DOTALL)
                json_str = json_match.group(1) if json_match else output_clean
                parsed = json.loads(json_str)
                passed = isinstance(parsed, (list, dict))
                detail = f"parsed={'list' if isinstance(parsed, list) else 'dict'}"
            except json.JSONDecodeError as e:
                detail = f"json_error: {str(e)[:60]}"

        elif validator == "xml":
            # Check for valid XML-like structure
            has_tags = bool(re.search(r"<\w+>.*</\w+>", output_clean, re.DOTALL))
            passed = has_tags
            detail = f"has_xml_tags={has_tags}"

        elif validator == "yaml":
            # Check for YAML-like key: value pairs
            yaml_lines = [l for l in output_clean.split("\n") if re.match(r"^\s*[\w-]+\s*:", l)]
            passed = len(yaml_lines) >= 2
            detail = f"yaml_lines={len(yaml_lines)}"

        if verbose:
            print(f" {'OK' if passed else 'FAIL'} ({detail})")

        results.append(AccuracyResult(
            category=fmt, prompt=prompt,
            passed=passed, detail=detail,
        ))

    # 4. Instruction following (5 prompts)
    instruction_tests = prompts_data.get("instruction_following", [])
    system_instr = "You are a helpful assistant. Follow instructions precisely."

    for test in instruction_tests:
        prompt = test["prompt"]
        check = test["check"]
        if verbose:
            print(f"    Instruction: {prompt[:50]}...", end="", flush=True)

        prompt_text = format_chat(tokenizer, system_instr, prompt)
        output = quick_generate(prompt_text, max_tokens=128)

        # Strip thinking tags
        output_clean = re.sub(r"<think>.*?</think>", "", output, flags=re.DOTALL).strip()

        passed = False
        detail = ""

        if check == "word_count_3":
            words = output_clean.split()
            passed = len(words) == 3
            detail = f"word_count={len(words)}"

        elif check == "line_count_5":
            lines = [l.strip() for l in output_clean.strip().split("\n") if l.strip()]
            passed = len(lines) == 5
            detail = f"line_count={len(lines)}"

        elif check == "yes_or_no":
            lower = output_clean.lower().strip().rstrip(".")
            passed = lower in ("yes", "no")
            detail = f"response='{output_clean[:30]}'"

        elif check == "all_caps":
            # Check if alphabetic characters are mostly caps
            alpha = [c for c in output_clean if c.isalpha()]
            if alpha:
                caps_ratio = sum(1 for c in alpha if c.isupper()) / len(alpha)
                passed = caps_ratio > 0.8
                detail = f"caps_ratio={caps_ratio:.0%}"
            else:
                detail = "no_alpha_chars"

        elif check == "single_emoji":
            # Simple emoji check: single character response or very short
            clean = output_clean.strip()
            # Emoji detection: check if response is very short and contains non-ASCII
            passed = len(clean) <= 4 and any(ord(c) > 127 for c in clean)
            detail = f"response='{clean[:10]}' len={len(clean)}"

        if verbose:
            print(f" {'OK' if passed else 'FAIL'} ({detail})")

        results.append(AccuracyResult(
            category="instruction_following", prompt=prompt,
            passed=passed, detail=detail,
        ))

    return results


# ---------------------------------------------------------------------------
# Markdown output
# ---------------------------------------------------------------------------

def results_to_markdown(all_results: list, hardware_info: dict) -> str:
    lines = []
    lines.append("## Deep Memory & KV Cache Benchmark")
    lines.append("")
    lines.append(f"**Hardware:** {hardware_info.get('arch', 'Apple Silicon')}, {hardware_info.get('ram_gb', '?')} GB unified memory")
    lines.append(f"**Max Metal memory:** {format_bytes(hardware_info.get('max_metal', 0))}")
    lines.append("**Quantization:** 4-bit weights (MLX community)")
    lines.append("**Backend:** mlx-lm (Python API)")
    lines.append(f"**Date:** {time.strftime('%Y-%m-%d')}")
    lines.append("")

    # Table 1: Memory Profile (weight + KV at each context with 4-bit KV)
    lines.append("### 1. Memory Profile — Weights + KV Cache (4-bit KV)")
    lines.append("")

    # Collect all context sizes measured
    all_ctx = sorted(set(
        m.context_size_k
        for r in all_results
        for m in r.memory_sweep
        if m.kv_bits == 4
    ))

    if all_ctx:
        header = "| Model | Weights |"
        sep = "|---|---:|"
        for k in all_ctx:
            header += f" +{k}K KV |"
            sep += "---:|"
        lines.append(header)
        lines.append(sep)

        for r in all_results:
            weight_str = format_bytes(r.weight_memory.metal_bytes) if r.weight_memory else "?"
            row = f"| {r.model_short} | {weight_str} |"
            for k in all_ctx:
                m = next((x for x in r.memory_sweep if x.context_size_k == k and x.kv_bits == 4), None)
                if m is None:
                    row += " - |"
                elif m.status != "ok":
                    row += f" {m.status} |"
                else:
                    row += f" {format_bytes(m.kv_cache_delta_bytes)} |"
            lines.append(row)
        lines.append("")

    # Table 2: TTFT by Context Size
    lines.append("### 2. Time to First Token (ms) — 4-bit KV")
    lines.append("")

    if all_ctx:
        header = "| Model |"
        sep = "|---|"
        for k in all_ctx:
            header += f" {k}K |"
            sep += "---:|"
        lines.append(header)
        lines.append(sep)

        for r in all_results:
            row = f"| {r.model_short} |"
            for k in all_ctx:
                m = next((x for x in r.memory_sweep if x.context_size_k == k and x.kv_bits == 4), None)
                if m and m.status == "ok":
                    row += f" {m.ttft_ms:.0f} |"
                elif m:
                    row += f" {m.status} |"
                else:
                    row += " - |"
            lines.append(row)
        lines.append("")

    # Table 3: Generation Speed
    lines.append("### 3. Generation Speed (T/s) — 4-bit KV")
    lines.append("")

    if all_ctx:
        header = "| Model |"
        sep = "|---|"
        for k in all_ctx:
            header += f" {k}K |"
            sep += "---:|"
        lines.append(header)
        lines.append(sep)

        for r in all_results:
            row = f"| {r.model_short} |"
            for k in all_ctx:
                m = next((x for x in r.memory_sweep if x.context_size_k == k and x.kv_bits == 4), None)
                if m and m.status == "ok":
                    row += f" {m.generation_tps:.1f} |"
                elif m:
                    row += f" {m.status} |"
                else:
                    row += " - |"
            lines.append(row)
        lines.append("")

    # Table 4: KV Quantization Impact
    lines.append("### 4. KV Quantization Impact (at 8K context)")
    lines.append("")
    lines.append("| Model | KV=fp16 mem | KV=8 mem | KV=4 mem | KV=fp16 T/s | KV=8 T/s | KV=4 T/s |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")

    for r in all_results:
        row = f"| {r.model_short} |"
        for kv in [None, 8, 4]:
            m = next((x for x in r.memory_sweep if x.context_size_k == 8 and x.kv_bits == kv), None)
            if m and m.status == "ok":
                row += f" {format_bytes(m.kv_cache_delta_bytes)} |"
            elif m:
                row += f" {m.status} |"
            else:
                row += " - |"
        for kv in [None, 8, 4]:
            m = next((x for x in r.memory_sweep if x.context_size_k == 8 and x.kv_bits == kv), None)
            if m and m.status == "ok":
                row += f" {m.generation_tps:.1f} |"
            elif m:
                row += f" {m.status} |"
            else:
                row += " - |"
        lines.append(row)
    lines.append("")

    # Table 5: Accuracy Summary
    has_accuracy = any(r.accuracy for r in all_results)
    if has_accuracy:
        lines.append("### 5. Accuracy Summary")
        lines.append("")
        categories = ["tool_calling", "no_think", "json", "xml", "yaml", "instruction_following"]
        header = "| Model |"
        sep = "|---|"
        for cat in categories:
            header += f" {cat} |"
            sep += "---:|"
        lines.append(header)
        lines.append(sep)

        for r in all_results:
            row = f"| {r.model_short} |"
            for cat in categories:
                cat_results = [a for a in r.accuracy if a.category == cat]
                if cat_results:
                    passed = sum(1 for a in cat_results if a.passed)
                    total = len(cat_results)
                    pct = (passed / total * 100) if total > 0 else 0
                    row += f" {passed}/{total} ({pct:.0f}%) |"
                else:
                    row += " - |"
            lines.append(row)
        lines.append("")

    # Table 6: Total System Load vs RAM tiers
    lines.append("### 6. Total System Load vs RAM Tiers (4-bit KV)")
    lines.append("")
    lines.append("Shows weights + KV cache at Fae's default context size + headroom for STT/TTS/VLM.")
    lines.append(f"Headroom estimate: {ESTIMATED_HEADROOM_GB:.0f} GB (STT + TTS + VLM + system)")
    lines.append("")

    # Fae's default context per model (from auto ladder)
    fae_contexts = {
        "qwen3.5-2b": 32,
        "qwen3.5-4b": 32,
        "qwen3.5-35b-a3b": 128,  # 131072 on 64+ GB, 32768 on 32-63 GB
        # Historical models (kept for reference)
        "saorsa-1.1-tiny": 32,
        "qwen3.5-0.8b": 32,
        "qwen3.5-9b": 32,
        "qwen3.5-27b": 32,
    }

    header = "| Model | Fae ctx | Weights | KV cache | Total | +Headroom |"
    sep = "|---|---:|---:|---:|---:|---:|"
    for gb in RAM_TIERS_GB:
        header += f" {gb}GB? |"
        sep += "---|"
    lines.append(header)
    lines.append(sep)

    for r in all_results:
        ctx_k = fae_contexts.get(r.model_short, 32)
        weight_bytes = r.weight_memory.metal_bytes if r.weight_memory else 0

        m = next((x for x in r.memory_sweep if x.context_size_k == ctx_k and x.kv_bits == 4), None)
        if m is None:
            # Try closest available
            m = next((x for x in r.memory_sweep if x.kv_bits == 4 and x.status == "ok"), None)
            if m:
                ctx_k = m.context_size_k

        if m and m.status == "ok":
            kv_bytes = m.kv_cache_delta_bytes
        else:
            # Use estimate
            model_config_est = {'num_layers': 32, 'num_kv_heads': 8, 'head_dim': 128}
            kv_bytes = estimate_kv_bytes(model_config_est, ctx_k * 1024, 4)

        total_bytes = weight_bytes + kv_bytes
        with_headroom_gb = bytes_to_gb(total_bytes) + ESTIMATED_HEADROOM_GB

        row = f"| {r.model_short} | {ctx_k}K | {format_bytes(weight_bytes)} | {format_bytes(kv_bytes)} | {bytes_to_gb(total_bytes):.1f} GB | {with_headroom_gb:.1f} GB |"

        for gb in RAM_TIERS_GB:
            fits = with_headroom_gb <= gb * 0.85  # 85% threshold
            row += f" {'YES' if fits else 'NO'} |"

        lines.append(row)
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main benchmark
# ---------------------------------------------------------------------------

def benchmark_model(
    model_id: str, short_name: str,
    context_sizes_k: list, kv_bits_list: list,
    max_gen_tokens: int, timeout_secs: int,
    memory_only: bool = False, accuracy_only: bool = False,
    skip_accuracy: bool = False, verbose: bool = False,
    resume_data: dict | None = None,
) -> ModelResult:
    """Run deep benchmark for a single model."""
    print(f"\n{'=' * 70}")
    print(f"  Loading {short_name} ({model_id})")
    print(f"{'=' * 70}")

    model, tokenizer = load(model_id)
    result = ModelResult(model_short=short_name, model_id=model_id)

    # Check for resumed data
    if resume_data:
        if resume_data.get("weight_memory"):
            wm = resume_data["weight_memory"]
            result.weight_memory = WeightMemory(**wm)
        if resume_data.get("memory_sweep"):
            result.memory_sweep = [ContextMeasurement(**m) for m in resume_data["memory_sweep"]]
        if resume_data.get("accuracy"):
            result.accuracy = [AccuracyResult(**a) for a in resume_data["accuracy"]]

    # A. Weight memory
    if not result.weight_memory:
        print("\n  Measuring weight memory...")
        result.weight_memory = measure_weight_memory(model)
        print(f"    Metal: {format_bytes(result.weight_memory.metal_bytes)}")
        print(f"    RSS:   {result.weight_memory.rss_mb:.0f} MB")

    if accuracy_only:
        # Skip memory sweep, just run accuracy
        pass
    elif not memory_only:
        # B. Context sweep
        print(f"\n  Context sweep: {context_sizes_k} K x KV bits {kv_bits_list}")

        # Warmup
        print("  Warming up...")
        warmup_prompt = format_chat(tokenizer, "You are a helpful assistant.", "Hello")
        warmup_sampler = make_sampler(temp=0.7)
        for response in stream_generate(model, tokenizer, prompt=warmup_prompt, max_tokens=16, sampler=warmup_sampler):
            pass

        # Track OOM per kv_bits to enable progressive skip
        oom_at = {}  # kv_bits -> min context that OOMed

        for kv in kv_bits_list:
            kv_label = f"fp16" if kv is None else f"{kv}-bit"
            print(f"\n  KV={kv_label}:")

            for ctx_k in context_sizes_k:
                # Check resume - skip if already measured
                existing = next(
                    (m for m in result.memory_sweep if m.context_size_k == ctx_k and m.kv_bits == kv),
                    None,
                )
                if existing:
                    print(f"    {ctx_k}K: (resumed) {existing.status}")
                    continue

                # Progressive skip
                if kv in oom_at and ctx_k >= oom_at[kv]:
                    m = ContextMeasurement(
                        context_size_k=ctx_k, context_size_tokens=ctx_k * 1024,
                        kv_bits=kv, ttft_ms=0, generation_tps=0, prompt_tps=0,
                        kv_cache_delta_bytes=0, peak_metal_bytes=0, rss_mb=0,
                        status="skipped_progressive",
                    )
                    result.memory_sweep.append(m)
                    print(f"    {ctx_k}K: skipped (progressive)")
                    continue

                print(f"    {ctx_k}K...", end="", flush=True)
                m = measure_context(
                    model, tokenizer, ctx_k, kv,
                    max_gen_tokens, timeout_secs, verbose,
                )
                result.memory_sweep.append(m)

                if m.status == "ok":
                    print(f" KV={format_bytes(m.kv_cache_delta_bytes)}, "
                          f"TTFT={m.ttft_ms:.0f}ms, "
                          f"Gen={m.generation_tps:.1f} T/s, "
                          f"Prompt={m.prompt_tps:.0f} T/s")
                else:
                    print(f" {m.status}")
                    if m.status in ("oom", "timeout", "skipped_estimated_oom"):
                        oom_at[kv] = ctx_k

                # Clear between measurements
                mx.clear_cache()
                gc.collect()

    # C. Accuracy
    if not memory_only and not skip_accuracy and not result.accuracy:
        print("\n  Accuracy tests:")
        result.accuracy = run_accuracy_tests(model, tokenizer, verbose)

        # Print summary
        categories = set(a.category for a in result.accuracy)
        for cat in sorted(categories):
            cat_results = [a for a in result.accuracy if a.category == cat]
            passed = sum(1 for a in cat_results if a.passed)
            total = len(cat_results)
            print(f"    {cat}: {passed}/{total} ({passed/total*100:.0f}%)")

    # Cleanup
    del model
    del tokenizer
    mx.clear_cache()
    gc.collect()

    return result


def save_results(all_results: list, hardware_info: dict, output_path: str):
    """Save results to JSON."""
    data = {
        "metadata": {
            "benchmark": "mlx_deep_benchmark",
            "date": time.strftime("%Y-%m-%d %H:%M:%S"),
            "hardware": hardware_info,
        },
        "models": {},
    }

    for r in all_results:
        model_data = {
            "model_id": r.model_id,
            "weight_memory": asdict(r.weight_memory) if r.weight_memory else None,
            "memory_sweep": [asdict(m) for m in r.memory_sweep],
            "accuracy": [asdict(a) for a in r.accuracy],
        }
        data["models"][r.model_short] = model_data

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"\nJSON saved: {output_path}")


def load_resume_data(resume_path: str) -> dict:
    """Load previous results for resuming."""
    with open(resume_path) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="MLX Deep Memory & KV Cache Benchmark for Fae",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"Available models: {', '.join(MODELS.keys())}",
    )
    parser.add_argument("--all", action="store_true", help="Benchmark all 7 models")
    parser.add_argument("--models", nargs="+", metavar="M",
                        help=f"Model short names: {', '.join(MODELS.keys())}")
    parser.add_argument("--context-sizes", nargs="+", type=int, metavar="K",
                        help=f"Context sizes in K tokens (default: {DEFAULT_CONTEXT_SIZES_K})")
    parser.add_argument("--kv-bits", nargs="+", metavar="B",
                        help="KV quantization bits: none 8 4 (default: none 8 4)")
    parser.add_argument("--memory-only", action="store_true",
                        help="Only measure weight + KV memory, skip accuracy")
    parser.add_argument("--accuracy-only", action="store_true",
                        help="Only run accuracy tests")
    parser.add_argument("--skip-accuracy", action="store_true",
                        help="Skip accuracy tests")
    parser.add_argument("--max-gen-tokens", type=int, default=64,
                        help="Max tokens to generate per measurement (default: 64)")
    parser.add_argument("--timeout", type=int, default=120,
                        help="Timeout per measurement in seconds (default: 120)")
    parser.add_argument("--output", type=str, default=None,
                        help="Output JSON path (default: scripts/benchmark-results/deep_bench_DATE.json)")
    parser.add_argument("--markdown", type=str, default=None,
                        help="Output markdown path (prints to stdout if not specified)")
    parser.add_argument("--resume", type=str, default=None,
                        help="Resume from previous JSON results file")
    parser.add_argument("--verbose", action="store_true", help="Verbose output")

    args = parser.parse_args()

    # Parse KV bits
    if args.kv_bits:
        kv_bits_list = []
        for b in args.kv_bits:
            if b.lower() == "none":
                kv_bits_list.append(None)
            else:
                kv_bits_list.append(int(b))
    else:
        kv_bits_list = DEFAULT_KV_BITS

    context_sizes_k = args.context_sizes or DEFAULT_CONTEXT_SIZES_K

    # Determine models
    if args.all:
        model_list = list(MODELS.items())
    elif args.models:
        model_list = []
        for name in args.models:
            if name in MODELS:
                model_list.append((name, MODELS[name]))
            else:
                print(f"Unknown model: {name}. Available: {', '.join(MODELS.keys())}")
                sys.exit(1)
    else:
        parser.print_help()
        print(f"\nAvailable models: {', '.join(MODELS.keys())}")
        sys.exit(1)

    # Load resume data
    resume_data = {}
    if args.resume:
        full_resume = load_resume_data(args.resume)
        resume_data = full_resume.get("models", {})
        print(f"Resuming from: {args.resume}")

    # Hardware info
    max_metal = get_max_metal_memory()
    hardware_info = {
        "arch": os.uname().machine,
        "ram_gb": psutil.virtual_memory().total // (1024 ** 3),
        "max_metal": max_metal,
    }

    print(f"MLX Deep Benchmark — {len(model_list)} model(s)")
    print(f"Hardware: {hardware_info['arch']}, {hardware_info['ram_gb']} GB RAM")
    print(f"Max Metal memory: {format_bytes(max_metal)}")
    print(f"Context sizes: {context_sizes_k} K")
    print(f"KV bits: {kv_bits_list}")
    print(f"Model cache: {HF_CACHE_DIR}")

    # Run benchmarks
    all_results = []
    for short_name, model_id in model_list:
        try:
            model_resume = resume_data.get(short_name, None)
            result = benchmark_model(
                model_id, short_name,
                context_sizes_k, kv_bits_list,
                args.max_gen_tokens, args.timeout,
                memory_only=args.memory_only,
                accuracy_only=args.accuracy_only,
                skip_accuracy=args.skip_accuracy,
                verbose=args.verbose,
                resume_data=model_resume,
            )
            all_results.append(result)
        except Exception as e:
            print(f"\n  ERROR benchmarking {short_name}: {e}")
            import traceback
            traceback.print_exc()

    if not all_results:
        print("\nNo benchmarks completed.")
        sys.exit(1)

    # Save JSON
    date_str = time.strftime("%Y%m%d-%H%M%S")
    output_path = args.output or str(RESULTS_DIR / f"deep_bench_{date_str}.json")
    save_results(all_results, hardware_info, output_path)

    # Generate markdown
    md = results_to_markdown(all_results, hardware_info)
    if args.markdown:
        with open(args.markdown, "w") as f:
            f.write(md)
        print(f"Markdown saved: {args.markdown}")
    else:
        print("\n" + "=" * 70)
        print("MARKDOWN OUTPUT")
        print("=" * 70)
        print(md)


if __name__ == "__main__":
    main()
