#!/usr/bin/env python3
"""
External A/B benchmark for Qwen3.5-9B quantizations.

This compares the current standard MLX 4-bit checkpoint against the ParoQuant
4-bit checkpoint using the same prompt corpus taken from Fae's stored targeted
benchmark artifact. It intentionally stays outside the app runtime so we can
measure the quantization delta before deciding whether ParoQuant support belongs
in Fae itself.
"""

from __future__ import annotations

import argparse
import asyncio
import gc
import json
import re
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CORPUS = PROJECT_ROOT / "scripts" / "benchmark-results" / "qwen3.5-9b_20260313-172928.json"
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "scripts" / "benchmark-results"

QWEN_CALIBRATED_MCQ_SYSTEM_PROMPT = """
/no_think
You are Qwen running in benchmark mode.
Return only the final choice, wrapped exactly as <answer>X</answer> where X is A, B, C, or D.
Do not include analysis, reasoning, "Thinking Process", bullets, or any text before or after the answer tag.
If you are unsure, still return exactly one choice in the answer tag.

Valid examples:
<answer>B</answer>
<answer>D</answer>

Invalid examples:
Thinking Process: ...
The answer is B
B
""".strip()

QWEN_CALIBRATED_SERIALIZATION_SYSTEM_PROMPT = """
/no_think
You are Qwen running in benchmark mode.
Return only the requested payload.
Do not include analysis, reasoning, "Thinking Process", markdown fences, labels, or any text before the payload.
If JSON is requested, the very first character must be {.
If XML is requested, the very first character must be < and the root must be <record>.
If YAML is requested, the very first line must start with the first key.

Valid examples:
{"name":"Ada","city":"London"}
<record><name>Ada</name><city>London</city></record>
name: Ada
city: London

Invalid examples:
Thinking Process: ...
Here is the JSON:
```json
{"name":"Ada"}
```
""".strip()

MCQ_PATTERNS = [
    re.compile(r"(?im)^\s*(?:answer|final answer|correct answer)?\s*[:=-]?\s*([ABCD])\s*$"),
    re.compile(r"(?im)\b(?:answer|final answer|correct answer)\s*[:=-]?\s*([ABCD])\b"),
    re.compile(r"(?im)<answer>\s*([ABCD])\s*</answer>"),
    re.compile(r"(?im)\b([ABCD])\b"),
]

THINK_RE = re.compile(r"<think>(.*?)</think>", re.DOTALL)


@dataclass
class GenerationMetrics:
    output_text: str
    prompt_tokens: int
    generation_tokens: int
    wall_time_s: float
    first_token_latency_ms: float
    tokens_per_second: float
    prompt_tokens_per_second: float


class BaseRunner:
    name: str
    model_id: str

    async def load(self) -> None:
        raise NotImplementedError

    async def close(self) -> None:
        raise NotImplementedError

    async def generate_chat(
        self,
        system: str,
        user: str,
        *,
        max_tokens: int,
        temperature: float,
        enable_thinking: bool,
    ) -> GenerationMetrics:
        raise NotImplementedError


class StandardMLXRunner(BaseRunner):
    def __init__(self, model_id: str, adapter_path: str | None = None, label: str = "standard_mlx_4bit") -> None:
        self.name = label
        self.model_id = model_id
        self.adapter_path = adapter_path
        self.model = None
        self.tokenizer = None

    async def load(self) -> None:
        from mlx_lm import load

        self.model, self.tokenizer = load(self.model_id, adapter_path=self.adapter_path)

    async def close(self) -> None:
        if self.model is not None:
            import mlx.core as mx

            self.model = None
            self.tokenizer = None
            gc.collect()
            mx.clear_cache()

    async def generate_chat(
        self,
        system: str,
        user: str,
        *,
        max_tokens: int,
        temperature: float,
        enable_thinking: bool,
    ) -> GenerationMetrics:
        import mlx.core as mx
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler

        if self.model is None or self.tokenizer is None:
            raise RuntimeError("Runner not loaded")

        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ]
        try:
            prompt = self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=enable_thinking,
            )
        except TypeError:
            prompt = self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
            )

        sampler = make_sampler(temp=temperature)

        start = time.perf_counter()
        first_token_time: float | None = None
        chunks: list[str] = []
        last_response = None

        for response in stream_generate(
            self.model,
            self.tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=sampler,
        ):
            last_response = response
            if response.text:
                if first_token_time is None:
                    first_token_time = time.perf_counter()
                chunks.append(response.text)

        end = time.perf_counter()
        output_text = "".join(chunks)
        prompt_tokens = len(self.tokenizer.encode(prompt))
        generation_tokens = len(self.tokenizer.encode(output_text))
        prompt_tps = 0.0
        generation_tps = 0.0

        if last_response is not None:
            prompt_tokens = int(last_response.prompt_tokens or prompt_tokens)
            generation_tokens = int(last_response.generation_tokens or generation_tokens)
            prompt_tps = float(last_response.prompt_tps or 0.0)
            generation_tps = float(last_response.generation_tps or 0.0)

        if generation_tps <= 0 and generation_tokens > 0:
            gen_start = first_token_time if first_token_time is not None else start
            generation_tps = generation_tokens / max(end - gen_start, 1e-6)

        first_token_latency_ms = (
            (first_token_time - start) * 1000 if first_token_time is not None else (end - start) * 1000
        )

        mx.clear_cache()

        return GenerationMetrics(
            output_text=output_text,
            prompt_tokens=prompt_tokens,
            generation_tokens=generation_tokens,
            wall_time_s=end - start,
            first_token_latency_ms=first_token_latency_ms,
            tokens_per_second=generation_tps,
            prompt_tokens_per_second=prompt_tps,
        )


class ParoQuantRunner(BaseRunner):
    def __init__(self, model_id: str, label: str = "paroquant_4bit") -> None:
        self.name = label
        self.model_id = model_id
        self.generator = None

    async def load(self) -> None:
        from paroquant.inference import create_generator

        self.generator = create_generator("mlx", self.model_id)

    async def close(self) -> None:
        if self.generator is not None:
            import mlx.core as mx

            await self.generator.close()
            self.generator = None
            gc.collect()
            mx.clear_cache()

    async def generate_chat(
        self,
        system: str,
        user: str,
        *,
        max_tokens: int,
        temperature: float,
        enable_thinking: bool,
    ) -> GenerationMetrics:
        from paroquant.inference import GenerationParams, build_prompt

        if self.generator is None:
            raise RuntimeError("Runner not loaded")

        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ]
        prompt = build_prompt(self.generator.tokenizer, messages, enable_thinking)
        params = GenerationParams(max_tokens=max_tokens, temperature=temperature, top_p=1.0, top_k=0)
        result = await self.generator.generate(prompt, params)

        try:
            prompt_tokens = len(self.generator.tokenizer.encode(prompt, add_special_tokens=False))
        except TypeError:
            prompt_tokens = len(self.generator.tokenizer.encode(prompt))

        return GenerationMetrics(
            output_text=result.output_text,
            prompt_tokens=prompt_tokens,
            generation_tokens=result.stats.num_tokens,
            wall_time_s=result.stats.latency,
            first_token_latency_ms=(result.stats.ttft or result.stats.latency) * 1000,
            tokens_per_second=result.stats.tps,
            prompt_tokens_per_second=0.0,
        )


def build_filler_text(target_words: int) -> str:
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
    index = 0
    while len(text.split()) < target_words:
        text += sentences[index % len(sentences)] + " "
        index += 1
    return text.strip()


def clean_output(text: str) -> str:
    source = text
    if "</think>" in source:
        source = source.split("</think>", 1)[1]
    return source.replace("```", "").replace("\r\n", "\n").strip()


def extract_choice_letter(text: str) -> str:
    source = clean_output(text)
    for pattern in MCQ_PATTERNS:
        matches = pattern.findall(source)
        if matches:
            return matches[-1].upper()
    return "?"


def count_thinking_chars(text: str) -> tuple[int, int]:
    thinking_parts = THINK_RE.findall(text)
    thinking_chars = sum(len(part) for part in thinking_parts)
    visible = THINK_RE.sub("", text).strip()
    return len(visible), thinking_chars


def parse_flat_yaml(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in clean_output(text).splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        key, value = line.split(":", 1)
        result[key.strip()] = value.strip().strip("'\"")
    if not result:
        raise ValueError("No YAML fields parsed")
    return result


def parse_serialization_output(format_name: str, text: str) -> tuple[bool, dict[str, str]]:
    cleaned = clean_output(text)
    if format_name == "json":
        payload = json.loads(cleaned)
        if not isinstance(payload, dict):
            raise ValueError("JSON payload is not an object")
        return True, {str(k): str(v) for k, v in payload.items()}
    if format_name == "xml":
        root = ET.fromstring(cleaned)
        if root.tag != "record":
            raise ValueError("XML root is not <record>")
        return True, {child.tag: (child.text or "") for child in root}
    if format_name == "yaml":
        return True, parse_flat_yaml(cleaned)
    raise ValueError(f"Unsupported format: {format_name}")


def load_corpus(path: Path, limit_mcq: int | None, limit_serialization: int | None) -> dict[str, Any]:
    payload = json.loads(path.read_text())
    model = payload["models"][0]

    def maybe_limit(rows: list[dict[str, Any]], limit: int | None) -> list[dict[str, Any]]:
        return rows if limit is None else rows[:limit]

    return {
        "intelligence_eval": maybe_limit(model["intelligence_eval"], limit_mcq),
        "fae_capability_eval": maybe_limit(model["fae_capability_eval"], limit_mcq),
        "assistant_fit_eval": maybe_limit(model["assistant_fit_eval"], limit_mcq),
        "serialization_eval": maybe_limit(model["serialization_eval"], limit_serialization),
        "no_think_compliance": model["no_think_compliance"],
    }


async def run_mcq_section(
    runner: BaseRunner,
    questions: list[dict[str, Any]],
    *,
    label: str,
) -> dict[str, Any]:
    results: list[dict[str, Any]] = []

    for item in questions:
        user_prompt = "Return only <answer>X</answer>.\n\nQuestion:\n" + item["prompt"]
        generation = await runner.generate_chat(
            QWEN_CALIBRATED_MCQ_SYSTEM_PROMPT,
            user_prompt,
            max_tokens=48,
            temperature=0.0,
            enable_thinking=False,
        )
        actual = extract_choice_letter(generation.output_text)

        if actual == "?":
            generation = await runner.generate_chat(
                QWEN_CALIBRATED_MCQ_SYSTEM_PROMPT,
                user_prompt + "\n\nReminder: keep generating until you emit a final <answer>X</answer> tag.",
                max_tokens=192,
                temperature=0.0,
                enable_thinking=False,
            )
            actual = extract_choice_letter(generation.output_text)

        results.append(
            {
                "category": item["category"],
                "prompt": item["prompt"],
                "expected_answer": item["expected_answer"],
                "actual_answer": actual,
                "correct": actual == item["expected_answer"],
                "raw_output": generation.output_text,
                "first_token_latency_ms": round(generation.first_token_latency_ms, 1),
                "wall_time_s": round(generation.wall_time_s, 2),
            }
        )

    score = sum(1 for row in results if row["correct"])
    return {
        "label": label,
        "score": score,
        "total": len(results),
        "results": results,
    }


async def run_serialization_section(runner: BaseRunner, tests: list[dict[str, Any]]) -> dict[str, Any]:
    results: list[dict[str, Any]] = []

    for item in tests:
        user_prompt = (
            "Return only the payload with no prefix and no suffix.\n"
            "If you output any extra text before the payload, the answer is wrong.\n\n"
            f"Task:\n{item['prompt']}"
        )
        generation = await runner.generate_chat(
            QWEN_CALIBRATED_SERIALIZATION_SYSTEM_PROMPT,
            user_prompt,
            max_tokens=256,
            temperature=0.0,
            enable_thinking=False,
        )

        valid = False
        actual_fields: dict[str, str] = {}
        try:
            valid, actual_fields = parse_serialization_output(item["format"], generation.output_text)
        except Exception:
            valid = False
            actual_fields = {}

        expected_fields = {str(k): str(v) for k, v in item["expected_fields"].items()}
        correct = valid and actual_fields == expected_fields

        results.append(
            {
                "format": item["format"],
                "task": item["task"],
                "prompt": item["prompt"],
                "expected_fields": expected_fields,
                "actual_fields": actual_fields,
                "valid": valid,
                "correct": correct,
                "raw_output": generation.output_text,
                "first_token_latency_ms": round(generation.first_token_latency_ms, 1),
                "wall_time_s": round(generation.wall_time_s, 2),
            }
        )

    score = sum(1 for row in results if row["correct"])
    return {
        "label": "serialization_eval",
        "score": score,
        "total": len(results),
        "results": results,
    }


async def run_no_think_section(runner: BaseRunner, prompts: list[dict[str, Any]]) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    system = "You are a helpful assistant. Be concise."

    for item in prompts:
        prompt = item["prompt"]

        thinking_on = await runner.generate_chat(
            system,
            prompt,
            max_tokens=256,
            temperature=0.7,
            enable_thinking=True,
        )
        thinking_off = await runner.generate_chat(
            system,
            prompt,
            max_tokens=256,
            temperature=0.7,
            enable_thinking=False,
        )

        _, think_chars_off = count_thinking_chars(thinking_off.output_text)
        compliant = think_chars_off <= 10

        results.append(
            {
                "prompt": prompt,
                "think_on_tokens": thinking_on.generation_tokens,
                "think_on_time_s": round(thinking_on.wall_time_s, 2),
                "think_off_tokens": thinking_off.generation_tokens,
                "think_off_time_s": round(thinking_off.wall_time_s, 2),
                "overhead_tokens": (
                    f"{round(thinking_on.generation_tokens / max(thinking_off.generation_tokens, 1))}x"
                    if thinking_off.generation_tokens > 0
                    else "N/A"
                ),
                "overhead_time": (
                    f"{round(thinking_on.wall_time_s / max(thinking_off.wall_time_s, 1e-3))}x"
                    if thinking_off.wall_time_s > 0
                    else "N/A"
                ),
                "compliant": compliant,
                "think_on_raw_output": thinking_on.output_text,
                "think_off_raw_output": thinking_off.output_text,
            }
        )

    score = sum(1 for row in results if row["compliant"])
    return {
        "label": "no_think_compliance",
        "score": score,
        "total": len(results),
        "results": results,
    }


async def run_throughput_section(runner: BaseRunner, contexts: list[str]) -> dict[str, Any]:
    system = "You are a helpful assistant. Be concise."
    filler = build_filler_text(6500)
    words = filler.split()

    all_tests = {
        "short": ("Short (~20 tok)", "What is the weather like today?", 128),
        "1k": ("~1K tok ctx", " ".join(words[:750]) + " Summarize.", 256),
        "8.5k": (
            "~8.5K tok",
            filler + " Given all of this context, what are the three most important developments?",
            256,
        ),
    }

    results: list[dict[str, Any]] = []
    for key in contexts:
        label, prompt, max_tokens = all_tests[key]
        generation = await runner.generate_chat(
            system,
            prompt,
            max_tokens=max_tokens,
            temperature=0.7,
            enable_thinking=False,
        )
        results.append(
            {
                "context_key": key,
                "context_label": label,
                "prompt_tokens": generation.prompt_tokens,
                "generated_tokens": generation.generation_tokens,
                "wall_time_s": round(generation.wall_time_s, 2),
                "first_token_latency_ms": round(generation.first_token_latency_ms, 1),
                "tokens_per_second": round(generation.tokens_per_second, 1),
                "prompt_tokens_per_second": round(generation.prompt_tokens_per_second, 1),
            }
        )

    return {
        "label": "throughput_no_think",
        "results": results,
    }


def summarize_sections(run: dict[str, Any]) -> dict[str, Any]:
    return {
        "intelligence_eval": f"{run['intelligence_eval']['score']}/{run['intelligence_eval']['total']}",
        "fae_capability_eval": f"{run['fae_capability_eval']['score']}/{run['fae_capability_eval']['total']}",
        "assistant_fit_eval": f"{run['assistant_fit_eval']['score']}/{run['assistant_fit_eval']['total']}",
        "serialization_eval": f"{run['serialization_eval']['score']}/{run['serialization_eval']['total']}",
        "no_think_compliance": f"{run['no_think_compliance']['score']}/{run['no_think_compliance']['total']}",
    }


def compute_differences(left: dict[str, Any], right: dict[str, Any], section: str) -> list[dict[str, Any]]:
    diffs: list[dict[str, Any]] = []
    left_rows = left[section]["results"]
    right_rows = right[section]["results"]
    for left_row, right_row in zip(left_rows, right_rows):
        if left_row.get("correct") != right_row.get("correct") or left_row.get("actual_answer") != right_row.get("actual_answer"):
            diffs.append(
                {
                    "prompt": left_row["prompt"],
                    "left_correct": left_row.get("correct"),
                    "right_correct": right_row.get("correct"),
                    "left_actual_answer": left_row.get("actual_answer"),
                    "right_actual_answer": right_row.get("actual_answer"),
                    "expected_answer": left_row.get("expected_answer"),
                }
            )
    return diffs


async def run_model_suite(runner: BaseRunner, corpus: dict[str, Any], throughput_contexts: list[str]) -> dict[str, Any]:
    await runner.load()
    try:
        intelligence = await run_mcq_section(runner, corpus["intelligence_eval"], label="intelligence_eval")
        fae_capability = await run_mcq_section(runner, corpus["fae_capability_eval"], label="fae_capability_eval")
        assistant_fit = await run_mcq_section(runner, corpus["assistant_fit_eval"], label="assistant_fit_eval")
        serialization = await run_serialization_section(runner, corpus["serialization_eval"])
        no_think = await run_no_think_section(runner, corpus["no_think_compliance"])
        throughput = await run_throughput_section(runner, throughput_contexts)
    finally:
        await runner.close()

    return {
        "runner": runner.name,
        "model_id": runner.model_id,
        "intelligence_eval": intelligence,
        "fae_capability_eval": fae_capability,
        "assistant_fit_eval": assistant_fit,
        "serialization_eval": serialization,
        "no_think_compliance": no_think,
        "throughput_no_think": throughput,
    }


async def main() -> None:
    parser = argparse.ArgumentParser(description="Compare standard MLX 4-bit and ParoQuant 4-bit Qwen3.5-9B")
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--standard-model", default="mlx-community/Qwen3.5-9B-4bit")
    parser.add_argument("--standard-adapter-path", default=None)
    parser.add_argument("--standard-label", default="standard_mlx_4bit")
    parser.add_argument("--paro-model", default="z-lab/Qwen3.5-9B-PARO")
    parser.add_argument("--paro-label", default="paroquant_4bit")
    parser.add_argument("--limit-mcq", type=int, default=None)
    parser.add_argument("--limit-serialization", type=int, default=None)
    parser.add_argument("--throughput-contexts", default="short,1k,8.5k")
    args = parser.parse_args()

    corpus = load_corpus(args.corpus, args.limit_mcq, args.limit_serialization)
    throughput_contexts = [item.strip() for item in args.throughput_contexts.split(",") if item.strip()]

    standard = StandardMLXRunner(
        args.standard_model,
        adapter_path=args.standard_adapter_path,
        label=args.standard_label,
    )
    paro = ParoQuantRunner(args.paro_model, label=args.paro_label)

    standard_run = await run_model_suite(standard, corpus, throughput_contexts)
    paro_run = await run_model_suite(paro, corpus, throughput_contexts)

    output = {
        "date": datetime.now().isoformat(timespec="seconds"),
        "reference_corpus": str(args.corpus),
        "comparison": {
            standard_run["runner"]: summarize_sections(standard_run),
            paro_run["runner"]: summarize_sections(paro_run),
            "fae_capability_diffs": compute_differences(standard_run, paro_run, "fae_capability_eval"),
            "assistant_fit_diffs": compute_differences(standard_run, paro_run, "assistant_fit_eval"),
            "intelligence_diffs": compute_differences(standard_run, paro_run, "intelligence_eval"),
        },
        "models": [standard_run, paro_run],
    }

    args.output_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = args.output_dir / f"qwen35-9b-mlx-vs-paroquant_{stamp}.json"
    out_path.write_text(json.dumps(output, indent=2))
    print(out_path)


if __name__ == "__main__":
    asyncio.run(main())
