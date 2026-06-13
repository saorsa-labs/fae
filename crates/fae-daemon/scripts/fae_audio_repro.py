#!/usr/bin/env python3
"""Live repro for fae-daemon audio NDJSON commands.

Starts after fae-daemon is already running. Reads bootstrap token from the
selected HOME/data dir, then runs:
  authenticate -> audio.devices -> capture_start -> sleep -> capture_stop
  -> save WAV -> audio.play -> conversation.inject_text(audio) -> tts.synthesize
  -> audio.play(tts)
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import sys
import time
import wave
from pathlib import Path

PROTOCOL_VERSION = 2
CLIENT_ID = "swift-frontend-bootstrap"


def data_run_dir(home: Path) -> Path:
    if sys.platform == "darwin":
        return home / "Library" / "Application Support" / "fae" / "run"
    return Path(os.environ.get("XDG_DATA_HOME", home / ".local" / "share")) / "fae" / "run"


class Client:
    def __init__(self, socket_path: Path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(str(socket_path))
        self.file = self.sock.makefile("rwb", buffering=0)
        self.next_id = 1

    def command(self, command: str, payload: dict | None = None) -> dict:
        request_id = f"r{self.next_id}"
        self.next_id += 1
        frame = {
            "v": PROTOCOL_VERSION,
            "request_id": request_id,
            "command": command,
            "payload": payload or {},
        }
        self.file.write((json.dumps(frame) + "\n").encode())
        line = self.file.readline()
        if not line:
            raise RuntimeError("daemon closed socket")
        response = json.loads(line)
        print(f"{command} -> {json.dumps(response, sort_keys=True)[:900]}")
        return response


def require_ok(response: dict) -> dict:
    if not response.get("ok"):
        raise RuntimeError(response)
    return response.get("result") or {}


def validate_wav(path: Path) -> None:
    with wave.open(str(path), "rb") as wav:
        print(
            "saved_wav -> "
            f"channels={wav.getnchannels()} rate={wav.getframerate()} "
            f"frames={wav.getnframes()} duration={wav.getnframes() / wav.getframerate():.3f}s"
        )
        if wav.getnchannels() != 1 or wav.getframerate() != 16_000:
            raise RuntimeError("captured WAV is not 16 kHz mono")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", default=os.environ.get("HOME", ""))
    parser.add_argument("--out", default="/tmp/fae-cpal-capture.wav")
    parser.add_argument("--capture-seconds", type=float, default=3.0)
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    run_dir = data_run_dir(home)
    token = (run_dir / "bootstrap.token").read_text().strip()
    client = Client(run_dir / "fae-daemon.sock")
    require_ok(
        client.command(
            "session.authenticate", {"client_id": CLIENT_ID, "token": token}
        )
    )
    require_ok(client.command("audio.devices"))
    capture_id = require_ok(client.command("audio.capture_start"))["capture_id"]
    print(f"Speak now for {args.capture_seconds:.1f}s...")
    time.sleep(args.capture_seconds)
    captured = require_ok(client.command("audio.capture_stop", {"capture_id": capture_id}))
    wav_bytes = base64.b64decode(captured["wav_base64"])
    out = Path(args.out)
    out.write_bytes(wav_bytes)
    validate_wav(out)
    require_ok(client.command("audio.play", {"wav_base64": captured["wav_base64"]}))
    heard = require_ok(
        client.command(
            "conversation.inject_text",
            {
                "system": (
                    "The next user message contains an audio clip and "
                    "intentionally has empty text content. You MUST listen to "
                    "the attached WAV audio, transcribe the speech, and output "
                    "exactly one line beginning '[heard]: ' followed by the "
                    "transcript. Do not output an empty string."
                ),
                "messages": [
                    {
                        "role": "user",
                        "content": "",
                        "audio_wav_base64": captured["wav_base64"],
                    }
                ],
                "max_tokens": 128,
            },
        )
    )
    print(f"heard_turn -> {json.dumps(heard, sort_keys=True)}")
    tts = require_ok(client.command("tts.synthesize", {"text": heard.get("text", "hello")}))
    require_ok(client.command("audio.play", {"wav_base64": tts["wav_base64"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
