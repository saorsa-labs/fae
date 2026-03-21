# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx"]
# ///
"""FaeAutoResearch inject runner — drives TestServer HTTP API to execute e2e scenarios."""

import argparse
import json
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import httpx

BASE_URL = "http://127.0.0.1:7433"
DEFAULT_TIMEOUT = 30.0
POLL_INTERVAL = 0.5


@dataclass
class ScenarioResult:
    id: str
    dimension: str
    passed: bool = False
    latency_ms: float = 0.0
    events: list = field(default_factory=list)
    response_text: str = ""
    tools_called: list = field(default_factory=list)
    checks: dict = field(default_factory=dict)
    errors: list = field(default_factory=list)
    inject_text: str = ""
    started_at: str = ""
    completed_at: str = ""


class FaeTestClient:
    def __init__(self, base_url: str = BASE_URL):
        self.base_url = base_url
        self.client = httpx.Client(base_url=base_url, timeout=DEFAULT_TIMEOUT)
        self._event_seq = 0

    def health(self) -> dict:
        r = self.client.get("/health")
        return r.json()

    def inject(self, text: str) -> dict:
        r = self.client.post("/inject", json={"text": text})
        return r.json()

    def status(self) -> dict:
        r = self.client.get("/status")
        return r.json()

    def events_since(self, since: int = 0) -> dict:
        r = self.client.get(f"/events?since={since}")
        return r.json()

    def conversation(self) -> dict:
        r = self.client.get("/conversation")
        return r.json()

    def cancel(self) -> dict:
        r = self.client.post("/cancel")
        return r.json()

    def config(self, key: str, value) -> dict:
        r = self.client.post("/config", json={"key": key, "value": value})
        return r.json()

    def approve(self, approved: bool = True) -> dict:
        r = self.client.post("/approve", json={"approved": approved})
        return r.json()

    def approvals(self) -> dict:
        r = self.client.get("/approvals")
        return r.json()

    def reset(self) -> dict:
        r = self.client.post("/reset")
        return r.json()

    def memory_recall(self, query: str) -> dict:
        r = self.client.post("/memory/recall", json={"query": query})
        return r.json()

    def memory_import(self, text: str, source: str = "autoresearch") -> dict:
        r = self.client.post("/memory/import-text", json={"text": text, "source": source})
        return r.json()

    def wait_for_response(self, timeout_ms: int = 30000) -> dict:
        """Poll /conversation until generation completes."""
        deadline = time.monotonic() + timeout_ms / 1000
        last_conv = {}
        while time.monotonic() < deadline:
            try:
                conv = self.conversation()
                last_conv = conv
                if not conv.get("isGenerating", True):
                    return conv
            except httpx.HTTPError:
                pass
            time.sleep(POLL_INTERVAL)
        return last_conv

    def wait_and_approve(self, timeout_ms: int = 10000) -> bool:
        """Poll for pending approvals and auto-approve."""
        deadline = time.monotonic() + timeout_ms / 1000
        while time.monotonic() < deadline:
            try:
                pending = self.approvals()
                if pending.get("approvals") and len(pending["approvals"]) > 0:
                    self.approve(True)
                    return True
            except httpx.HTTPError:
                pass
            time.sleep(POLL_INTERVAL)
        return False

    def collect_events(self, since: int | None = None) -> tuple[list, int]:
        """Get events since a sequence number. Returns (events, latest_seq)."""
        seq = since if since is not None else self._event_seq
        data = self.events_since(seq)
        events = data.get("events", [])
        latest = data.get("latestSequence", seq)
        self._event_seq = latest
        return events, latest

    def mark_event_position(self) -> int:
        """Record current event sequence for later collection."""
        data = self.events_since(999999999)  # Get latest sequence without events
        self._event_seq = data.get("latestSequence", 0)
        return self._event_seq

    def close(self):
        self.client.close()


def extract_assistant_text(conv: dict) -> str:
    """Extract the last assistant message text from conversation."""
    messages = conv.get("messages", [])
    for msg in reversed(messages):
        if msg.get("role") == "assistant":
            return msg.get("content", "")
    return conv.get("streamingText", "")


def extract_tools_called(events: list) -> list[str]:
    """Extract tool names from events."""
    tools = []
    for ev in events:
        text = ev.get("text", "")
        kind = ev.get("kind", "")
        if kind == "Tool→" or "Tool→" in text:
            # Extract tool name from event text
            if ":" in text:
                tool_name = text.split(":")[0].replace("Tool→", "").strip()
                if tool_name:
                    tools.append(tool_name)
            elif " " in text:
                parts = text.split()
                for p in parts:
                    if p not in ("Tool→", "→"):
                        tools.append(p)
                        break
    return tools


def check_response_contains(text: str, keywords: list[str]) -> bool:
    """Check if response contains any of the expected keywords (case-insensitive)."""
    lower = text.lower()
    return any(kw.lower() in lower for kw in keywords)


def run_simple_scenario(client: FaeTestClient, scenario: dict) -> ScenarioResult:
    """Run a single inject-and-check scenario."""
    result = ScenarioResult(
        id=scenario["id"],
        dimension=scenario.get("dimension", "unknown"),
        inject_text=scenario.get("inject", ""),
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        # Setup: apply config if specified
        setup = scenario.get("setup", {})
        if "config" in setup:
            for key, value in setup["config"].items():
                client.config(key, value)

        # Mark event position
        event_start = client.mark_event_position()
        start_time = time.monotonic()

        # Inject text
        client.inject(scenario["inject"])

        # Handle approval if expected
        approval_action = scenario.get("approval_action")
        if approval_action is not None:
            approved = client.wait_and_approve()
            result.checks["approval_triggered"] = approved

        # Wait for response
        max_latency = scenario.get("max_latency_ms", 30000)
        conv = client.wait_for_response(timeout_ms=max_latency + 5000)

        end_time = time.monotonic()
        result.latency_ms = (end_time - start_time) * 1000

        # Collect events
        events, _ = client.collect_events(event_start)
        result.events = events

        # Extract response
        result.response_text = extract_assistant_text(conv)
        result.tools_called = extract_tools_called(events)

        # Run checks
        all_passed = True

        if "expect_response_contains" in scenario:
            contains = check_response_contains(
                result.response_text, scenario["expect_response_contains"]
            )
            result.checks["response_contains"] = contains
            if not contains:
                all_passed = False

        if "max_latency_ms" in scenario:
            within_limit = result.latency_ms <= scenario["max_latency_ms"]
            result.checks["max_latency"] = within_limit
            if not within_limit:
                all_passed = False

        if "expect_tool" in scenario:
            tool_found = scenario["expect_tool"] in result.tools_called
            result.checks["tool_called"] = tool_found
            if not tool_found:
                all_passed = False

        if "expect_no_think_tags" in scenario:
            has_tags = "<think>" in result.response_text
            result.checks["no_think_tags"] = not has_tags
            if has_tags:
                all_passed = False

        result.passed = all_passed

    except Exception as e:
        result.errors.append(str(e))
        result.passed = False

    finally:
        result.completed_at = datetime.now(timezone.utc).isoformat()
        # Teardown
        teardown = scenario.get("teardown", {})
        if teardown.get("endpoint") == "/reset":
            try:
                client.reset()
            except httpx.HTTPError:
                pass

    return result


def run_multi_step_scenario(client: FaeTestClient, scenario: dict) -> ScenarioResult:
    """Run a multi-step scenario (steps array)."""
    result = ScenarioResult(
        id=scenario["id"],
        dimension=scenario.get("dimension", "unknown"),
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        steps = scenario.get("steps", [])
        all_passed = True

        for i, step in enumerate(steps):
            step_start = time.monotonic()
            event_start = client.mark_event_position()

            # Inject
            inject_text = step.get("inject", "")
            if inject_text:
                result.inject_text = inject_text  # Last inject
                client.inject(inject_text)

            # Wait specified time or for response
            wait_ms = step.get("wait_ms", 15000)
            conv = client.wait_for_response(timeout_ms=wait_ms)

            step_latency = (time.monotonic() - step_start) * 1000
            result.latency_ms += step_latency

            # Collect events
            events, _ = client.collect_events(event_start)
            result.events.extend(events)

            # Check response for this step
            response = extract_assistant_text(conv)
            result.response_text = response  # Last response

            if "expect_response_contains" in step:
                contains = check_response_contains(response, step["expect_response_contains"])
                result.checks[f"step_{i}_response_contains"] = contains
                if not contains:
                    all_passed = False

            if "expect_tool" in step:
                tools = extract_tools_called(events)
                result.tools_called.extend(tools)
                tool_found = step["expect_tool"] in tools
                result.checks[f"step_{i}_tool_called"] = tool_found
                if not tool_found:
                    all_passed = False

        result.passed = all_passed

    except Exception as e:
        result.errors.append(str(e))
        result.passed = False

    finally:
        result.completed_at = datetime.now(timezone.utc).isoformat()
        try:
            client.reset()
        except httpx.HTTPError:
            pass

    return result


def run_interrupt_scenario(client: FaeTestClient, scenario: dict) -> ScenarioResult:
    """Run a barge-in / interrupt scenario."""
    result = ScenarioResult(
        id=scenario["id"],
        dimension=scenario.get("dimension", "barge_in"),
        inject_text=scenario.get("inject", ""),
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        event_start = client.mark_event_position()
        start_time = time.monotonic()

        # First inject to start Fae speaking
        client.inject(scenario["inject"])

        # Wait for specified duration before interrupting
        wait_ms = scenario.get("wait_ms", 3000)
        time.sleep(wait_ms / 1000)

        # Check if Fae is still generating/speaking
        conv_before = client.conversation()
        was_generating = conv_before.get("isGenerating", False)

        # Interrupt
        interrupt_text = scenario.get("interrupt_inject", "Stop")
        interrupt_time = time.monotonic()
        client.inject(interrupt_text)

        # Wait for the interrupt to take effect
        time.sleep(1.0)
        conv_after = client.conversation()
        interrupt_end = time.monotonic()

        result.latency_ms = (interrupt_end - start_time) * 1000

        # Collect events
        events, _ = client.collect_events(event_start)
        result.events = events
        result.response_text = extract_assistant_text(conv_after)
        result.tools_called = extract_tools_called(events)

        # Checks
        all_passed = True

        if scenario.get("expect_tts_stopped", False):
            # Check if generation stopped after interrupt
            stopped = not conv_after.get("isGenerating", True)
            result.checks["tts_stopped"] = stopped
            if not stopped:
                all_passed = False

        interrupt_latency = (interrupt_end - interrupt_time) * 1000
        max_interrupt_latency = scenario.get("max_interrupt_latency_ms", 2000)
        within_limit = interrupt_latency <= max_interrupt_latency
        result.checks["interrupt_latency_ms"] = interrupt_latency
        result.checks["max_interrupt_latency"] = within_limit

        result.passed = all_passed

    except Exception as e:
        result.errors.append(str(e))
        result.passed = False

    finally:
        result.completed_at = datetime.now(timezone.utc).isoformat()
        try:
            client.reset()
        except httpx.HTTPError:
            pass

    return result


def run_scenario(client: FaeTestClient, scenario: dict) -> ScenarioResult:
    """Route scenario to appropriate handler."""
    if "steps" in scenario:
        return run_multi_step_scenario(client, scenario)
    elif "interrupt_inject" in scenario:
        return run_interrupt_scenario(client, scenario)
    else:
        return run_simple_scenario(client, scenario)


def load_scenarios(path: Path) -> list[dict]:
    """Load JSONL scenario file."""
    scenarios = []
    with open(path) as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                scenarios.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"Warning: invalid JSON on line {line_num}: {e}", file=sys.stderr)
    return scenarios


def main():
    parser = argparse.ArgumentParser(description="FaeAutoResearch inject runner")
    parser.add_argument("--scenarios", required=True, help="Path to JSONL scenario file")
    parser.add_argument("--output", required=True, help="Path to output results JSON")
    parser.add_argument("--base-url", default=BASE_URL, help="TestServer base URL")
    parser.add_argument("--dimension", help="Only run scenarios for this dimension")
    args = parser.parse_args()

    scenarios = load_scenarios(Path(args.scenarios))
    if args.dimension:
        scenarios = [s for s in scenarios if s.get("dimension") == args.dimension]

    print(f"Loaded {len(scenarios)} scenarios from {args.scenarios}")

    client = FaeTestClient(args.base_url)

    # Verify TestServer is ready
    try:
        health = client.health()
        if not health.get("ready", False):
            print(f"Warning: TestServer not ready: {health}", file=sys.stderr)
    except httpx.HTTPError as e:
        print(f"Error: Cannot connect to TestServer at {args.base_url}: {e}", file=sys.stderr)
        sys.exit(1)

    results = []
    passed = 0
    failed = 0

    for i, scenario in enumerate(scenarios):
        sid = scenario.get("id", f"unknown_{i}")
        print(f"  [{i+1}/{len(scenarios)}] {sid} ...", end=" ", flush=True)

        result = run_scenario(client, scenario)
        results.append(asdict(result))

        if result.passed:
            passed += 1
            print("PASS", f"({result.latency_ms:.0f}ms)")
        else:
            failed += 1
            checks_detail = " ".join(
                f"{k}={'OK' if v else 'FAIL'}" for k, v in result.checks.items()
                if isinstance(v, bool)
            )
            errors = f" errors={result.errors}" if result.errors else ""
            print(f"FAIL ({checks_detail}{errors})")

    # Write output
    output = {
        "run_at": datetime.now(timezone.utc).isoformat(),
        "scenario_file": args.scenarios,
        "total": len(results),
        "passed": passed,
        "failed": failed,
        "pass_rate": passed / max(len(results), 1),
        "results": results,
    }

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2, default=str)

    # Symlink latest
    latest = output_path.parent / "latest.json"
    latest.unlink(missing_ok=True)
    latest.symlink_to(output_path.name)

    print(f"\nResults: {passed}/{len(results)} passed ({passed/max(len(results),1)*100:.0f}%)")
    print(f"Output: {output_path}")

    client.close()
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
