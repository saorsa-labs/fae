#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""See who is online and discover agents on the x0x network.

Actions (params.action):
  online (default) — agents currently online.
  find   — locate a specific agent by id (param: agent_id; optional ttl, timeout_ms).
  foaf   — friends-of-a-friend discovery (optional ttl, timeout_ms).
"""

import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, read_params, emit, fail  # noqa: E402


def is_hex64(s: str) -> bool:
    return isinstance(s, str) and len(s) == 64 and all(c in "0123456789abcdef" for c in s)


def _discovery_query(params: dict) -> str:
    ttl = params.get("ttl", 3)
    timeout_ms = params.get("timeout_ms", 5000)
    try:
        ttl = int(ttl)
        timeout_ms = int(timeout_ms)
    except (TypeError, ValueError):
        ttl, timeout_ms = 3, 5000
    return urllib.parse.urlencode({"ttl": ttl, "timeout_ms": timeout_ms})


def _agent_label(entry) -> str:
    if isinstance(entry, str):
        return entry[:12] + "…"
    aid = (entry.get("agent_id") or "")[:12]
    uid = entry.get("user_id")
    return f"{uid} ({aid}…)" if uid else f"{aid}…"


def do_online(client: X0x) -> dict:
    # Prefer the richer /presence/online; fall back to the raw id list.
    source = "online"
    try:
        resp = client.get("/presence/online")
        agents = resp.get("agents", []) or []
    except X0xError:
        resp = client.get("/presence")
        agents = resp.get("agents", []) or []
        source = "presence"
    labels = [_agent_label(a) for a in agents[:6]]
    if agents:
        summary = f"{len(agents)} agent(s) online: " + ", ".join(labels)
        if len(agents) > 6:
            summary += ", …"
    else:
        summary = "No one is showing as online right now."
    return {"ok": True, "agents": agents, "count": len(agents), "source": source, "summary": summary}


def do_find(client: X0x, params: dict) -> dict:
    agent_id = (params.get("agent_id") or "").strip().lower()
    if not is_hex64(agent_id):
        raise X0xError("I need a valid 64-character agent id to look someone up.")
    resp = client.get(f"/presence/find/{agent_id}?{_discovery_query(params)}",
                      raise_on_not_ok=False)
    agent = resp.get("agent")
    found = bool(agent) and resp.get("ok", True)
    return {
        "ok": True,
        "found": found,
        "agent": agent,
        "summary": (f"Found {_agent_label(agent)}." if found
                    else "I couldn't find that agent on the network right now."),
    }


def do_foaf(client: X0x, params: dict) -> dict:
    resp = client.get(f"/presence/foaf?{_discovery_query(params)}")
    agents = resp.get("agents", []) or []
    labels = [_agent_label(a) for a in agents[:6]]
    if agents:
        summary = f"Discovered {len(agents)} agent(s): " + ", ".join(labels)
        if len(agents) > 6:
            summary += ", …"
    else:
        summary = "No new agents discovered nearby."
    return {"ok": True, "agents": agents, "count": len(agents), "summary": summary}


def main() -> None:
    params = read_params()
    action = (params.get("action") or "online").strip().lower()
    client = X0x(params.get("instance"))
    try:
        client.require_running()
        if action == "online":
            emit(do_online(client))
        elif action == "find":
            emit(do_find(client, params))
        elif action == "foaf":
            emit(do_foaf(client, params))
        else:
            fail(f"Unknown action '{action}'. Use online, find, or foaf.")
    except X0xError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
