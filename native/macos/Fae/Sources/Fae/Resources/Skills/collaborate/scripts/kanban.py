#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Kanban boards over x0x CRDT task-lists.

Actions (params.action):
  list   (default) — list boards (task-lists).
  create — create a board (param: name; optional topic).
  tasks  — list cards on a board (param: list_id).
  add    — add a card (params: list_id, title; optional description).
  update — claim/complete a card (params: list_id, task_id, action_kind=claim|complete).
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, read_params, emit, fail  # noqa: E402


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")
    return slug or "board"


def do_list(client: X0x) -> dict:
    resp = client.get("/task-lists")
    lists = resp.get("lists", []) or []
    labels = [(b.get("topic") or b.get("id", ""))[:24] for b in lists[:6]]
    summary = (f"{len(lists)} board(s): " + ", ".join(labels)) if lists else "No boards yet."
    return {"ok": True, "lists": lists, "count": len(lists), "summary": summary}


def do_create(client: X0x, params: dict) -> dict:
    name = (params.get("name") or "").strip()
    if not name:
        raise X0xError("A new board needs a name.")
    topic = (params.get("topic") or slugify(name)).strip()
    resp = client.post("/task-lists", {"name": name, "topic": topic})
    return {
        "ok": True,
        "id": resp.get("id"),
        "topic": resp.get("topic", topic),
        "name": name,
        "summary": f"Created the board '{name}'.",
    }


def do_tasks(client: X0x, params: dict) -> dict:
    list_id = (params.get("list_id") or "").strip()
    if not list_id:
        raise X0xError("Which board? I need its list_id.")
    resp = client.get(f"/task-lists/{list_id}/tasks")
    tasks = resp.get("tasks", []) or []
    by_state: dict[str, int] = {}
    for t in tasks:
        st = t.get("state") or "open"
        by_state[st] = by_state.get(st, 0) + 1
    if tasks:
        breakdown = ", ".join(f"{n} {st}" for st, n in by_state.items())
        summary = f"{len(tasks)} card(s): {breakdown}."
    else:
        summary = "This board has no cards yet."
    return {"ok": True, "list_id": list_id, "tasks": tasks, "count": len(tasks),
            "by_state": by_state, "summary": summary}


def do_add(client: X0x, params: dict) -> dict:
    list_id = (params.get("list_id") or "").strip()
    title = (params.get("title") or "").strip()
    if not list_id:
        raise X0xError("Which board? I need its list_id.")
    if not title:
        raise X0xError("A card needs a title.")
    body = {"title": title}
    if params.get("description"):
        body["description"] = str(params["description"])
    resp = client.post(f"/task-lists/{list_id}/tasks", body)
    return {
        "ok": True,
        "id": resp.get("id"),
        "title": resp.get("title", title),
        "list_id": list_id,
        "summary": f"Added the card '{title}'.",
    }


def do_update(client: X0x, params: dict) -> dict:
    list_id = (params.get("list_id") or "").strip()
    task_id = (params.get("task_id") or "").strip()
    kind = (params.get("action_kind") or "").strip().lower()
    if not list_id or not task_id:
        raise X0xError("I need both the board (list_id) and the card (task_id).")
    if kind not in ("claim", "complete"):
        raise X0xError("action_kind must be 'claim' or 'complete'.")
    client.post(f"/task-lists/{list_id}/tasks/{task_id}", {"action": kind})
    verb = "claimed" if kind == "claim" else "completed"
    return {"ok": True, "list_id": list_id, "task_id": task_id, "action_kind": kind,
            "summary": f"Marked that card {verb}."}


def main() -> None:
    params = read_params()
    action = (params.get("action") or "list").strip().lower()
    client = X0x(params.get("instance"))
    try:
        client.require_running()
        if action == "list":
            emit(do_list(client))
        elif action == "create":
            emit(do_create(client, params))
        elif action == "tasks":
            emit(do_tasks(client, params))
        elif action == "add":
            emit(do_add(client, params))
        elif action == "update":
            emit(do_update(client, params))
        else:
            fail(f"Unknown action '{action}'. Use list, create, tasks, add, or update.")
    except X0xError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
