#!/usr/bin/env python3
"""
FaeBenchmark — Qwen3.6 Production Evals via mlx-vlm
====================================================
Qwen3.6-35B-A3B is an image-text-to-text model (VLM architecture) released
2026-04-15. Same activation profile as Qwen3.5-35B-A3B (3B active) but with
new hybrid architecture: Gated DeltaNet + Gated Attention + MoE. mlx-swift-lm
does NOT yet support this architecture, so we use mlx-vlm (Python) for eval.

Usage:
    uv run --no-project --with 'mlx-vlm>=0.4.4' python3 scripts/benchmark_qwen36.py --model qwen3.6-35b-a3b-4bit
    uv run --no-project --with 'mlx-vlm>=0.4.4' python3 scripts/benchmark_qwen36.py --all
"""

import argparse
import json
import os
import platform
import re
import sys
import time
from datetime import datetime
from pathlib import Path

# Reuse eval data + helpers from the Gemma 4 benchmark (same test suite).
sys.path.insert(0, str(Path(__file__).parent))
from benchmark_gemma4 import (  # noqa: E402
    MCQ_SYSTEM,
    MMLU_MINI,
    FAE_CAPABILITY,
    ASSISTANT_FIT,
    SERIALIZATION_CASES,
    SERIALIZATION_SYSTEM,
    TOOL_SCHEMAS,
    TOOL_CALL_TESTS,
    TOOL_SYSTEM_PROMPT,
    extract_choice_letter,
    parse_structured_fields,
    normalize_fields,
)

# Model registry — mlx-community quants uploaded 2026-04-16.
MODELS = {
    "qwen3.6-35b-a3b-4bit": "mlx-community/Qwen3.6-35B-A3B-4bit",
    "qwen3.6-35b-a3b-5bit": "mlx-community/Qwen3.6-35B-A3B-5bit",
    "qwen3.6-35b-a3b-6bit": "mlx-community/Qwen3.6-35B-A3B-6bit",
    "qwen3.6-35b-a3b-8bit": "mlx-community/Qwen3.6-35B-A3B-8bit",
    "qwen3.6-35b-a3b-bf16": "mlx-community/Qwen3.6-35B-A3B-bf16",
    "qwen3.6-35b-a3b-mxfp4": "mlx-community/Qwen3.6-35B-A3B-mxfp4",
    "qwen3.6-35b-a3b-mxfp8": "mlx-community/Qwen3.6-35B-A3B-mxfp8",
    "qwen3.6-35b-a3b-nvfp4": "mlx-community/Qwen3.6-35B-A3B-nvfp4",
    "qwen3.6-35b-a3b-msq": "mlx-community/Qwen3.6-35B-A3B-4.4bit-msq",
}

TIER_MODELS = {
    "tier-32gb": "mlx-community/Qwen3.6-35B-A3B-4bit",
}


def extract_tool_name_qwen(text: str) -> tuple[str, str]:
    """Handle Qwen3.x tool-call formats.

    Qwen3.6 uses the qwen3_coder format:
        <tool_call>
        <function=calendar>
        <parameter=action>list_today</parameter>
        </function>
        </tool_call>

    Qwen3/3.5 used the JSON format:
        <tool_call>{"name": "calendar", "arguments": {...}}</tool_call>
    """
    # qwen3_coder format (Qwen3.6)
    m = re.search(r'<function\s*=\s*(\w+)\s*>', text)
    if m:
        return m.group(1), "qwen3_coder"
    # Qwen3/3.5 JSON format
    m = re.search(r'<tool_call>\s*\{.*?"name"\s*:\s*"([^"]+)"', text, re.DOTALL)
    if m:
        return m.group(1), "qwen_tool_call"
    # Bare JSON name field
    m = re.search(r'"name"\s*:\s*"([^"]+)"', text)
    if m:
        return m.group(1), "json_name_field"
    # Python-style fallback (rare)
    m = re.search(r'```(?:python|tool_code)\s*\w*\.?(\w+)\(', text)
    if m:
        return m.group(1), "python_tool_call"
    return "none", "none"


class QwenBenchmark:
    def __init__(self, model_id: str, short_name: str):
        self.model_id = model_id
        self.short_name = short_name
        self.model = None
        self.processor = None
        self.tokenizer = None

    def load(self):
        # Transformers 5.2 / mlx-vlm 0.4.4 crash on Qwen3.6's processor config
        # because `video_processor_class_from_name` gets None for its extractors
        # lookup. For text-only eval the video processor is unused, so we patch
        # the lookup to return None safely before invoking vlm_load.
        from transformers.models.auto import video_processing_auto
        _orig = video_processing_auto.video_processor_class_from_name
        def _safe_lookup(class_name):
            try:
                return _orig(class_name)
            except TypeError:
                return None
        video_processing_auto.video_processor_class_from_name = _safe_lookup

        from mlx_vlm import load as vlm_load
        print(f"  Loading {self.short_name} ({self.model_id})...")
        try:
            self.model, self.processor = vlm_load(self.model_id)
            self.tokenizer = self.processor.tokenizer
        except Exception as exc:
            # Fallback: load tokenizer + model weights directly, bypassing
            # AutoProcessor entirely. Text-only eval path.
            print(f"  vlm_load failed ({type(exc).__name__}): {exc}")
            print("  Falling back to manual tokenizer + model load...")
            from transformers import AutoTokenizer
            from mlx_vlm.utils import load_model, get_model_path
            model_path = get_model_path(self.model_id)
            self.tokenizer = AutoTokenizer.from_pretrained(model_path)
            self.model, _ = load_model(model_path, lazy=False)
            self.processor = None
        print("  Loaded.")

    def _build_prompt(self, system: str, user: str, tools: list | None = None) -> str:
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": user})
        kwargs = {"tokenize": False, "add_generation_prompt": True}
        if tools:
            kwargs["tools"] = tools
        # Qwen3.6: disable thinking by default to match Fae's /no_think paths.
        # The new chat template reads this from additional kwargs.
        kwargs["enable_thinking"] = False
        try:
            return self.tokenizer.apply_chat_template(messages, **kwargs)
        except TypeError:
            # Older tokenizers reject enable_thinking — retry without it.
            kwargs.pop("enable_thinking", None)
            return self.tokenizer.apply_chat_template(messages, **kwargs)

    def generate(self, system: str, user: str, max_tokens: int = 256,
                 temperature: float = 0.0, tools: list | None = None) -> dict:
        from mlx_vlm import generate as vlm_generate
        prompt = self._build_prompt(system, user, tools=tools)
        start = time.time()
        output = vlm_generate(
            self.model,
            self.processor,
            prompt,
            max_tokens=max_tokens,
            temperature=temperature if temperature > 0 else 0.0,
            verbose=False,
        )
        elapsed = time.time() - start
        if isinstance(output, str):
            text = output
        elif hasattr(output, "text"):
            text = output.text
        else:
            text = str(output)
        return {"text": text, "wall_time": elapsed}

    def run_mcq_eval(self, questions, label):
        results = []
        for cat, prompt, answer in questions:
            print(f"    {label} [{cat}]: {prompt[:42].replace(chr(10), ' ')}...", end="", flush=True)
            result = self.generate(MCQ_SYSTEM, prompt, max_tokens=16)
            actual = extract_choice_letter(result["text"])
            correct = actual == answer
            print(f" {'OK' if correct else 'MISS'} expected={answer} got={actual}")
            results.append({
                "category": cat, "prompt": prompt,
                "expected_answer": answer, "actual_answer": actual,
                "correct": correct, "wall_time_s": round(result["wall_time"], 2),
            })
        return results

    def run_tool_calling(self):
        results = []
        for prompt, expected in TOOL_CALL_TESTS:
            print(f"    Tool test: {prompt[:50]}...", end="", flush=True)
            result = self.generate(
                TOOL_SYSTEM_PROMPT, prompt, max_tokens=512, tools=TOOL_SCHEMAS,
            )
            actual, source = extract_tool_name_qwen(result["text"])
            correct = actual == expected
            print(f" {'OK' if correct else 'MISS'} expected={expected} got={actual} ({source})")
            results.append({
                "prompt": prompt, "expected_tool": expected,
                "actual_tool": actual, "tool_call_source": source,
                "raw_response_preview": result["text"][:300].replace("\n", "\\n"),
                "correct": correct, "wall_time_s": round(result["wall_time"], 2),
            })
        return results

    def run_serialization_eval(self):
        results = []
        for fmt, task, prompt, expected_fields in SERIALIZATION_CASES:
            print(f"    Ser [{fmt}]: {task}...", end="", flush=True)
            result = self.generate(SERIALIZATION_SYSTEM, prompt, max_tokens=128)
            actual = parse_structured_fields(result["text"], fmt)
            norm_actual = normalize_fields(actual)
            norm_expected = normalize_fields(expected_fields)
            valid = len(norm_actual) > 0
            correct = norm_actual == norm_expected
            print(f" {'OK' if correct else 'MISS'} valid={'yes' if valid else 'no'}")
            results.append({
                "format": fmt, "task": task, "prompt": prompt,
                "expected_fields": expected_fields, "actual_fields": actual,
                "raw_output": result["text"], "valid": valid, "correct": correct,
                "wall_time_s": round(result["wall_time"], 2),
            })
        return results

    def run_throughput(self):
        results = []
        system = "You are a helpful assistant. Be concise."
        prompts = [
            ("Short (~20 tok)", "What is the weather like today?", 128),
            ("~200 tok ctx",
             " ".join(["The history of artificial intelligence is a fascinating journey."] * 15) + " Summarize.",
             256),
        ]
        for label, user, max_tok in prompts:
            print(f"    {label}...", end="", flush=True)
            result = self.generate(system, user, max_tokens=max_tok, temperature=0.7)
            text = result["text"]
            word_count = len(text.split())
            est_tokens = int(word_count * 1.33)
            est_tps = est_tokens / max(result["wall_time"], 0.01)
            print(f" ~{est_tps:.1f} T/s (est), {result['wall_time']:.1f}s wall, {word_count} words")
            results.append({
                "context_label": label,
                "estimated_tokens": est_tokens,
                "wall_time_s": round(result["wall_time"], 2),
                "estimated_tps": round(est_tps, 1),
                "word_count": word_count,
            })
        return results

    def run_full(self):
        print(f"\n{'='*60}\n  MODEL: {self.short_name}\n  ID:    {self.model_id}\n{'='*60}")
        self.load()

        print("\n  [1/6] Throughput...")
        throughput = self.run_throughput()

        print("\n  [2/6] Tool Calling...")
        tool_calling = self.run_tool_calling()
        tc_correct = sum(1 for r in tool_calling if r["correct"])
        tc_total = len(tool_calling)

        print("\n  [3/6] MMLU-mini...")
        intelligence = self.run_mcq_eval(MMLU_MINI, "MMLU-mini")
        int_correct = sum(1 for r in intelligence if r["correct"])
        int_total = len(intelligence)

        print("\n  [4/6] Fae Capability...")
        fae_cap = self.run_mcq_eval(FAE_CAPABILITY, "Fae-cap")
        cap_correct = sum(1 for r in fae_cap if r["correct"])
        cap_total = len(fae_cap)

        print("\n  [5/6] Assistant Fit...")
        assistant_fit = self.run_mcq_eval(ASSISTANT_FIT, "Assistant-fit")
        af_correct = sum(1 for r in assistant_fit if r["correct"])
        af_total = len(assistant_fit)

        print("\n  [6/6] Serialization...")
        serialization = self.run_serialization_eval()
        ser_correct = sum(1 for r in serialization if r["correct"])
        ser_total = len(serialization)

        print(f"\n{'='*60}\n  SUMMARY: {self.short_name}")
        print(f"  Tool Calling:    {tc_correct}/{tc_total} ({tc_correct/tc_total*100:.0f}%)")
        print(f"  MMLU-mini:       {int_correct}/{int_total} ({int_correct/int_total*100:.0f}%)")
        print(f"  Fae Capability:  {cap_correct}/{cap_total} ({cap_correct/cap_total*100:.0f}%)")
        print(f"  Assistant Fit:   {af_correct}/{af_total} ({af_correct/af_total*100:.0f}%)")
        print(f"  Serialization:   {ser_correct}/{ser_total} ({ser_correct/ser_total*100:.0f}%)")
        print(f"{'='*60}")

        return {
            "model_id": self.model_id,
            "model_short": self.short_name,
            "backend": "mlx-vlm",
            "throughput": throughput,
            "tool_calling": tool_calling,
            "intelligence_eval": intelligence,
            "fae_capability_eval": fae_cap,
            "assistant_fit_eval": assistant_fit,
            "serialization_eval": serialization,
            "summary": {
                "tool_calling": f"{tc_correct}/{tc_total}",
                "intelligence": f"{int_correct}/{int_total}",
                "fae_capability": f"{cap_correct}/{cap_total}",
                "assistant_fit": f"{af_correct}/{af_total}",
                "serialization": f"{ser_correct}/{ser_total}",
            },
        }


def main():
    parser = argparse.ArgumentParser(description="FaeBenchmark — Qwen3.6 via mlx-vlm")
    parser.add_argument("--model", type=str, help="Model short name or HuggingFace ID")
    parser.add_argument("--all", action="store_true", help="Run all Qwen3.6 quants")
    parser.add_argument("--tiers", action="store_true", help="Run production tier only (4bit)")
    parser.add_argument("--output", type=str, help="Output JSON path")
    args = parser.parse_args()

    if not args.model and not args.all and not args.tiers:
        parser.print_help()
        print("\nAvailable models:")
        for name, hf_id in MODELS.items():
            print(f"  {name:30s} {hf_id}")
        return

    if args.tiers:
        models_to_run = list(TIER_MODELS.items())
    elif args.all:
        models_to_run = list(MODELS.items())
    else:
        key = args.model
        if key in MODELS:
            models_to_run = [(key, MODELS[key])]
        elif key in TIER_MODELS:
            models_to_run = [(key, TIER_MODELS[key])]
        else:
            short = key.split("/")[-1].lower()
            models_to_run = [(short, key)]

    results_dir = Path(__file__).parent / "benchmark-results"
    results_dir.mkdir(exist_ok=True)

    all_results = []
    for short_name, model_id in models_to_run:
        bench = QwenBenchmark(model_id, short_name)
        result = bench.run_full()
        all_results.append(result)

        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        out_path = results_dir / f"{short_name}_{timestamp}.json"
        output = {
            "hardware": {
                "arch": platform.machine(),
                "ram_gb": int(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / (1024**3)),
            },
            "date": datetime.now().isoformat(),
            "backend": "mlx-vlm",
            "models": [result],
        }
        with open(out_path, "w") as f:
            json.dump(output, f, indent=2)
        latest = results_dir / f"{short_name}_latest.json"
        if latest.is_symlink() or latest.exists():
            latest.unlink()
        latest.symlink_to(out_path.name)
        print(f"\n  Results saved: {out_path}")

    if args.output:
        output = {
            "hardware": {
                "arch": platform.machine(),
                "ram_gb": int(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / (1024**3)),
            },
            "date": datetime.now().isoformat(),
            "backend": "mlx-vlm",
            "models": all_results,
        }
        with open(args.output, "w") as f:
            json.dump(output, f, indent=2)
        print(f"\nAll results saved: {args.output}")


if __name__ == "__main__":
    main()
