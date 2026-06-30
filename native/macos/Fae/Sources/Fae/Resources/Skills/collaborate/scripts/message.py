#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Send and read messages — in a space (group_id) or direct to an agent (agent_id).

Actions (params.action):
  send — send `text` to a `group_id` (group message) or `agent_id` (direct message).
  read — read recent messages of a `group_id`.

Note on direct-message history: incoming DMs arrive over the daemon's
/direct/events SSE stream. A one-shot script cannot tail a stream, so `read`
supports group history only; for DM history use the GUI. We never fabricate a
DM-history endpoint.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, read_params, emit, fail, b64  # noqa: E402


def is_hex64(s: str) -> bool:
    return isinstance(s, str) and len(s) == 64 and all(c in "0123456789abcdef" for c in s)


def do_send(client: X0x, params: dict) -> dict:
    text = params.get("text")
    if not text or not isinstance(text, str):
        raise X0xError("I need the message text to send.")
    group_id = (params.get("group_id") or "").strip()
    agent_id = (params.get("agent_id") or "").strip().lower()
    if group_id and agent_id:
        raise X0xError("Send to a space OR a person, not both — give group_id or agent_id.")
    if group_id:
        resp = client.post(f"/groups/{group_id}/send", {"body": text, "kind": "text"})
        return {
            "ok": True,
            "message_id": resp.get("message_id"),
            "group_id": group_id,
            "summary": "Sent your message to the space.",
        }
    if agent_id:
        if not is_hex64(agent_id):
            raise X0xError("That agent id isn't valid (needs 64 hex characters).")
        # Direct-message payloads are base64-encoded.
        resp = client.post("/direct/send", {"agent_id": agent_id, "payload": b64(text)})
        return {
            "ok": True,
            "msg_id": resp.get("msg_id"),
            "agent_id": agent_id,
            "summary": f"Sent a direct message to {agent_id[:12]}….",
        }
    raise X0xError("Tell me where to send it — a space (group_id) or a person (agent_id).")


def _ago(ts) -> str:
    try:
        ms = float(ts)
    except (TypeError, ValueError):
        return ""
    # timestamps are unix ms; tolerate seconds too.
    if ms > 1e12:
        ms /= 1000.0
    delta = max(0.0, time.time() - ms)
    if delta < 90:
        return "just now"
    if delta < 3600:
        return f"{int(delta // 60)}m ago"
    if delta < 86400:
        return f"{int(delta // 3600)}h ago"
    return f"{int(delta // 86400)}d ago"


def do_read(client: X0x, params: dict) -> dict:
    group_id = (params.get("group_id") or "").strip()
    if not group_id:
        if params.get("agent_id"):
            raise X0xError(
                "I can't replay direct-message history from here — DMs stream live over "
                "the network. Open the app to see your DM history, or read a space instead."
            )
        raise X0xError("Which space should I read? I need a group_id.")
    resp = client.get(f"/groups/{group_id}/messages")
    messages = resp.get("messages", []) or []
    recent = messages[-10:]
    shaped = [
        {
            "from": m.get("from"),
            "body": m.get("body"),
            "timestamp": m.get("timestamp"),
            "ago": _ago(m.get("timestamp")),
        }
        for m in recent
    ]
    if shaped:
        last = shaped[-1]
        sender = (last.get("from") or "")[:12]
        summary = (
            f"{len(messages)} message(s) in this space. "
            f"Latest from {sender}… {last.get('ago', '')}: {last.get('body', '')}"
        )
    else:
        summary = "No messages in this space yet."
    return {
        "ok": True,
        "group_id": group_id,
        "messages": shaped,
        "total": len(messages),
        "history_note": "Group history shown is daemon-backed for signed public groups; "
                        "some history may live only in the app.",
        "summary": summary,
    }


def main() -> None:
    params = read_params()
    action = (params.get("action") or "send").strip().lower()
    client = X0x(params.get("instance"))
    try:
        client.require_running()
        if action == "send":
            emit(do_send(client, params))
        elif action == "read":
            emit(do_read(client, params))
        else:
            fail(f"Unknown action '{action}'. Use send or read.")
    except X0xError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
