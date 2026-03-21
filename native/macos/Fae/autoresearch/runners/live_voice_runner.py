# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx"]
# ///
"""Live voice autoresearch runner — speaks to Fae through speakers, monitors via TestServer.

Uses `voice` (Kokoro TTS CLI) or `say` to speak TO Fae through the Mac speakers.
Fae's mic picks it up and processes through the full pipeline:
  Mic → VAD → Speaker ID → Echo Suppression → Speech Verifier → STT → LLM → TTS → Speaker

This is a real end-to-end test — identical to a human user talking to Fae.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

_ssl_cert = os.environ.get("SSL_CERT_FILE", "")
if _ssl_cert and not os.path.exists(_ssl_cert):
    del os.environ["SSL_CERT_FILE"]

import httpx

BASE_URL = "http://127.0.0.1:7433"
DEFAULT_TIMEOUT = 90.0
POLL_INTERVAL = 0.3

# How long to wait after speaking for Fae to finish responding
RESPONSE_WAIT_S = 90.0
# How long to wait for Fae to START responding after we speak
ACTIVATION_WAIT_S = 30.0


@dataclass
class LiveResult:
    id: str
    dimension: str
    passed: bool = False
    # Timing
    speak_duration_ms: float = 0.0  # How long our TTS took
    activation_latency_ms: float = 0.0  # Time from speak-end to Fae starting generation
    response_latency_ms: float = 0.0  # Time from speak-end to Fae finishing response
    ttfa_ms: float = 0.0  # Time to first audio (from events)
    # Content
    spoken_text: str = ""
    response_text: str = ""
    events: list = field(default_factory=list)
    tools_called: list = field(default_factory=list)
    checks: dict = field(default_factory=dict)
    errors: list = field(default_factory=list)
    # Audio
    voice_used: str = ""
    speaker_decision: str = ""  # "accepted", "rejected", "unknown"
    started_at: str = ""
    completed_at: str = ""


class FaeClient:
    def __init__(self, base_url: str = BASE_URL):
        self.client = httpx.Client(base_url=base_url, timeout=DEFAULT_TIMEOUT)
        self._event_seq = 0

    def health(self) -> dict:
        return self.client.get("/health").json()

    def status(self) -> dict:
        return self.client.get("/status").json()

    def conversation(self) -> dict:
        return self.client.get("/conversation").json()

    def events_since(self, since: int = 0) -> dict:
        return self.client.get(f"/events?since={since}").json()

    def reset(self) -> dict:
        return self.client.post("/reset").json()

    def config(self, key: str, value) -> dict:
        return self.client.post("/config", json={"key": key, "value": value}).json()

    def mark_event_position(self) -> int:
        data = self.events_since(999999999)
        self._event_seq = data.get("latestSequence", 0)
        return self._event_seq

    def collect_events(self, since: int | None = None) -> list:
        seq = since if since is not None else self._event_seq
        data = self.events_since(seq)
        events = data.get("events", [])
        self._event_seq = data.get("latestSequence", seq)
        return events

    def wait_for_generation_start(self, timeout_s: float = ACTIVATION_WAIT_S) -> bool:
        """Wait for Fae to start generating (isGenerating=true or message count increases)."""
        deadline = time.monotonic() + timeout_s
        try:
            initial = self.conversation()
            initial_count = initial.get("count", 0)
        except httpx.HTTPError:
            initial_count = 0

        while time.monotonic() < deadline:
            try:
                conv = self.conversation()
                if conv.get("isGenerating", False):
                    return True
                if conv.get("count", 0) > initial_count:
                    return True
            except httpx.HTTPError:
                pass
            time.sleep(POLL_INTERVAL)
        return False

    def wait_for_idle(self, timeout_s: float = RESPONSE_WAIT_S) -> dict:
        """Wait until Fae is done generating AND speaking."""
        deadline = time.monotonic() + timeout_s
        last_conv = {}
        was_active = False

        while time.monotonic() < deadline:
            try:
                conv = self.conversation()
                last_conv = conv
                is_gen = conv.get("isGenerating", False)
                is_speak = conv.get("isSpeaking", False)

                if is_gen or is_speak:
                    was_active = True

                # Only return idle after we've seen activity
                if was_active and not is_gen and not is_speak:
                    return conv
            except httpx.HTTPError:
                pass
            time.sleep(POLL_INTERVAL)
        return last_conv

    def close(self):
        self.client.close()


def speak(text: str, voice_tool: str = "voice", voice_name: str | None = None) -> float:
    """Speak text through Mac speakers. Returns duration in ms."""
    start = time.monotonic()

    if voice_tool == "voice":
        # Kokoro TTS — high quality, Fae-like voice
        subprocess.run(
            ["voice", "-q", text],
            capture_output=True, timeout=30
        )
    elif voice_tool == "say":
        cmd = ["say"]
        if voice_name:
            cmd.extend(["-v", voice_name])
        cmd.append(text)
        subprocess.run(cmd, capture_output=True, timeout=30)
    else:
        raise ValueError(f"Unknown voice tool: {voice_tool}")

    duration_ms = (time.monotonic() - start) * 1000
    return duration_ms


def play_audio(file_path: str, duration_s: float | None = None) -> float:
    """Play an audio file through speakers. Returns duration in ms."""
    start = time.monotonic()
    cmd = ["afplay", file_path]
    if duration_s:
        cmd.extend(["-t", str(duration_s)])
    subprocess.run(cmd, capture_output=True, timeout=max(30, (duration_s or 10) + 5))
    return (time.monotonic() - start) * 1000


def extract_assistant_text(conv: dict) -> str:
    messages = conv.get("messages", [])
    for msg in reversed(messages):
        if msg.get("role") == "assistant":
            return msg.get("content", "")
    return ""


def extract_speaker_decision(events: list) -> str:
    """Check if speaker was accepted or rejected from events."""
    for ev in events:
        text = ev.get("text", "").lower()
        kind = ev.get("kind", "")
        if kind == "Speaker" or "speaker" in text:
            if "accepted" in text or "owner" in text or "verified" in text:
                return "accepted"
            if "rejected" in text or "ignored" in text or "unknown" in text:
                return "rejected"
    return "unknown"


def extract_ttfa(events: list) -> float:
    """Extract time-to-first-audio from TTS events (ms)."""
    for ev in events:
        text = ev.get("text", "")
        if "ttfa_ms=" in text:
            try:
                val = text.split("ttfa_ms=")[1].split()[0]
                return float(val)
            except (ValueError, IndexError):
                pass
        if "tts_first_chunk_latency_ms=" in text:
            try:
                val = text.split("tts_first_chunk_latency_ms=")[1].split()[0]
                return float(val)
            except (ValueError, IndexError):
                pass
    return 0.0


def check_contains(text: str, keywords: list[str]) -> bool:
    lower = text.lower()
    return any(kw.lower() in lower for kw in keywords)


# --- Scenario Runners ---


def run_speak_and_check(client: FaeClient, scenario: dict) -> LiveResult:
    """Core pattern: speak → wait for Fae → check response."""
    result = LiveResult(
        id=scenario["id"],
        dimension=scenario.get("dimension", "unknown"),
        spoken_text=scenario.get("speak", ""),
        voice_used=scenario.get("voice_tool", "voice"),
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        text = scenario["speak"]
        voice_tool = scenario.get("voice_tool", "voice")
        voice_name = scenario.get("voice_name")

        # Mark events before speaking
        event_start = client.mark_event_position()
        speak_start = time.monotonic()

        # Speak through speakers
        result.speak_duration_ms = speak(text, voice_tool=voice_tool, voice_name=voice_name)

        speak_end = time.monotonic()

        # Wait for Fae to activate (start generating)
        activated = client.wait_for_generation_start(timeout_s=ACTIVATION_WAIT_S)
        activation_end = time.monotonic()
        result.activation_latency_ms = (activation_end - speak_end) * 1000

        if activated:
            # Wait for Fae to finish responding (generation + TTS playback)
            conv = client.wait_for_idle(timeout_s=RESPONSE_WAIT_S)
            response_end = time.monotonic()
            result.response_latency_ms = (response_end - speak_end) * 1000
            result.response_text = extract_assistant_text(conv)
        else:
            result.response_latency_ms = (activation_end - speak_end) * 1000

        # Collect events
        result.events = client.collect_events(event_start)
        result.speaker_decision = extract_speaker_decision(result.events)
        result.ttfa_ms = extract_ttfa(result.events)

        # --- Checks ---
        all_passed = True

        # Response expected?
        expect_response = scenario.get("expect_response", True)
        got_response = bool(result.response_text.strip())

        if expect_response:
            result.checks["got_response"] = got_response
            if not got_response:
                all_passed = False

            if "expect_contains" in scenario and got_response:
                contains = check_contains(result.response_text, scenario["expect_contains"])
                result.checks["response_contains"] = contains
                if not contains:
                    all_passed = False
        else:
            # Should NOT have responded
            result.checks["correctly_silent"] = not got_response
            if got_response:
                all_passed = False

        # Speaker gate check
        if "expect_speaker" in scenario:
            expected = scenario["expect_speaker"]  # "accepted" or "rejected"
            result.checks["speaker_gate"] = result.speaker_decision == expected

        # Think tag leak
        if scenario.get("expect_no_think_tags", False):
            has_tags = "<think>" in result.response_text
            result.checks["no_think_tags"] = not has_tags
            if has_tags:
                all_passed = False

        # Latency check (soft)
        if "max_response_ms" in scenario:
            result.checks["within_latency"] = result.response_latency_ms <= scenario["max_response_ms"]

        result.passed = all_passed

    except Exception as e:
        result.errors.append(str(e))
        result.passed = False
    finally:
        result.completed_at = datetime.now(timezone.utc).isoformat()

    return result


def run_multi_turn(client: FaeClient, scenario: dict) -> LiveResult:
    """Multi-turn conversation: speak multiple times, check final response."""
    result = LiveResult(
        id=scenario["id"],
        dimension=scenario.get("dimension", "unknown"),
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        steps = scenario.get("steps", [])
        all_passed = True
        voice_tool = scenario.get("voice_tool", "voice")

        for i, step in enumerate(steps):
            # Wait for previous turn to finish
            if i > 0:
                client.wait_for_idle(timeout_s=RESPONSE_WAIT_S)
                time.sleep(1.0)

            text = step.get("speak", "")
            if not text:
                continue

            result.spoken_text = text
            event_start = client.mark_event_position()

            # Speak
            speak(text, voice_tool=voice_tool, voice_name=step.get("voice_name"))

            # Wait for response
            activated = client.wait_for_generation_start(timeout_s=ACTIVATION_WAIT_S)
            if activated:
                conv = client.wait_for_idle(timeout_s=RESPONSE_WAIT_S)
                response = extract_assistant_text(conv)
                result.response_text = response

                events = client.collect_events(event_start)
                result.events.extend(events)
            else:
                result.response_text = ""

            # Step-level checks
            if "expect_contains" in step:
                contains = check_contains(result.response_text, step["expect_contains"])
                result.checks[f"step_{i}_contains"] = contains
                if not contains:
                    all_passed = False

        result.passed = all_passed

    except Exception as e:
        result.errors.append(str(e))
        result.passed = False
    finally:
        result.completed_at = datetime.now(timezone.utc).isoformat()

    return result


def run_barge_in(client: FaeClient, scenario: dict) -> LiveResult:
    """Barge-in test: make Fae speak, then interrupt with voice."""
    result = LiveResult(
        id=scenario["id"],
        dimension=scenario.get("dimension", "barge_in"),
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        voice_tool = scenario.get("voice_tool", "voice")

        # Step 1: Make Fae start talking (long response)
        prompt = scenario["speak"]
        result.spoken_text = prompt
        event_start = client.mark_event_position()

        speak(prompt, voice_tool=voice_tool)

        # Wait for Fae to start generating
        activated = client.wait_for_generation_start(timeout_s=ACTIVATION_WAIT_S)
        if not activated:
            result.errors.append("Fae never started generating")
            result.passed = False
            return result

        # Step 2: Wait for Fae to start speaking (TTS playing)
        wait_for_speech_ms = scenario.get("wait_for_speech_ms", 5000)
        deadline = time.monotonic() + wait_for_speech_ms / 1000
        fae_was_speaking = False
        while time.monotonic() < deadline:
            conv = client.conversation()
            if conv.get("isSpeaking", False):
                fae_was_speaking = True
                break
            time.sleep(POLL_INTERVAL)

        if not fae_was_speaking:
            # Fae might have finished before we could interrupt
            result.checks["fae_was_speaking"] = False
            result.passed = False
            result.completed_at = datetime.now(timezone.utc).isoformat()
            return result

        result.checks["fae_was_speaking"] = True

        # Step 3: Wait the specified delay while Fae speaks
        interrupt_delay_ms = scenario.get("interrupt_delay_ms", 2000)
        time.sleep(interrupt_delay_ms / 1000)

        # Step 4: Interrupt! Speak over Fae
        interrupt_text = scenario.get("interrupt_speak", "Stop")
        interrupt_start = time.monotonic()

        speak(interrupt_text, voice_tool=voice_tool)

        # Step 5: Check if Fae stopped speaking
        time.sleep(1.0)
        conv_after = client.conversation()
        interrupt_end = time.monotonic()

        stopped = not conv_after.get("isSpeaking", True)
        result.checks["fae_stopped"] = stopped

        result.response_latency_ms = (interrupt_end - interrupt_start) * 1000

        # Collect events for analysis
        result.events = client.collect_events(event_start)
        result.response_text = extract_assistant_text(conv_after)

        # If we spoke a new question, wait for Fae's response to THAT
        if scenario.get("expect_redirect_response"):
            client.wait_for_generation_start(timeout_s=15.0)
            conv_final = client.wait_for_idle(timeout_s=RESPONSE_WAIT_S)
            result.response_text = extract_assistant_text(conv_final)

            if "expect_contains" in scenario:
                contains = check_contains(result.response_text, scenario["expect_contains"])
                result.checks["redirect_response"] = contains

        result.passed = stopped  # Primary check: did Fae stop?

    except Exception as e:
        result.errors.append(str(e))
        result.passed = False
    finally:
        result.completed_at = datetime.now(timezone.utc).isoformat()

    return result


def run_noise_test(client: FaeClient, scenario: dict) -> LiveResult:
    """Noise rejection: play noise/music, verify Fae doesn't activate."""
    result = LiveResult(
        id=scenario["id"],
        dimension=scenario.get("dimension", "noise_resilience"),
        started_at=datetime.now(timezone.utc).isoformat(),
    )

    try:
        noise_file = scenario.get("noise_file", "")
        noise_duration = scenario.get("noise_duration_s", 5)

        event_start = client.mark_event_position()

        try:
            pre_conv = client.conversation()
            initial_count = pre_conv.get("count", 0)
        except httpx.HTTPError:
            initial_count = 0

        # Play noise
        if noise_file and Path(noise_file).exists():
            play_audio(noise_file, duration_s=noise_duration)
        else:
            # Generate noise with say (background chatter)
            noise_text = scenario.get("noise_text", "The weather today is partly cloudy with a high of 15 degrees")
            noise_voice = scenario.get("noise_voice", "Samantha")
            speak(noise_text, voice_tool="say", voice_name=noise_voice)

        # Wait a moment, then check if Fae activated
        time.sleep(3.0)
        conv = client.conversation()
        current_count = conv.get("count", 0)

        result.events = client.collect_events(event_start)

        # Check: Fae should NOT have responded
        no_activation = current_count <= initial_count
        result.checks["no_activation"] = no_activation
        result.passed = no_activation

        if not no_activation:
            result.response_text = extract_assistant_text(conv)

    except Exception as e:
        result.errors.append(str(e))
        result.passed = False
    finally:
        result.completed_at = datetime.now(timezone.utc).isoformat()

    return result


def run_scenario(client: FaeClient, scenario: dict) -> LiveResult:
    """Route to appropriate handler. Reset between scenarios."""
    # Wait for any previous activity to finish
    try:
        client.wait_for_idle(timeout_s=15.0)
        client.reset()
        time.sleep(2.0)  # Let pipeline fully settle after reset
    except httpx.HTTPError:
        pass

    scenario_type = scenario.get("type", "speak")

    if scenario_type == "multi_turn":
        return run_multi_turn(client, scenario)
    elif scenario_type == "barge_in":
        return run_barge_in(client, scenario)
    elif scenario_type == "noise":
        return run_noise_test(client, scenario)
    else:
        return run_speak_and_check(client, scenario)


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
    parser = argparse.ArgumentParser(description="Live Voice AutoResearch Runner")
    parser.add_argument("--scenarios", required=True, help="JSONL scenario file")
    parser.add_argument("--output", required=True, help="Output results JSON")
    parser.add_argument("--base-url", default=BASE_URL)
    args = parser.parse_args()

    scenarios = load_scenarios(Path(args.scenarios))
    print(f"Loaded {len(scenarios)} live voice scenarios from {args.scenarios}")
    print(f"NOTE: This test speaks through your Mac speakers. Turn volume up!\n")

    client = FaeClient(args.base_url)

    try:
        health = client.health()
        if health.get("status") != "ok":
            print(f"Error: Fae not ready: {health}", file=sys.stderr)
            sys.exit(1)
    except httpx.HTTPError as e:
        print(f"Error: Cannot connect: {e}", file=sys.stderr)
        sys.exit(1)

    results = []
    passed = 0
    failed = 0

    for i, scenario in enumerate(scenarios):
        sid = scenario.get("id", f"unknown_{i}")
        stype = scenario.get("type", "speak")
        print(f"  [{i+1}/{len(scenarios)}] {sid} ({stype})", end=" ", flush=True)
        print(f"— speaking: \"{scenario.get('speak', scenario.get('steps', [{}])[0].get('speak', ''))[:50]}\"")

        result = run_scenario(client, scenario)
        results.append(asdict(result))

        status = "PASS" if result.passed else "FAIL"
        timing = f"speak={result.speak_duration_ms:.0f}ms"
        if result.activation_latency_ms > 0:
            timing += f" activate={result.activation_latency_ms:.0f}ms"
        if result.response_latency_ms > 0:
            timing += f" response={result.response_latency_ms:.0f}ms"
        if result.ttfa_ms > 0:
            timing += f" ttfa={result.ttfa_ms:.0f}ms"

        checks_str = " ".join(
            f"{k}={'OK' if v else 'FAIL'}" for k, v in result.checks.items()
            if isinstance(v, bool)
        )

        print(f"    → {status} ({timing})")
        if checks_str:
            print(f"      checks: {checks_str}")
        if result.response_text:
            print(f"      Fae said: \"{result.response_text[:80]}\"")
        if result.errors:
            print(f"      errors: {result.errors}")
        print()

    total_passed = sum(1 for r in results if r["passed"])
    output = {
        "run_at": datetime.now(timezone.utc).isoformat(),
        "runner": "live_voice",
        "scenario_file": args.scenarios,
        "total": len(results),
        "passed": total_passed,
        "failed": len(results) - total_passed,
        "pass_rate": total_passed / max(len(results), 1),
        "results": results,
    }

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2, default=str)

    print(f"\n{'='*60}")
    print(f"Results: {passed}/{len(results)} passed ({passed/max(len(results),1)*100:.0f}%)")
    print(f"Output: {output_path}")

    client.close()


if __name__ == "__main__":
    main()
