#!/usr/bin/env python3
"""
Compare 9B tool-calling through local OpenAI-compatible servers.

This benchmarks:
- standard MLX server with mlx-community/Qwen3.5-9B-4bit
- ParoQuant MLX server with z-lab/Qwen3.5-9B-PARO

The goal is to measure actual tool-call selection, which the direct sidecar
text benchmark cannot cover.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CORPUS = PROJECT_ROOT / "scripts" / "benchmark-results" / "qwen3.5-9b_20260313-172928.json"
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "scripts" / "benchmark-results"

TOOL_CALLING_SYSTEM_PROMPT = (
    "You are Fae, a personal AI companion running on macOS. When the user's request requires a tool, "
    "call the appropriate tool. For simple conversation, just respond directly without tools.\n\n"
    "Tool usage:\n"
    "- Calendar, reminders, mail, contacts, notes queries: ALWAYS call the relevant tool. Do NOT answer from memory.\n"
    "- Real-time data, file access, and web lookups: use the appropriate tool.\n"
    "- If tools are provided, call them using the model's native tool-calling format.\n"
    "- Qwen-family models may emit XML function calls.\n"
    "- After a tool result, respond naturally in spoken language.\n"
    "- For simple conversation, just respond directly without tools.\n"
    "- Keep spoken responses concise (1-4 sentences).\n"
    "- NEVER expose raw tool call markup, JSON, or code to the user."
)

VALID_TOOLS = {
    "calendar",
    "reminders",
    "contacts",
    "mail",
    "notes",
    "web_search",
    "read",
    "write",
    "bash",
}

TOOL_DEFS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "calendar",
            "description": "Access macOS Calendar events.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string"},
                    "query": {"type": "string"},
                    "date": {"type": "string"},
                },
                "required": ["action"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "reminders",
            "description": "Access macOS Reminders.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string"},
                    "title": {"type": "string"},
                    "query": {"type": "string"},
                },
                "required": ["action"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "contacts",
            "description": "Search macOS Contacts.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string"},
                    "query": {"type": "string"},
                },
                "required": ["action", "query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mail",
            "description": "Interact with macOS Mail.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string"},
                    "query": {"type": "string"},
                    "to": {"type": "string"},
                    "subject": {"type": "string"},
                    "body": {"type": "string"},
                },
                "required": ["action"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "notes",
            "description": "Search macOS Notes.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string"},
                    "query": {"type": "string"},
                    "title": {"type": "string"},
                },
                "required": ["action"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the web for current information.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read",
            "description": "Read a local file from disk.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write",
            "description": "Write a local file to disk.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "bash",
            "description": "Run a shell command.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string"},
                },
                "required": ["command"],
            },
        },
    },
]


def find_free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def http_json(method: str, url: str, payload: dict[str, Any] | None = None, timeout: float = 30.0) -> dict[str, Any]:
    body = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


class ServerHarness:
    def __init__(
        self,
        label: str,
        model_id: str,
        command: list[str],
        log_path: Path,
        request_model_id: str | None = None,
    ) -> None:
        self.label = label
        self.model_id = model_id
        self.command = command
        self.log_path = log_path
        self.request_model_id = request_model_id or model_id
        self.process: subprocess.Popen[str] | None = None
        self.port = int(command[command.index("--port") + 1])

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def start(self, timeout_s: float = 180.0) -> None:
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        log_handle = self.log_path.open("w")
        self.process = subprocess.Popen(
            self.command,
            cwd=str(PROJECT_ROOT),
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            text=True,
        )

        deadline = time.time() + timeout_s
        last_error = "server did not become ready"
        while time.time() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(
                    f"{self.label} server exited early with code {self.process.returncode}; "
                    f"see {self.log_path}"
                )
            try:
                http_json("GET", f"{self.base_url}/v1/models", timeout=5.0)
                return
            except Exception as exc:  # noqa: BLE001
                last_error = str(exc)
                time.sleep(1.0)

        raise RuntimeError(f"{self.label} server failed to start: {last_error}; see {self.log_path}")

    def stop(self) -> None:
        if self.process is None:
            return
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.process = None


def load_tool_corpus(path: Path) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text())
    return payload["models"][0]["tool_calling"]


def extract_tool_from_content(output: str) -> tuple[str, str]:
    if "<tool_call>" in output:
        name_match = re.search(r'"name"\s*:\s*"([^"]+)"', output)
        if name_match:
            candidate = name_match.group(1)
            if candidate in VALID_TOOLS:
                return candidate, "raw_tool_call_json"

    xml_match = re.search(r"<function=([A-Za-z_][A-Za-z0-9_]*)>", output)
    if xml_match:
        candidate = xml_match.group(1)
        if candidate in VALID_TOOLS:
            return candidate, "raw_qwen_xml"

    liquid_match = re.search(r"<\|tool_call_start\|>\s*\[\s*([A-Za-z_][A-Za-z0-9_]*)\(", output)
    if liquid_match:
        candidate = liquid_match.group(1)
        if candidate in VALID_TOOLS:
            return candidate, "raw_liquid_pythonic"

    loose_match = re.search(r"""["']name["']\s*:\s*["'](\w+)["']""", output)
    if loose_match:
        candidate = loose_match.group(1)
        if candidate in VALID_TOOLS:
            return candidate, "raw_name_field"

    return "none", "none"


def run_tool_suite(server: ServerHarness, corpus: list[dict[str, Any]]) -> dict[str, Any]:
    results: list[dict[str, Any]] = []

    for test in corpus:
        payload = {
            "model": server.request_model_id,
            "messages": [
                {"role": "system", "content": TOOL_CALLING_SYSTEM_PROMPT},
                {"role": "user", "content": test["prompt"]},
            ],
            "tools": TOOL_DEFS,
            "tool_choice": "auto",
            "stream": False,
            "temperature": 0.0,
            "top_p": 1.0,
            "max_tokens": 512,
            "chat_template_kwargs": {"enable_thinking": False},
        }
        response = http_json("POST", f"{server.base_url}/v1/chat/completions", payload=payload, timeout=120.0)
        choice = response["choices"][0]["message"]
        output = (choice.get("content") or "").strip()
        raw_preview = output[:300].replace("\n", "\\n")

        actual = "none"
        source = "none"

        tool_calls = choice.get("tool_calls") or []
        if tool_calls:
            function = tool_calls[0].get("function") or {}
            candidate = function.get("name") or "none"
            if candidate in VALID_TOOLS:
                actual = candidate
                source = "api_tool_call"

        if actual == "none":
            actual, source = extract_tool_from_content(output)

        correct = actual == test["expected_tool"]
        results.append(
            {
                "prompt": test["prompt"],
                "expected_tool": test["expected_tool"],
                "actual_tool": actual,
                "tool_call_source": source,
                "correct": correct,
                "raw_response_preview": raw_preview,
            }
        )

    score = sum(1 for row in results if row["correct"])
    return {
        "runner": server.label,
        "model_id": server.model_id,
        "score": score,
        "total": len(results),
        "results": results,
        "log_path": str(server.log_path),
    }


def build_server_command(kind: str, model_id: str, port: int, adapter_path: str | None = None) -> list[str]:
    uv = shutil.which("uv")
    if not uv:
        raise RuntimeError("uv is required on PATH")

    base = [uv, "run", "--python", "3.12", "--with", "mlx-lm", "--with", "paroquant[mlx]", "python", "-m"]
    if kind == "standard":
        command = base + ["mlx_lm.server", "--model", model_id, "--host", "127.0.0.1", "--port", str(port)]
        if adapter_path:
            command += ["--adapter-path", adapter_path]
        return command
    if kind == "paro":
        return base + ["paroquant.cli.serve", "--model", model_id, "--host", "127.0.0.1", "--port", str(port)]
    raise ValueError(f"Unsupported server kind: {kind}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark 9B tool-calling via local OpenAI-compatible servers")
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--standard-model", default="mlx-community/Qwen3.5-9B-4bit")
    parser.add_argument("--standard-adapter-path", default=None)
    parser.add_argument("--standard-label", default="standard_mlx_server")
    parser.add_argument("--paro-model", default="z-lab/Qwen3.5-9B-PARO")
    parser.add_argument("--paro-label", default="paroquant_server")
    args = parser.parse_args()

    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    tmp_dir = Path(tempfile.mkdtemp(prefix="fae-qwen9b-tool-server-"))

    corpus = load_tool_corpus(args.corpus)

    standard_port = find_free_port()
    paro_port = find_free_port()

    standard = ServerHarness(
        label=args.standard_label,
        model_id=args.standard_model,
        command=build_server_command("standard", args.standard_model, standard_port, args.standard_adapter_path),
        log_path=tmp_dir / f"standard-{stamp}.log",
        request_model_id=args.standard_model,
    )
    paro = ServerHarness(
        label=args.paro_label,
        model_id=args.paro_model,
        command=build_server_command("paro", args.paro_model, paro_port),
        log_path=tmp_dir / f"paro-{stamp}.log",
    )

    try:
        standard.start()
        standard_results = run_tool_suite(standard, corpus)
    finally:
        standard.stop()

    try:
        paro.start()
        paro_results = run_tool_suite(paro, corpus)
    finally:
        paro.stop()

    comparison = {
        "date": datetime.now().isoformat(timespec="seconds"),
        "reference_corpus": str(args.corpus),
        args.standard_label: f"{standard_results['score']}/{standard_results['total']}",
        args.paro_label: f"{paro_results['score']}/{paro_results['total']}",
        "models": [standard_results, paro_results],
    }

    out_path = output_dir / f"qwen35-9b-toolcalling-mlx-vs-paro_{stamp}.json"
    out_path.write_text(json.dumps(comparison, indent=2))
    print(out_path)


if __name__ == "__main__":
    main()
