"""Deterministic scoring engine — evaluates model output against scenario checks."""

from __future__ import annotations

import json
import re
from typing import Any

from schemas import Check, Scenario, ScenarioResult, Verdict


def score_scenario(scenario: Scenario, model_output: str, tool_calls: list[dict[str, Any]], latency_ms: float = 0.0, tokens: int = 0, first_token_ms: float = 0.0) -> ScenarioResult:
    """Score a single scenario against its checks and expectations."""
    checks_passed: list[str] = []
    checks_failed: list[str] = []

    # --- Tool expectation checks (if any) ---
    if scenario.expected_tool_calls:
        for exp in scenario.expected_tool_calls:
            matched = any(tc.get("name") == exp.name for tc in tool_calls)
            label = f"tool:{exp.name}"
            if matched:
                checks_passed.append(label)
                # Check args if specified
                if exp.args_contain:
                    tc_match = next((tc for tc in tool_calls if tc.get("name") == exp.name), {})
                    tc_args = tc_match.get("arguments", {})
                    if isinstance(tc_args, str):
                        try:
                            tc_args = json.loads(tc_args)
                        except json.JSONDecodeError:
                            tc_args = {}
                    for k, v in exp.args_contain.items():
                        arg_label = f"tool_arg:{exp.name}.{k}={v}"
                        if str(tc_args.get(k, "")).lower() == str(v).lower():
                            checks_passed.append(arg_label)
                        else:
                            checks_failed.append(arg_label)
            else:
                checks_failed.append(label)

    if scenario.no_tool_call_expected:
        label = "no_tool_call"
        if not tool_calls:
            checks_passed.append(label)
        else:
            checks_failed.append(label)

    # --- Check-based evaluation ---
    for check in scenario.checks:
        label = f"{check.kind}:{_check_label(check)}"
        if _evaluate_check(check, model_output):
            checks_passed.append(label)
        else:
            checks_failed.append(label)

    # --- Compute verdict ---
    total_checks = len(checks_passed) + len(checks_failed)
    if total_checks == 0:
        verdict = Verdict.passed
        score = 1.0
    elif not checks_failed:
        verdict = Verdict.passed
        score = 1.0
    elif not checks_passed:
        verdict = Verdict.fail
        score = 0.0
    else:
        ratio = len(checks_passed) / total_checks
        if ratio >= 0.7:
            verdict = Verdict.partial
            score = 0.5
        else:
            verdict = Verdict.fail
            score = 0.0

    return ScenarioResult(
        scenario_id=scenario.id,
        dimension=scenario.dimension,
        category=scenario.category,
        verdict=verdict,
        score=score,
        model_output=model_output[:2000],
        tool_calls_made=tool_calls,
        checks_passed=checks_passed,
        checks_failed=checks_failed,
        latency_ms=latency_ms,
        tokens_generated=tokens,
        first_token_ms=first_token_ms,
    )


def _check_label(check: Check) -> str:
    v = check.value
    if isinstance(v, str):
        return v[:40]
    if isinstance(v, list):
        return ",".join(str(x)[:15] for x in v[:3])
    return str(v)[:40]


def _evaluate_check(check: Check, output: str) -> bool:
    kind = check.kind
    value = check.value
    text = output.strip()
    text_lower = text.lower()

    if kind == "exact":
        return text == str(value)

    if kind == "exact_ignorecase":
        return text_lower == str(value).lower()

    if kind == "contains_all":
        if not isinstance(value, list):
            return False
        return all(str(v).lower() in text_lower for v in value)

    if kind == "contains_any":
        if not isinstance(value, list):
            return False
        return any(str(v).lower() in text_lower for v in value)

    if kind == "forbids_any":
        if not isinstance(value, list):
            return False
        return not any(str(v).lower() in text_lower for v in value)

    if kind == "max_words":
        return len(text.split()) <= int(value)

    if kind == "min_words":
        return len(text.split()) >= int(value)

    if kind == "requires_question":
        return "?" in text

    if kind == "mcq_letter":
        # Extract a single letter A-D from model output
        extracted = _extract_mcq_letter(text)
        return extracted == str(value).upper()

    if kind == "tool_name":
        # Check that a tool call with this name was made
        # (handled in main tool expectation logic, but kept for standalone use)
        return str(value).lower() in text_lower

    if kind == "keyword_groups":
        # value = {"groups": [["kw1", "kw2"], ["kw3"]], "min_matched": 2}
        if not isinstance(value, dict):
            return False
        groups = value.get("groups", [])
        min_matched = value.get("min_matched", 2)
        matched = sum(
            1 for group in groups if any(kw.lower() in text_lower for kw in group)
        )
        return matched >= min_matched

    if kind == "field_match":
        # value = {"format": "json|xml|yaml", "expected": {"key": "val"}}
        if not isinstance(value, dict):
            return False
        expected_fields = value.get("expected", {})
        return _check_fields(text, expected_fields)

    if kind == "regex":
        try:
            return bool(re.search(str(value), text, re.IGNORECASE))
        except re.error:
            return False

    if kind == "thinking_suppressed":
        # Check that thinking output is minimal (<=10 chars)
        think_match = re.search(r"<think>(.*?)</think>", text, re.DOTALL)
        if think_match:
            return len(think_match.group(1).strip()) <= 10
        return True

    return False


def _extract_mcq_letter(text: str) -> str:
    """Extract MCQ answer letter from model output."""
    text = text.strip()
    # Direct single letter
    if len(text) == 1 and text.upper() in "ABCD":
        return text.upper()
    # "The answer is X" pattern
    m = re.search(r"(?:answer|correct)\s+(?:is\s+)?([A-Da-d])\b", text, re.IGNORECASE)
    if m:
        return m.group(1).upper()
    # "(X)" pattern
    m = re.search(r"\(([A-Da-d])\)", text)
    if m:
        return m.group(1).upper()
    # First letter at start
    m = re.match(r"([A-Da-d])[\.\)\:]", text)
    if m:
        return m.group(1).upper()
    # Last single letter
    m = re.search(r"\b([A-Da-d])\s*$", text)
    if m:
        return m.group(1).upper()
    return ""


def _check_fields(text: str, expected: dict[str, str]) -> bool:
    """Check that structured output contains expected key-value pairs."""
    text_lower = text.lower()
    matched = 0
    for key, val in expected.items():
        # Look for key:val or key=val or "key": "val" patterns
        patterns = [
            f'"{key}"\\s*:\\s*"{val}"',
            f"{key}\\s*:\\s*{val}",
            f"<{key}>{val}</{key}>",
            f"{key}={val}",
        ]
        for pat in patterns:
            if re.search(pat, text_lower, re.IGNORECASE):
                matched += 1
                break
    return matched == len(expected)
