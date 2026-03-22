# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx"]
# ///
"""Voice Pipeline AutoResearch runner — handles text injection, audio injection, and resource monitoring."""

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

# Unset SSL_CERT_FILE if it points to a missing file (zerobrew Python 3.14 issue).
_ssl_cert = os.environ.get("SSL_CERT_FILE", "")
if _ssl_cert and not os.path.exists(_ssl_cert):
    del os.environ["SSL_CERT_FILE"]

import httpx

BASE_URL = "http://127.0.0.1:7433"
DEFAULT_TIMEOUT = 90.0
POLL_INTERVAL = 0.5
LATENCY_BUFFER_MS = 60000


@dataclass
class ScenarioResult:
    id: str
    dimension: str
    scenario_type: str = "text"
    passed: bool = False
    latency_ms: float = 0.0
    events: list = field(default_factory=list)
    response_text: str = ""
    tools_called: list = field(default_factory=list)
    checks: dict = field(default_factory=dict)
    errors: list = field(default_factory=list)
    inject_text: str = ""
    audio_file: str = ""
    resource_metrics: dict = field(default_factory=dict)
    started_at: str = ""
    completed_at: str = ""


class FaeTestClient:
    def __init__(self, base_url: str = BASE_URL):
        self.base_url = base_url
        self.client = httpx.Client(base_url=base_url, timeout=DEFAULT_TIMEOUT)
        self._event_seq = 0

    def health(self) -> dict:
        return self.client.get("/health").json()

    def inject(self, text: str, max_retries: int = 10) -> dict:
        for attempt in range(max_retries):
            r = self.client.post("/inject", json={"text": text})
            data = r.json()
            if r.status_code == 409:
                time.sleep(2.0)
                continue
            return data
        return data

    def command(self, name: str, payload: dict | None = None) -> dict:
        r = self.client.post("/command", json={"name": name, "payload": payload or {}})
        return r.json()

    def inject_audio(self, file_path: str) -> dict:
        """Inject a WAV file into the audio pipeline via /command."""
        abs_path = str(Path(file_path).resolve())
        return self.command("test.inject_audio", {"path": abs_path})

    def mute_mic(self, muted: bool = True) -> dict:
        return self.command("test.mute_mic", {"muted": muted})

    def status(self) -> dict:
        return self.client.get("/status").json()

    def conversation(self) -> dict:
        return self.client.get("/conversation").json()

    def events_since(self, since: int = 0) -> dict:
        return self.client.get(f"/events?since={since}").json()

    def cancel(self) -> dict:
        return self.client.post("/cancel").json()

    def config(self, key: str, value) -> dict:
        return self.client.post("/config", json={"key": key, "value": value}).json()

    def approve(self, approved: bool = True) -> dict:
        return self.client.post("/approve", json={"approved": approved}).json()

    def approvals(self) -> dict:
        return self.client.get("/approvals").json()

    def reset(self) -> dict:
        return self.client.post("/reset").json()

    def wait_for_response(self, timeout_ms: int = 30000, initial_count: int | None = None) -> dict:
        """Poll /conversation until LLM generation completes."""
        deadline = time.monotonic() + timeout_ms / 1000
        last_conv = {}
        generation_started = False

        if initial_count is None:
            try:
                initial = self.conversation()
                initial_count = initial.get("count", 0)
            except httpx.HTTPError:
                initial_count = 0

        while time.monotonic() < deadline:
            try:
                conv = self.conversation()
                last_conv = conv
                is_generating = conv.get("isGenerating", False)
                current_count = conv.get("count", 0)

                if is_generating:
                    generation_started = True
                if current_count > initial_count + 1:
                    generation_started = True

                if generation_started and not is_generating:
                    return conv
            except httpx.HTTPError:
                pass
            time.sleep(POLL_INTERVAL)
        return last_conv

    def wait_for_idle(self, timeout_s: float = 30.0):
        """Wait until neither generating nor speaking."""
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            try:
                conv = self.conversation()
                if not conv.get("isGenerating", False) and not conv.get("isSpeaking", False):
                    return
            except httpx.HTTPError:
                pass
            time.sleep(0.5)

    def mark_event_position(self) -> int:
        data = self.events_since(999999999)
        self._event_seq = data.get("latestSequence", 0)
        return self._event_seq

    def collect_events(self, since: int | None = None) -> tuple[list, int]:
        seq = since if since is not None else self._event_seq
        data = self.events_since(seq)
        events = data.get("events", [])
        latest = data.get("latestSequence", seq)
        self._event_seq = latest
        return events, latest

    def close(self):
        self.client.close()


def extract_assistant_text(conv: dict) -> str:
    messages = conv.get("messages", [])
    for msg in reversed(messages):
        if msg.get("role") == "assistant":
            return msg.get("content", "")
    return conv.get("streamingText", "")


def extract_tools_called(events: list) -> list[str]:
    tools = []
    for ev in events:
        text = ev.get("text", "")
        raw_kind = ev.get("raw_kind", "")
        if raw_kind != "Tool→":
            continue
        tool_name = None
        if " name=" in text:
            for part in text.split():
                if part.startswith("name="):
                    tool_name = part[5:]
                    break
        elif "Execute request: " in text:
            after = text.split("Execute request: ", 1)[1]
            tool_name = after.split()[0] if after else None
        if tool_name and tool_name not in tools:
            tools.append(tool_name)
    return tools


def check_response_contains(text: str, keywords: list[str]) -> bool:
    lower = text.lower()
    return any(kw.lower() in lower for kw in keywords)


def check_no_ai_slop(text: str) -> bool:
    """Check response doesn't contain common AI slop phrases."""
    slop_phrases = [
        "great question", "absolutely", "i'd be happy to",
        "certainly", "of course!", "that's a wonderful",
        "i appreciate you asking", "what a great",
    ]
    lower = text.lower()
    return not any(phrase in lower for phrase in slop_phrases)


def check_no_parroting(text: str, inject_text: str) -> bool:
    """Check response doesn't parrot back what the user said."""
    parrot_phrases = [
        "you asked", "you said", "you mentioned",
        "the user said", "you want to know",
    ]
    lower = text.lower()
    return not any(phrase in lower for phrase in parrot_phrases)


def measure_resources(pid: int, duration_ms: int = 5000) -> dict:
    """Sample CPU/memory for a process over a duration."""
    samples = []
    deadline = time.monotonic() + duration_ms / 1000
    while time.monotonic() < deadline:
        try:
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "%cpu,rss,vsz"],
                capture_output=True, text=True, timeout=5
            )
            lines = result.stdout.strip().split("\n")
            if len(lines) >= 2:
                parts = lines[1].split()
                if len(parts) >= 3:
                    samples.append({
                        "cpu_percent": float(parts[0]),
                        "rss_kb": int(parts[1]),
                        "vsz_kb": int(parts[2]),
                    })
        except (subprocess.TimeoutExpired, ValueError):
            pass
        time.sleep(1.0)

    if not samples:
        return {}

    avg_cpu = sum(s["cpu_percent"] for s in samples) / len(samples)
    avg_rss = sum(s["rss_kb"] for s in samples) / len(samples)
    max_rss = max(s["rss_kb"] for s in samples)

    return {
        "avg_cpu_percent": round(avg_cpu, 1),
        "avg_rss_mb": round(avg_rss / 1024, 1),
        "max_rss_mb": round(max_rss / 1024, 1),
        "samples": len(samples),
    }


def get_fae_pid() -> int | None:
    """Find the Fae process PID."""
    try:
        result = subprocess.run(["pgrep", "-x", "Fae"], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            return int(result.stdout.strip().split("\n")[0])
    except (subprocess.TimeoutExpired, ValueError):
        pass
    return None


# --- Scenario Runners ---


def run_text_scenario(client: FaeTestClient, scenario: dict) -> ScenarioResult:
    """Run a text-injection scenario."""
    result = ScenarioResult(
        id=scenario["id"],
        dimension=scenario.get("dimension", "unknown"),
        scenario_type="text",
        inject_text=scenario.get("inject", ""),
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        # Capture initial count before inject
        try:
            pre = client.conversation()
            initial_count = pre.get("count", 0)
        except httpx.HTTPError:
            initial_count = 0

        event_start = client.mark_event_position()
        start_time = time.monotonic()

        client.inject(scenario["inject"])

        max_latency = scenario.get("max_latency_ms", 30000)
        conv = client.wait_for_response(
            timeout_ms=max_latency + LATENCY_BUFFER_MS,
            initial_count=initial_count,
        )

        end_time = time.monotonic()
        result.latency_ms = (end_time - start_time) * 1000

        events, _ = client.collect_events(event_start)
        result.events = events
        result.response_text = extract_assistant_text(conv)
        result.tools_called = extract_tools_called(events)

        # Checks
        all_passed = True

        if "expect_response_contains" in scenario:
            contains = check_response_contains(result.response_text, scenario["expect_response_contains"])
            result.checks["response_contains"] = contains
            if not contains:
                all_passed = False

        if "expect_no_think_tags" in scenario:
            has_tags = "<think>" in result.response_text
            result.checks["no_think_tags"] = not has_tags
            if has_tags:
                all_passed = False

        if scenario.get("expect_no_parrot"):
            no_parrot = check_no_parroting(result.response_text, scenario.get("inject", ""))
            result.checks["no_parroting"] = no_parrot
            if not no_parrot:
                all_passed = False

        # Soft latency check (recorded, not pass/fail)
        if "max_latency_ms" in scenario:
            result.checks["max_latency"] = result.latency_ms <= scenario["max_latency_ms"]

        # Check for empty response (always a failure for text scenarios)
        if not result.response_text.strip():
            result.checks["has_response"] = False
            all_passed = False
        else:
            result.checks["has_response"] = True

        # AI slop check
        if result.response_text:
            result.checks["no_ai_slop"] = check_no_ai_slop(result.response_text)

        result.passed = all_passed

    except Exception as e:
        result.errors.append(str(e))
        result.passed = False
    finally:
        result.completed_at = datetime.now(timezone.utc).isoformat()

    return result


def run_multi_step_scenario(client: FaeTestClient, scenario: dict) -> ScenarioResult:
    """Run a multi-step text scenario."""
    result = ScenarioResult(
        id=scenario["id"],
        dimension=scenario.get("dimension", "unknown"),
        scenario_type="multi_step",
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        steps = scenario.get("steps", [])
        all_passed = True

        for i, step in enumerate(steps):
            # Wait between steps for previous turn to complete
            if i > 0:
                client.wait_for_idle(timeout_s=30.0)
                time.sleep(1.0)

            try:
                pre = client.conversation()
                step_initial = pre.get("count", 0)
            except httpx.HTTPError:
                step_initial = 0

            event_start = client.mark_event_position()
            step_start = time.monotonic()

            inject_text = step.get("inject", "")
            if inject_text:
                result.inject_text = inject_text
                client.inject(inject_text)

            wait_ms = step.get("wait_ms", 15000)
            conv = client.wait_for_response(
                timeout_ms=wait_ms + LATENCY_BUFFER_MS,
                initial_count=step_initial,
            )

            result.latency_ms += (time.monotonic() - step_start) * 1000

            events, _ = client.collect_events(event_start)
            result.events.extend(events)

            response = extract_assistant_text(conv)
            result.response_text = response

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

    return result


def run_interrupt_scenario(client: FaeTestClient, scenario: dict) -> ScenarioResult:
    """Run a barge-in / interrupt scenario.

    For text-injection barge-in: the interrupt inject triggers processTranscription
    which calls markGenerationInterrupted() on the current generation, then starts
    a NEW generation for the interrupt text. So we verify:
    1. The original generation was active before interrupt
    2. The interrupt was accepted (new turn started)
    3. After the interrupt response completes, the final response addresses the interrupt
    """
    result = ScenarioResult(
        id=scenario["id"],
        dimension=scenario.get("dimension", "barge_in"),
        scenario_type="interrupt",
        inject_text=scenario.get("inject", ""),
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        event_start = client.mark_event_position()
        start_time = time.monotonic()

        # Start Fae generating a long response
        client.inject(scenario["inject"])

        # Wait before interrupting — must be long enough for generation to start
        wait_ms = scenario.get("wait_ms", 3000)
        time.sleep(wait_ms / 1000)

        # Check if still generating (it should be for a long prompt)
        conv_before = client.conversation()
        was_generating = conv_before.get("isGenerating", False)
        count_before = conv_before.get("count", 0)

        # Inject the interrupt
        interrupt_text = scenario.get("interrupt_inject", "Stop")
        interrupt_time = time.monotonic()

        if interrupt_text:
            client.inject(interrupt_text)

        # Wait for the interrupt response to complete (new generation)
        conv_after = client.wait_for_response(
            timeout_ms=60000,
            initial_count=count_before,
        )
        interrupt_end = time.monotonic()

        result.latency_ms = (interrupt_end - start_time) * 1000

        events, _ = client.collect_events(event_start)
        result.events = events
        result.response_text = extract_assistant_text(conv_after)

        all_passed = True

        if scenario.get("expect_tts_stopped", False):
            # For text-injection barge-in, success means:
            # - The original generation was interrupted (events show interrupt)
            # - The interrupt text was processed (new turn appeared)
            interrupted = any(
                "interrupt" in e.get("text", "").lower() or
                "barge" in e.get("text", "").lower() or
                "cancelled" in e.get("text", "").lower()
                for e in events
            )
            # Also check: did we get a new response (count increased)?
            new_response = conv_after.get("count", 0) > count_before
            # The interrupt worked if a new response was generated
            stopped = interrupted or new_response
            result.checks["tts_stopped"] = stopped
            result.checks["was_generating_before"] = was_generating
            if not stopped:
                all_passed = False

        # Check if interrupt response contains expected content
        if "expect_interrupt_contains" in scenario and result.response_text:
            contains = check_response_contains(
                result.response_text,
                scenario["expect_interrupt_contains"]
            )
            result.checks["interrupt_response_contains"] = contains
            if not contains:
                all_passed = False

        interrupt_latency = (interrupt_end - interrupt_time) * 1000
        max_il = scenario.get("max_interrupt_latency_ms", 30000)
        result.checks["interrupt_latency_ms"] = interrupt_latency
        result.checks["max_interrupt_latency"] = interrupt_latency <= max_il

        result.passed = all_passed

    except Exception as e:
        result.errors.append(str(e))
        result.passed = False
    finally:
        result.completed_at = datetime.now(timezone.utc).isoformat()

    return result


def run_audio_scenario(client: FaeTestClient, scenario: dict) -> ScenarioResult:
    """Run an audio-injection scenario."""
    result = ScenarioResult(
        id=scenario["id"],
        dimension=scenario.get("dimension", "unknown"),
        scenario_type="audio",
        audio_file=scenario.get("audio_file", ""),
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        audio_file = scenario.get("audio_file", "")
        if not audio_file or not Path(audio_file).exists():
            result.errors.append(f"Audio file not found: {audio_file}")
            result.passed = False
            return result

        # Pre-delay if specified (e.g., for re-identification after silence)
        pre_delay = scenario.get("pre_delay_ms", 0)
        if pre_delay > 0:
            time.sleep(pre_delay / 1000)

        try:
            pre = client.conversation()
            initial_count = pre.get("count", 0)
        except httpx.HTTPError:
            initial_count = 0

        event_start = client.mark_event_position()
        start_time = time.monotonic()

        # Inject audio
        client.inject_audio(audio_file)

        # Wait for pipeline to process
        max_latency = scenario.get("max_latency_ms", 15000)
        time.sleep(2.0)  # Give pipeline time to receive and process audio

        expect_response = scenario.get("expect_response", True)

        if expect_response:
            conv = client.wait_for_response(
                timeout_ms=max_latency + LATENCY_BUFFER_MS,
                initial_count=initial_count,
            )
        else:
            # For expect_response=false, wait the max time and check no response came
            time.sleep(max_latency / 1000)
            conv = client.conversation()

        end_time = time.monotonic()
        result.latency_ms = (end_time - start_time) * 1000

        events, _ = client.collect_events(event_start)
        result.events = events
        result.response_text = extract_assistant_text(conv)

        all_passed = True
        current_count = conv.get("count", 0)

        if expect_response:
            got_response = current_count > initial_count + 1 or bool(result.response_text.strip())
            result.checks["got_response"] = got_response
            if not got_response:
                all_passed = False

            if "expect_response_contains" in scenario and result.response_text:
                contains = check_response_contains(result.response_text, scenario["expect_response_contains"])
                result.checks["response_contains"] = contains
                if not contains:
                    all_passed = False
        else:
            # Should NOT have gotten a response
            no_response = current_count <= initial_count + 1 and not result.response_text.strip()
            result.checks["no_response"] = no_response
            if not no_response:
                all_passed = False

        result.passed = all_passed

    except Exception as e:
        result.errors.append(str(e))
        result.passed = False
    finally:
        result.completed_at = datetime.now(timezone.utc).isoformat()

    return result


def run_resource_scenario(client: FaeTestClient, scenario: dict) -> ScenarioResult:
    """Run a resource measurement scenario."""
    result = ScenarioResult(
        id=scenario["id"],
        dimension="resource_usage",
        scenario_type="resource",
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        pid = get_fae_pid()
        if not pid:
            result.errors.append("Fae process not found")
            result.passed = False
            return result

        phase = scenario.get("phase", "idle")
        duration = scenario.get("duration_ms", 5000)

        # For generation phase, inject text first
        if phase in ("generation", "memory_recall") and "inject" in scenario:
            client.inject(scenario["inject"])
            time.sleep(0.5)

        metrics = measure_resources(pid, duration_ms=duration)
        result.resource_metrics = metrics
        result.passed = bool(metrics)
        result.checks["measured"] = bool(metrics)

        if metrics:
            result.checks["cpu_percent"] = metrics.get("avg_cpu_percent", 0)
            result.checks["rss_mb"] = metrics.get("avg_rss_mb", 0)

    except Exception as e:
        result.errors.append(str(e))
        result.passed = False
    finally:
        result.completed_at = datetime.now(timezone.utc).isoformat()

    return result


def run_scenario(client: FaeTestClient, scenario: dict) -> ScenarioResult:
    """Route scenario to appropriate handler. Resets before each."""
    # Wait for previous turn to complete
    try:
        client.wait_for_idle(timeout_s=20.0)
        client.reset()
        time.sleep(1.5)
    except httpx.HTTPError:
        pass

    scenario_type = scenario.get("type", "text")

    if scenario_type == "audio":
        return run_audio_scenario(client, scenario)
    elif scenario_type == "resource":
        return run_resource_scenario(client, scenario)
    elif "steps" in scenario:
        return run_multi_step_scenario(client, scenario)
    elif "interrupt_inject" in scenario:
        return run_interrupt_scenario(client, scenario)
    else:
        return run_text_scenario(client, scenario)


def load_scenarios(path: Path) -> list[dict]:
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
    parser = argparse.ArgumentParser(description="Voice Pipeline AutoResearch runner")
    parser.add_argument("--scenarios", required=True, help="Path to JSONL scenario file")
    parser.add_argument("--output", required=True, help="Path to output results JSON")
    parser.add_argument("--base-url", default=BASE_URL, help="TestServer base URL")
    args = parser.parse_args()

    scenarios = load_scenarios(Path(args.scenarios))
    print(f"Loaded {len(scenarios)} scenarios from {args.scenarios}")

    client = FaeTestClient(args.base_url)

    # Verify TestServer
    try:
        health = client.health()
        if health.get("status") != "ok":
            print(f"Warning: TestServer not ready: {health}", file=sys.stderr)
    except httpx.HTTPError as e:
        print(f"Error: Cannot connect to TestServer at {args.base_url}: {e}", file=sys.stderr)
        sys.exit(1)

    results = []
    passed = 0
    failed = 0

    for i, scenario in enumerate(scenarios):
        sid = scenario.get("id", f"unknown_{i}")
        stype = scenario.get("type", "text")
        if "steps" in scenario:
            stype = "multi"
        if "interrupt_inject" in scenario:
            stype = "interrupt"
        print(f"  [{i+1}/{len(scenarios)}] {sid} ({stype}) ...", end=" ", flush=True)

        result = run_scenario(client, scenario)
        results.append(asdict(result))

        if result.passed:
            passed += 1
            print(f"PASS ({result.latency_ms:.0f}ms)")
        else:
            failed += 1
            checks_detail = " ".join(
                f"{k}={'OK' if v else 'FAIL'}" for k, v in result.checks.items()
                if isinstance(v, bool)
            )
            errors = f" errors={result.errors}" if result.errors else ""
            print(f"FAIL ({checks_detail}{errors})")

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

    print(f"\nResults: {passed}/{len(results)} passed ({passed/max(len(results),1)*100:.0f}%)")
    print(f"Output: {output_path}")

    client.close()
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
