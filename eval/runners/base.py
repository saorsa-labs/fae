"""Base runner with SSE event streaming and model client abstraction."""

from __future__ import annotations

import asyncio
import base64
import json
import time
import uuid
from pathlib import Path
from typing import Any, AsyncIterator

import httpx

from schemas import (
    Check,
    Dimension,
    DimensionSummary,
    RunEvent,
    RunResult,
    Scenario,
    ScenarioResult,
    Verdict,
)
from scoring.engine import score_scenario


class ModelClient:
    """OpenAI-compatible chat completion client.

    Works with:
    - Fae's local runtime server (http://127.0.0.1:7434)
    - MLX local server
    - llama.cpp server
    - Any OpenAI-compatible endpoint
    """

    def __init__(self, base_url: str, model: str, api_key: str = "", timeout: float = 120.0):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.api_key = api_key
        self.timeout = timeout
        self._client = httpx.AsyncClient(timeout=timeout)

    async def chat(
        self,
        messages: list[dict[str, str]],
        tools: list[dict[str, Any]] | None = None,
        temperature: float = 0.0,
        max_tokens: int = 1024,
    ) -> dict[str, Any]:
        """Send a chat completion request. Returns the raw response dict."""
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
        }
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"

        headers: dict[str, str] = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        url = f"{self.base_url}/v1/chat/completions"
        resp = await self._client.post(url, json=payload, headers=headers)
        resp.raise_for_status()
        return resp.json()

    async def close(self) -> None:
        await self._client.aclose()

    @staticmethod
    def extract_content(response: dict[str, Any]) -> str:
        """Extract text content from a chat completion response."""
        choices = response.get("choices", [])
        if not choices:
            return ""
        msg = choices[0].get("message", {})
        content = msg.get("content", "")
        if isinstance(content, list):
            return " ".join(c.get("text", "") for c in content if isinstance(c, dict))
        return content or ""

    @staticmethod
    def extract_tool_calls(response: dict[str, Any]) -> list[dict[str, Any]]:
        """Extract tool calls from a chat completion response."""
        choices = response.get("choices", [])
        if not choices:
            return []
        msg = choices[0].get("message", {})
        tool_calls = msg.get("tool_calls", [])
        result = []
        for tc in tool_calls:
            fn = tc.get("function", {})
            args = fn.get("arguments", "{}")
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError:
                    pass
            result.append({
                "id": tc.get("id", str(uuid.uuid4())[:8]),
                "name": fn.get("name", ""),
                "arguments": args,
            })
        return result


class BaseRunner:
    """Base class for evaluation runners with SSE streaming."""

    dimension: Dimension

    def __init__(self, client: ModelClient, scenarios: list[Scenario]):
        self.client = client
        self.scenarios = [s for s in scenarios if s.dimension == self.dimension]

    async def run(self, run_id: str) -> AsyncIterator[tuple[RunEvent, ScenarioResult | None]]:
        """Run all scenarios, yielding SSE events and results."""
        for i, scenario in enumerate(self.scenarios):
            # Emit start event
            yield RunEvent(
                kind="scenario_start",
                run_id=run_id,
                data={
                    "scenario_id": scenario.id,
                    "dimension": scenario.dimension.value,
                    "category": scenario.category,
                    "index": i,
                    "total": len(self.scenarios),
                },
            ), None

            try:
                result = await self._run_scenario(scenario)
            except Exception as e:
                result = ScenarioResult(
                    scenario_id=scenario.id,
                    dimension=scenario.dimension,
                    category=scenario.category,
                    verdict=Verdict.error,
                    score=0.0,
                    error_message=str(e),
                )

            yield RunEvent(
                kind="scenario_result",
                run_id=run_id,
                data={
                    "scenario_id": scenario.id,
                    "verdict": result.verdict.value,
                    "score": result.score,
                    "latency_ms": result.latency_ms,
                    "checks_passed": result.checks_passed,
                    "checks_failed": result.checks_failed,
                    "model_output": result.model_output[:500],
                    "error": result.error_message,
                },
            ), result

        # Dimension summary
        summary = self._compute_summary(run_id)
        yield RunEvent(
            kind="dimension_complete",
            run_id=run_id,
            data={
                "dimension": self.dimension.value,
                "score": summary.score,
                "passed": summary.passed,
                "failed": summary.failed,
                "total": summary.total,
            },
        ), None

    async def _run_scenario(self, scenario: Scenario) -> ScenarioResult:
        """Run a single scenario. Override in subclasses for custom behavior."""
        messages: list[dict[str, Any]] = []
        if scenario.system_prompt:
            messages.append({"role": "system", "content": scenario.system_prompt})
        messages.extend(scenario.turns)

        # Attach base64 image to the last user message if image_path is set
        if scenario.image_path:
            eval_root = Path(__file__).parent.parent
            img_path = eval_root / scenario.image_path
            if img_path.exists():
                b64 = base64.b64encode(img_path.read_bytes()).decode("ascii")
                # Find the last user message and add image_base64
                for msg in reversed(messages):
                    if msg.get("role") == "user":
                        msg["image_base64"] = b64
                        break

        tools = scenario.tools if scenario.tools else None

        t0 = time.perf_counter()
        response = await self.client.chat(
            messages=messages,
            tools=tools,
            temperature=scenario.temperature,
        )
        elapsed_ms = (time.perf_counter() - t0) * 1000

        content = self.client.extract_content(response)
        tool_calls = self.client.extract_tool_calls(response)

        # Multi-turn: if tool calls and mock responses, loop
        turn = 0
        while tool_calls and scenario.mock_tool_responses and turn < scenario.max_turns:
            for tc in tool_calls:
                mock = next(
                    (m for m in scenario.mock_tool_responses if m.tool_name == tc["name"]),
                    None,
                )
                tool_result = json.dumps(mock.response) if mock else '{"error": "no mock"}'
                messages.append({
                    "role": "assistant",
                    "content": content,
                })
                messages.append({
                    "role": "tool",
                    "content": tool_result,
                    "tool_call_id": tc["id"],
                })

            response = await self.client.chat(
                messages=messages,
                tools=tools,
                temperature=scenario.temperature,
            )
            content = self.client.extract_content(response)
            new_tool_calls = self.client.extract_tool_calls(response)
            if not new_tool_calls:
                break
            tool_calls.extend(new_tool_calls)
            turn += 1

        usage = response.get("usage", {})
        tokens = usage.get("completion_tokens", 0)

        return score_scenario(
            scenario=scenario,
            model_output=content,
            tool_calls=tool_calls,
            latency_ms=elapsed_ms,
            tokens=tokens,
        )

    def _compute_summary(self, run_id: str) -> DimensionSummary:
        """Compute dimension summary from collected results (called after run)."""
        # This is a placeholder — actual aggregation happens in the orchestrator
        return DimensionSummary(dimension=self.dimension)
