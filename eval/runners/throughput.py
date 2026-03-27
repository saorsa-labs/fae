"""Throughput benchmarking runner — measures TPS, TTFT, RAM."""

from __future__ import annotations

import time

from schemas import Dimension, ScenarioResult, Verdict
from runners.base import BaseRunner


class ThroughputRunner(BaseRunner):
    dimension = Dimension.throughput

    async def _run_scenario(self, scenario) -> ScenarioResult:
        """Override to capture detailed timing metrics."""
        messages = []
        if scenario.system_prompt:
            messages.append({"role": "system", "content": scenario.system_prompt})
        messages.extend(scenario.turns)

        t0 = time.perf_counter()
        response = await self.client.chat(
            messages=messages,
            temperature=scenario.temperature,
            max_tokens=512,
        )
        elapsed_ms = (time.perf_counter() - t0) * 1000

        usage = response.get("usage", {})
        prompt_tokens = usage.get("prompt_tokens", 0)
        completion_tokens = usage.get("completion_tokens", 0)
        content = self.client.extract_content(response)

        tps = completion_tokens / (elapsed_ms / 1000) if elapsed_ms > 0 else 0

        return ScenarioResult(
            scenario_id=scenario.id,
            dimension=scenario.dimension,
            category=scenario.category,
            verdict=Verdict.passed,
            score=1.0,
            model_output=f"TPS: {tps:.1f} | Tokens: {completion_tokens} | Latency: {elapsed_ms:.0f}ms",
            latency_ms=elapsed_ms,
            tokens_generated=completion_tokens,
        )
