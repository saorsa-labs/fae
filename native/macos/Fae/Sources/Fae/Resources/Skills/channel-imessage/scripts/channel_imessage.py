#!/usr/bin/env python3
"""Minimal iMessage channel skill wrapper for Fae skill runtime."""

import json
import sys


def main() -> int:
    payload = sys.stdin.read().strip()
    if not payload:
        print("{\"ok\":false,\"error\":\"empty request\"}")
        return 1

    try:
        request = json.loads(payload)
    except json.JSONDecodeError:
        print("{\"ok\":false,\"error\":\"invalid json\"}")
        return 1

    params = request.get("params") or {}
    action = params.get("action", "status")

    if action == "status":
        result = {
            "ok": True,
            "state": "configured",
            "required_fields": [],
        }
    elif action == "configure":
        result = {
            "ok": True,
            "message": "iMessage settings accepted",
        }
    elif action == "test_connection":
        result = {
            "ok": True,
            "message": "iMessage test flow placeholder",
        }
    elif action == "disconnect":
        result = {
            "ok": True,
            "message": "iMessage disconnect placeholder",
        }
    else:
        result = {
            "ok": False,
            "error": f"unsupported action: {action}",
        }

    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
