#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Manage x0x contacts — the people and agents the user is connected to.

This is how Fae connects the user to other humans AND their agents: import a
person's agent card, or add an agent_id directly, and set a trust level.

Actions (params.action):
  list   (default) — list contacts.
  import — import a peer's agent card (param: card; optional trust_level).
  add    — add a contact by agent_id (param: agent_id; optional trust_level, label).
  trust  — set the trust level of a known agent_id (params: agent_id, level).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, read_params, emit, fail  # noqa: E402

TRUST_LEVELS = ("blocked", "unknown", "known", "trusted")


def is_hex64(s: str) -> bool:
    return isinstance(s, str) and len(s) == 64 and all(c in "0123456789abcdef" for c in s)


def do_list(client: X0x) -> dict:
    resp = client.get("/contacts")
    contacts = resp.get("contacts", []) or []
    labels = []
    for c in contacts[:5]:
        name = c.get("label") or (c.get("agent_id", "")[:12] + "…")
        labels.append(f"{name} ({c.get('trust_level', '?')})")
    if contacts:
        summary = f"{len(contacts)} contact(s): " + ", ".join(labels)
        if len(contacts) > 5:
            summary += ", …"
    else:
        summary = "No contacts yet."
    return {"ok": True, "contacts": contacts, "count": len(contacts), "summary": summary}


def do_import(client: X0x, params: dict) -> dict:
    card = params.get("card")
    if not card or not isinstance(card, str):
        raise X0xError("To import a contact I need their agent card (an x0x:// link or code).")
    trust = (params.get("trust_level") or "known").strip().lower()
    if trust not in TRUST_LEVELS:
        raise X0xError(f"trust_level must be one of {', '.join(TRUST_LEVELS)}.")
    client.post("/agent/card/import", {"card": card, "trust_level": trust})
    return {
        "ok": True,
        "imported": True,
        "trust_level": trust,
        "summary": f"Imported the contact and set trust to {trust}.",
    }


def do_add(client: X0x, params: dict) -> dict:
    agent_id = (params.get("agent_id") or "").strip().lower()
    if not is_hex64(agent_id):
        raise X0xError("I need a valid 64-character agent id to add a contact.")
    trust = (params.get("trust_level") or "known").strip().lower()
    if trust not in TRUST_LEVELS:
        raise X0xError(f"trust_level must be one of {', '.join(TRUST_LEVELS)}.")
    body = {"agent_id": agent_id, "trust_level": trust}
    label = params.get("label")
    if label:
        body["label"] = str(label)
    client.post("/contacts", body)
    who = label or (agent_id[:12] + "…")
    return {
        "ok": True,
        "added": True,
        "agent_id": agent_id,
        "trust_level": trust,
        "summary": f"Added {who} as a contact ({trust}).",
    }


def do_trust(client: X0x, params: dict) -> dict:
    agent_id = (params.get("agent_id") or "").strip().lower()
    if not is_hex64(agent_id):
        raise X0xError("I need a valid 64-character agent id to set trust.")
    level = (params.get("level") or params.get("trust_level") or "").strip().lower()
    if level not in TRUST_LEVELS:
        raise X0xError(f"level must be one of {', '.join(TRUST_LEVELS)}.")
    client.post("/contacts/trust", {"agent_id": agent_id, "level": level})
    return {
        "ok": True,
        "agent_id": agent_id,
        "level": level,
        "summary": f"Set trust for {agent_id[:12]}… to {level}.",
    }


def main() -> None:
    params = read_params()
    action = (params.get("action") or "list").strip().lower()
    client = X0x(params.get("instance"))
    try:
        client.require_running()
        if action == "list":
            emit(do_list(client))
        elif action == "import":
            emit(do_import(client, params))
        elif action == "add":
            emit(do_add(client, params))
        elif action == "trust":
            emit(do_trust(client, params))
        else:
            fail(f"Unknown action '{action}'. Use list, import, add, or trust.")
    except X0xError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
