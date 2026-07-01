#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Manage x0x named groups / spaces.

Actions (params.action):
  create     — create a space (params: name; optional description, display_name, preset).
  list       (default) — list spaces.
  get        — full state of one space (param: group_id).
  members    — list members of a space (param: group_id).
  add_member — add an agent to a space (params: group_id, agent_id).
  invite     — create a shareable invite link (param: group_id; optional expiry_secs).
  join       — join a space via an invite (param: invite; optional display_name).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, read_params, emit, fail  # noqa: E402

PRESETS = ("private_secure", "public_request_secure", "public_open", "public_announce")


def is_hex64(s: str) -> bool:
    return isinstance(s, str) and len(s) == 64 and all(c in "0123456789abcdef" for c in s)


def require_group_id(params: dict) -> str:
    gid = (params.get("group_id") or "").strip()
    if not gid:
        raise X0xError("I need the space's id for that.")
    return gid


def do_create(client: X0x, params: dict) -> dict:
    name = (params.get("name") or "").strip()
    if not name:
        raise X0xError("A new space needs a name.")
    preset = (params.get("preset") or "private_secure").strip().lower()
    if preset not in PRESETS:
        raise X0xError(f"preset must be one of {', '.join(PRESETS)}.")
    body = {
        "name": name,
        "description": params.get("description") or "",
        "preset": preset,
    }
    if params.get("display_name"):
        body["display_name"] = str(params["display_name"])
    resp = client.post("/groups", body)
    return {
        "ok": True,
        "group_id": resp.get("group_id"),
        "topic": resp.get("topic"),
        "name": name,
        "preset": preset,
        "summary": f"Created the space '{name}' ({preset.replace('_', ' ')}).",
    }


def do_list(client: X0x) -> dict:
    resp = client.get("/groups")
    groups = resp.get("groups", []) or []
    names = []
    for g in groups[:6]:
        nm = g.get("display_name") or g.get("name") or g.get("group_id", "")[:8]
        mc = g.get("member_count")
        names.append(f"{nm}" + (f" ({mc})" if mc is not None else ""))
    if groups:
        summary = f"{len(groups)} space(s): " + ", ".join(names) + ("…" if len(groups) > 6 else "")
    else:
        summary = "No spaces yet."
    return {"ok": True, "groups": groups, "count": len(groups), "summary": summary}


def do_get(client: X0x, params: dict) -> dict:
    gid = require_group_id(params)
    resp = client.get(f"/groups/{gid}")
    return {"ok": True, "group": resp, "summary": f"Loaded space {gid}."}


def do_members(client: X0x, params: dict) -> dict:
    gid = require_group_id(params)
    resp = client.get(f"/groups/{gid}/members")
    members = resp.get("members", []) or []
    return {
        "ok": True,
        "group_id": gid,
        "members": members,
        "count": len(members),
        "summary": f"That space has {len(members)} member(s).",
    }


def do_add_member(client: X0x, params: dict) -> dict:
    gid = require_group_id(params)
    agent_id = (params.get("agent_id") or "").strip().lower()
    if not is_hex64(agent_id):
        raise X0xError("I need a valid 64-character agent id to add to the space.")
    client.post(f"/groups/{gid}/members", {"agent_id": agent_id})
    return {
        "ok": True,
        "group_id": gid,
        "agent_id": agent_id,
        "summary": f"Added {agent_id[:12]}… to the space.",
    }


def do_invite(client: X0x, params: dict) -> dict:
    gid = require_group_id(params)
    expiry = params.get("expiry_secs", 86400)
    try:
        expiry = int(expiry)
    except (TypeError, ValueError):
        raise X0xError("expiry_secs must be a number of seconds.")
    resp = client.post(f"/groups/{gid}/invite", {"expiry_secs": expiry})
    link = resp.get("invite_link")
    return {
        "ok": True,
        "group_id": gid,
        "invite_link": link,
        "expiry_secs": expiry,
        "summary": f"Here's the invite link to share: {link}",
    }


def do_join(client: X0x, params: dict) -> dict:
    invite = (params.get("invite") or "").strip()
    if not invite:
        raise X0xError("I need the invite link to join a space.")
    body = {"invite": invite}
    if params.get("display_name"):
        body["display_name"] = str(params["display_name"])
    resp = client.post("/groups/join", body)
    gid = resp.get("group_id")
    return {"ok": True, "group_id": gid, "summary": f"Joined the space ({gid})."}


def main() -> None:
    params = read_params()
    action = (params.get("action") or "list").strip().lower()
    client = X0x(params.get("instance"))
    handlers = {
        "create": lambda: do_create(client, params),
        "list": lambda: do_list(client),
        "get": lambda: do_get(client, params),
        "members": lambda: do_members(client, params),
        "add_member": lambda: do_add_member(client, params),
        "invite": lambda: do_invite(client, params),
        "join": lambda: do_join(client, params),
    }
    try:
        client.require_running()
        handler = handlers.get(action)
        if not handler:
            fail(f"Unknown action '{action}'. Use {', '.join(handlers)}.")
            return
        emit(handler())
    except X0xError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
