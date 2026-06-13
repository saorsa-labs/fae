#!/usr/bin/env python3
"""Fae executable skill wrapper for the Himalaya mail CLI."""

import email.utils
import json
import os
import shutil
import subprocess
import sys
from typing import Any


MAX_COUNT = 25
TIMEOUT_SECONDS = 90


def read_request() -> dict[str, Any]:
    payload = sys.stdin.read().strip()
    if not payload:
        raise ValueError("empty request")
    request = json.loads(payload)
    params = request.get("params") or {}
    if not isinstance(params, dict):
        raise ValueError("params must be an object")
    return params


def emit(result: dict[str, Any], status: int = 0) -> int:
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return status


def safe_count(value: Any, default: int = 5) -> int:
    try:
        count = int(value)
    except (TypeError, ValueError):
        count = default
    return max(1, min(MAX_COUNT, count))


def himalaya_binary() -> str | None:
    return shutil.which("himalaya")


def run_himalaya(args: list[str], *, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
    binary = himalaya_binary()
    if binary is None:
        raise FileNotFoundError("himalaya binary not found")
    return subprocess.run(
        [binary, *args],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=TIMEOUT_SECONDS,
        check=False,
        env=os.environ.copy(),
    )


def run_with_account_variants(account: Any, args: list[str]) -> subprocess.CompletedProcess[str]:
    account_name = str(account or "").strip()
    variants: list[list[str]] = []
    if account_name:
        variants.append(["--account", account_name, *args])
        variants.append(["-a", account_name, *args])
    variants.append(args)

    last: subprocess.CompletedProcess[str] | None = None
    for variant in variants:
        result = run_himalaya(variant)
        if result.returncode == 0:
            return result
        last = result
    if last is None:
        raise RuntimeError("no himalaya command variant was attempted")
    return last


def parse_json_or_text(raw: str) -> Any:
    text = raw.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def redacted_stderr(text: str) -> str:
    lowered = text.lower()
    sensitive_markers = ["password", "token", "secret", "authorization"]
    if any(marker in lowered for marker in sensitive_markers):
        return "[redacted: command mentioned sensitive material]"
    return text.strip()[:4000]


def status() -> dict[str, Any]:
    binary = himalaya_binary()
    result: dict[str, Any] = {
        "ok": True,
        "installed": binary is not None,
        "binary": binary,
        "secrets_env_present": {
            "HIMALAYA_PASSWORD": bool(os.environ.get("HIMALAYA_PASSWORD")),
            "HIMALAYA_OAUTH_TOKEN": bool(os.environ.get("HIMALAYA_OAUTH_TOKEN")),
        },
    }
    if binary is None:
        result["state"] = "missing_binary"
        result["next_step"] = "Install himalaya through Fae tool augmentation or brew; do not install from this skill."
        return result

    version = run_himalaya(["--version"])
    result["version"] = (version.stdout or version.stderr).strip().splitlines()[:3]
    result["state"] = "ready"
    return result


def list_recent(params: dict[str, Any]) -> dict[str, Any]:
    folder = str(params.get("folder") or "INBOX").strip() or "INBOX"
    count = safe_count(params.get("count"), default=5)
    account = params.get("account")
    args = ["--json", "envelope", "list", "-m", folder]
    result = run_with_account_variants(account, args)
    payload = parse_json_or_text(result.stdout)
    ok = result.returncode == 0
    return {
        "ok": ok,
        "action": "list_recent",
        "folder": folder,
        "count_requested": count,
        "result": trim_envelopes(payload, count),
        "stderr": redacted_stderr(result.stderr) if not ok else "",
        "exit_code": result.returncode,
    }


def search(params: dict[str, Any]) -> dict[str, Any]:
    query = str(params.get("query") or "").strip()
    if not query:
        return {"ok": False, "error": "query is required"}
    folder = str(params.get("folder") or "INBOX").strip() or "INBOX"
    count = safe_count(params.get("count"), default=10)
    account = params.get("account")
    args = ["--json", "envelope", "search", "-m", folder, *query.split()]
    result = run_with_account_variants(account, args)
    payload = parse_json_or_text(result.stdout)
    ok = result.returncode == 0
    return {
        "ok": ok,
        "action": "search",
        "folder": folder,
        "query": query,
        "count_requested": count,
        "result": trim_envelopes(payload, count),
        "stderr": redacted_stderr(result.stderr) if not ok else "",
        "exit_code": result.returncode,
    }


def trim_envelopes(payload: Any, count: int) -> Any:
    if isinstance(payload, dict) and isinstance(payload.get("envelopes"), list):
        trimmed = []
        for item in payload["envelopes"][:count]:
            if isinstance(item, dict):
                trimmed.append({
                    "id": item.get("id"),
                    "message_id": item.get("message-id") or item.get("message_id"),
                    "subject": item.get("subject"),
                    "from": item.get("from"),
                    "date": item.get("date"),
                    "flags": item.get("flags"),
                    "has_attachment": item.get("has-attachment") or item.get("has_attachment"),
                })
            else:
                trimmed.append(item)
        return {"envelopes": trimmed, "total_returned": len(trimmed)}
    if isinstance(payload, list):
        return payload[:count]
    return payload


def address_header(values: Any) -> str:
    if values is None:
        return ""
    if isinstance(values, str):
        return values.strip()
    if isinstance(values, list):
        return ", ".join(str(value).strip() for value in values if str(value).strip())
    return str(values).strip()


def build_message(params: dict[str, Any]) -> str:
    to_header = address_header(params.get("to"))
    subject = str(params.get("subject") or "").strip()
    body = str(params.get("body") or "")
    if not to_header:
        raise ValueError("to is required")
    if not subject:
        raise ValueError("subject is required")

    lines = []
    from_header = address_header(params.get("from"))
    if from_header:
        lines.append(("From", from_header))
    lines.append(("To", to_header))
    cc_header = address_header(params.get("cc"))
    if cc_header:
        lines.append(("Cc", cc_header))
    if address_header(params.get("bcc")):
        raise ValueError("bcc is not supported by this v1 raw-message sender; use to/cc or provider UI")
    lines.append(("Subject", subject))
    lines.append(("Date", email.utils.formatdate(localtime=True)))
    lines.append(("Content-Type", "text/plain; charset=utf-8"))
    headers = "\n".join(f"{name}: {value}" for name, value in lines)
    return f"{headers}\n\n{body}\n"


def send(params: dict[str, Any]) -> dict[str, Any]:
    message = build_message(params)
    dry_run = params.get("dry_run", True)
    if isinstance(dry_run, str):
        dry_run = dry_run.lower() not in {"false", "0", "no"}
    if dry_run:
        return {
            "ok": True,
            "dry_run": True,
            "to": address_header(params.get("to")),
            "subject": str(params.get("subject") or ""),
            "bytes": len(message.encode("utf-8")),
            "message": "Dry run only; call with dry_run=false after user confirmation to send.",
        }

    args = ["message", "send"]
    if params.get("save", True):
        args.extend(["--save", str(params.get("sent_folder") or "sent")])

    account = params.get("account")
    account_name = str(account or "").strip()
    variants: list[list[str]] = []
    if account_name:
        variants.append(["--account", account_name, *args])
        variants.append(["-a", account_name, *args])
    variants.append(args)

    result: subprocess.CompletedProcess[str] | None = None
    for variant in variants:
        candidate = run_himalaya(variant, stdin=message)
        result = candidate
        if candidate.returncode == 0:
            break
    if result is None:
        raise RuntimeError("no himalaya send command variant was attempted")

    ok = result.returncode == 0
    return {
        "ok": ok,
        "dry_run": False,
        "to": address_header(params.get("to")),
        "subject": str(params.get("subject") or ""),
        "stdout": result.stdout.strip()[:4000],
        "stderr": redacted_stderr(result.stderr) if not ok else "",
        "exit_code": result.returncode,
    }


def main() -> int:
    try:
        params = read_request()
        action = str(params.get("action") or "status").strip()
        if action == "status":
            return emit(status())
        if action == "list_recent":
            return emit(list_recent(params))
        if action == "search":
            return emit(search(params))
        if action == "send":
            return emit(send(params))
        return emit({"ok": False, "error": f"unsupported action: {action}"}, status=1)
    except FileNotFoundError as exc:
        return emit({"ok": False, "state": "missing_binary", "error": str(exc)}, status=1)
    except subprocess.TimeoutExpired:
        return emit({"ok": False, "error": "himalaya command timed out"}, status=1)
    except Exception as exc:  # noqa: BLE001 - skill boundary returns structured JSON.
        return emit({"ok": False, "error": str(exc)}, status=1)


if __name__ == "__main__":
    raise SystemExit(main())
