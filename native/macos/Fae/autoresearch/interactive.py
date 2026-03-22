# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx"]
# ///
"""Interactive Fae testing helper — used by Claude to have real conversations with Fae.

Usage from command line:
  uv run autoresearch/interactive.py setup          # Launch Fae, enroll, warmup
  uv run autoresearch/interactive.py say "Hello"    # Speak to Fae via audio injection
  uv run autoresearch/interactive.py noise "path"   # Play noise audio (should NOT trigger)
  uv run autoresearch/interactive.py stranger "Hi"  # Speak as stranger (should be rejected)
  uv run autoresearch/interactive.py status         # Show conversation state
  uv run autoresearch/interactive.py reset          # Reset conversation
  uv run autoresearch/interactive.py screenshot     # Take and report screenshot
  uv run autoresearch/interactive.py shutdown       # Kill Fae
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

_ssl_cert = os.environ.get("SSL_CERT_FILE", "")
if _ssl_cert and not os.path.exists(_ssl_cert):
    del os.environ["SSL_CERT_FILE"]

import httpx

BASE = "http://127.0.0.1:7433"
CLIENT = httpx.Client(base_url=BASE, timeout=90.0)
ENROLL_DIR = Path(__file__).parent / "audio" / "enrollment_voice"
FAE_APP = Path(__file__).parent.parent.parent.parent.parent / "Fae.app" / "Contents" / "MacOS" / "Fae"


def _voice_to_wav(text: str, output: str, voice: str = "am_adam"):
    """Generate speech with Kokoro voice CLI and convert to 16kHz mono WAV."""
    raw = output.replace(".wav", "_raw.wav")
    subprocess.run(["voice", "-v", voice, "-q", "-o", raw, text], capture_output=True, timeout=30)
    subprocess.run(
        ["ffmpeg", "-y", "-i", raw, "-ar", "16000", "-ac", "1", output],
        capture_output=True, timeout=15,
    )
    Path(raw).unlink(missing_ok=True)


def _wait_idle(timeout_s=90, min_count=0):
    """Wait until Fae finishes generating AND speaking."""
    deadline = time.monotonic() + timeout_s
    was_active = False
    while time.monotonic() < deadline:
        try:
            conv = CLIENT.get("/conversation").json()
            gen = conv.get("isGenerating", False)
            spk = conv.get("isSpeaking", False)
            cnt = conv.get("count", 0)
            if gen or spk:
                was_active = True
            if was_active and not gen and not spk and cnt >= min_count:
                return conv
        except httpx.HTTPError:
            pass
        time.sleep(0.5)
    return CLIENT.get("/conversation").json()


def _get_response(conv):
    for m in reversed(conv.get("messages", [])):
        if m.get("role") == "assistant":
            return m.get("content", "")
    return ""


def _get_transcription(conv):
    for m in conv.get("messages", []):
        if m.get("role") == "user":
            return m.get("content", "")
    return ""


def _get_speaker_events():
    try:
        data = CLIENT.get("/events?since=0").json()
        results = []
        for e in data.get("events", []):
            txt = e.get("text", "")
            if "Matched" in txt or "rejected" in txt.lower() or "fae_self" in txt.lower():
                results.append(txt[:200])
        return results
    except httpx.HTTPError:
        return []


def cmd_setup():
    """Launch Fae, enroll, configure, warmup."""
    # Kill any existing
    subprocess.run(["pkill", "-x", "Fae"], capture_output=True)
    time.sleep(1)

    # Clear speakers
    speakers_path = Path.home() / "Library" / "Application Support" / "fae" / "speakers.json"
    speakers_path.write_text("[]")

    # Launch
    env = {**os.environ, "FAE_TEST_SERVER": "1", "FAE_DISABLE_STREAMING_ASR": "1"}
    log = open("/tmp/fae-interactive.log", "w")
    proc = subprocess.Popen(
        [str(FAE_APP), "--test-server"],
        env=env, stdout=log, stderr=log,
    )
    print(f"Fae PID: {proc.pid}")

    # Wait for ready
    for i in range(90):
        try:
            h = CLIENT.get("/health").json()
            if h.get("status") == "ok":
                print(f"Ready after {i*2}s")
                break
        except httpx.HTTPError:
            pass
        time.sleep(2)
    else:
        print("ERROR: Fae not ready after 180s")
        return

    # Enroll
    files = [str(ENROLL_DIR / f"male_enroll_{i}_16k.wav") for i in range(1, 4)]
    existing = [f for f in files if Path(f).exists()]
    if not existing:
        print("ERROR: No enrollment audio files found")
        return
    CLIENT.post("/command", json={
        "name": "test.enroll_owner",
        "payload": {"name": "David", "audio_files": existing},
    })
    time.sleep(4)
    print("Enrolled owner")

    # Configure — disable proactive features that hijack conversation
    for key, val in [
        ("awareness.enabled", False),
        ("awareness.camera_enabled", False),
        ("awareness.screen_enabled", False),
        ("awareness.enhanced_briefing", False),
        ("conversation.require_direct_address", False),
    ]:
        CLIENT.post("/config", json={"key": key, "value": val})

    # Wait for enrollment TTS ("Thanks, David") to finish playing
    time.sleep(6)

    # Warmup LLM (compiles Metal shaders on first inference)
    print("Warming up LLM...")
    CLIENT.post("/inject", json={"text": "Hi"})
    _wait_idle(timeout_s=60, min_count=2)
    CLIENT.post("/reset")
    time.sleep(3)
    print("Ready for conversation.")


def cmd_say(text: str):
    """Speak to Fae as the owner. Returns transcription + response."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        wav_path = f.name

    _voice_to_wav(text, wav_path)

    # Get initial state
    try:
        pre = CLIENT.get("/conversation").json()
        pre_count = pre.get("count", 0)
    except httpx.HTTPError:
        pre_count = 0

    event_mark = CLIENT.get("/events?since=999999999").json().get("latestSequence", 0)
    start = time.monotonic()

    # Inject
    CLIENT.post("/command", json={"name": "test.inject_audio", "payload": {"path": wav_path}})

    # Wait for response
    conv = _wait_idle(timeout_s=90, min_count=pre_count + 2)
    elapsed = time.monotonic() - start

    transcription = _get_transcription(conv)
    response = _get_response(conv)
    speaker_events = _get_speaker_events()

    Path(wav_path).unlink(missing_ok=True)

    print(f"\n{'='*60}")
    print(f"SPOKE: \"{text}\"")
    print(f"STT:   \"{transcription}\"")
    print(f"FAE:   \"{response}\"")
    print(f"TIME:  {elapsed:.1f}s")
    if speaker_events:
        print(f"SPEAKER: {speaker_events[-1]}")
    print(f"{'='*60}\n")


def cmd_stranger(text: str):
    """Speak as a stranger voice. Should be rejected."""
    # Use a different voice style — we can't easily change Kokoro voice,
    # so we use the pre-generated stranger audio if available.
    stranger_dir = Path(__file__).parent / "audio" / "stranger"
    if stranger_dir.exists():
        wavs = list(stranger_dir.glob("*.wav"))
        if wavs:
            wav = str(wavs[0])
            print(f"Using stranger audio: {wav}")
            try:
                pre = CLIENT.get("/conversation").json()
                pre_count = pre.get("count", 0)
            except httpx.HTTPError:
                pre_count = 0

            CLIENT.post("/command", json={"name": "test.inject_audio", "payload": {"path": wav}})
            time.sleep(10)
            conv = CLIENT.get("/conversation").json()
            post_count = conv.get("count", 0)
            responded = post_count > pre_count

            speaker_events = _get_speaker_events()
            print(f"Stranger spoke. Fae responded: {responded}")
            if speaker_events:
                print(f"Speaker decision: {speaker_events[-1]}")
            if responded:
                print(f"FAIL — Fae should NOT respond to strangers")
            else:
                print(f"PASS — Fae correctly ignored stranger")
            return

    print("No stranger audio found. Generate with: bash autoresearch/generate_audio.sh")


def cmd_noise(path: str = ""):
    """Play noise audio. Should NOT trigger Fae."""
    if not path:
        noise_dir = Path(__file__).parent / "audio" / "noise"
        wavs = list(noise_dir.glob("*.wav")) if noise_dir.exists() else []
        if wavs:
            path = str(wavs[0])
        else:
            print("No noise files found")
            return

    try:
        pre = CLIENT.get("/conversation").json()
        pre_count = pre.get("count", 0)
    except httpx.HTTPError:
        pre_count = 0

    CLIENT.post("/command", json={"name": "test.inject_audio", "payload": {"path": path}})
    time.sleep(8)
    conv = CLIENT.get("/conversation").json()
    post_count = conv.get("count", 0)
    responded = post_count > pre_count

    print(f"Noise: {Path(path).name}")
    if responded:
        print(f"FAIL — Fae activated on noise (should stay silent)")
    else:
        print(f"PASS — Fae correctly ignored noise")


def cmd_status():
    """Show current conversation state."""
    conv = CLIENT.get("/conversation").json()
    print(f"Messages: {conv.get('count', 0)}  Gen: {conv.get('isGenerating')}  Speak: {conv.get('isSpeaking')}")
    for m in conv.get("messages", []):
        print(f"  [{m['role']}] {m.get('content', '')[:300]}")


def cmd_reset():
    CLIENT.post("/cancel")
    time.sleep(1)
    CLIENT.post("/reset")
    time.sleep(2)
    print("Conversation reset")


def cmd_screenshot():
    subprocess.run(["screencapture", "-x", "/tmp/fae-screenshot.png"], capture_output=True)
    print("Screenshot: /tmp/fae-screenshot.png")


def cmd_shutdown():
    subprocess.run(["pkill", "-x", "Fae"], capture_output=True)
    print("Fae killed")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(0)

    cmd = sys.argv[1]
    arg = " ".join(sys.argv[2:]) if len(sys.argv) > 2 else ""

    match cmd:
        case "setup":
            cmd_setup()
        case "say":
            if not arg:
                print("Usage: interactive.py say \"Hello Fae\"")
            else:
                cmd_say(arg)
        case "stranger":
            cmd_stranger(arg)
        case "noise":
            cmd_noise(arg)
        case "status":
            cmd_status()
        case "reset":
            cmd_reset()
        case "screenshot":
            cmd_screenshot()
        case "shutdown":
            cmd_shutdown()
        case _:
            print(f"Unknown command: {cmd}")
            print(__doc__)
