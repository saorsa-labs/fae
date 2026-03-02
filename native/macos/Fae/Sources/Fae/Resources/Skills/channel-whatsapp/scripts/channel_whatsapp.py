#!/usr/bin/env python3
"""Minimal WhatsApp channel skill wrapper for Fae skill runtime."""

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
            "state": "needs_input",
            "required_fields": ["access_token", "phone_number_id", "verify_token"],
        }
    elif action == "configure":
        result = {
            "ok": True,
            "message": "WhatsApp settings accepted",
        }
    elif action == "test_connection":
        result = {
            "ok": True,
            "message": "WhatsApp test flow placeholder",
        }
    elif action == "disconnect":
        result = {
            "ok": True,
            "message": "WhatsApp disconnect placeholder",
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
