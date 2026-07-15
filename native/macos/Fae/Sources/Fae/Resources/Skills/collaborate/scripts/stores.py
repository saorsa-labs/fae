#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Manage replicated x0x key-value stores.

Actions (params.action):
  list (default) — list joined stores.
  create         — create a store (name, topic).
  join           — join a store (store_id).
  keys           — list keys (store_id).
  get            — read a value (store_id, key).
  set            — write text (store_id, key, value; optional content_type).
  rm             — remove a value (store_id, key).
"""

import os
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, b64, unb64_text, read_params, emit, fail  # noqa: E402

# Delay schedule for retrying 404s during the x0xd startup state-recovery window
# (~10 s after daemon restart).  Three retries at 4 s each = ~12 s total budget.
_STARTUP_RETRY_DELAYS = (4.0, 4.0, 4.0)
_RESTART_HINT = (
    "That data isn't available yet — the x0x daemon may still be recovering state "
    "after a recent restart. Try again in a moment."
)


def _retry_read(fn, on_persistent_error: str) -> dict:
    """Call fn() (a GET), retrying up to 3 times on HTTP 404 startup recovery window.

    on_persistent_error is the sanitized message raised for any non-404 X0xError.
    When all retries exhaust on 404, raises with the restart hint instead.
    """
    for delay in (None, *_STARTUP_RETRY_DELAYS):
        if delay is not None:
            time.sleep(delay)
        try:
            return fn()
        except X0xError as e:
            if "HTTP 404" in str(e):
                continue
            raise X0xError(on_persistent_error) from None
    raise X0xError(_RESTART_HINT) from None


def _required_text(value, message: str, *, max_length: int = 1024) -> str:
    if not isinstance(value, str) or not value.strip():
        raise X0xError(message)
    text = value.strip()
    if len(text) > max_length or any(ord(char) < 32 for char in text):
        raise X0xError(message)
    return text


def _store_id(params: dict) -> str:
    return _required_text(
        params.get("store_id"),
        "Which shared store? I need its store_id.",
    )


def _key(params: dict) -> str:
    return _required_text(
        params.get("key"),
        "Which value? I need its key.",
    )


def _segment(value: str) -> str:
    return urllib.parse.quote(value, safe="")


def do_list(client: X0x) -> dict:
    resp = _retry_read(
        lambda: client.get("/stores"),
        "I couldn't list the shared stores right now.",
    )
    stores = resp.get("stores", []) or []
    summary = f"{len(stores)} shared store(s) joined." if stores else "No shared stores are joined yet."
    return {"ok": True, "stores": stores, "count": len(stores), "summary": summary}


def do_create(client: X0x, params: dict) -> dict:
    name = _required_text(params.get("name"), "A shared store needs both a name and a topic.")
    topic = _required_text(params.get("topic"), "A shared store needs both a name and a topic.")
    try:
        resp = client.post("/stores", {"name": name, "topic": topic})
    except X0xError:
        raise X0xError("I couldn't create that shared store.") from None
    store_id = resp.get("id", topic)
    return {
        "ok": True,
        "id": store_id,
        "name": name,
        "topic": topic,
        "summary": f"Created the shared store '{name}'.",
    }


def do_join(client: X0x, params: dict) -> dict:
    store_id = _store_id(params)
    try:
        resp = client.post(f"/stores/{_segment(store_id)}/join")
    except X0xError:
        raise X0xError("I couldn't join that shared store.") from None
    joined_id = resp.get("id", store_id)
    return {"ok": True, "id": joined_id, "summary": "Joined the shared store."}


def do_keys(client: X0x, params: dict) -> dict:
    store_id = _store_id(params)
    resp = _retry_read(
        lambda: client.get(f"/stores/{_segment(store_id)}/keys"),
        "I couldn't list the keys in that shared store.",
    )
    keys = resp.get("keys", []) or []
    summary = f"{len(keys)} key(s) in that shared store." if keys else "That shared store has no keys yet."
    return {
        "ok": True,
        "store_id": store_id,
        "keys": keys,
        "count": len(keys),
        "summary": summary,
    }


def do_get(client: X0x, params: dict) -> dict:
    store_id = _store_id(params)
    key = _key(params)
    resp = _retry_read(
        lambda: client.get(f"/stores/{_segment(store_id)}/{_segment(key)}"),
        "I couldn't read that value from the shared store.",
    )
    encoded = resp.get("value") or ""
    return {
        **resp,
        "ok": True,
        "store_id": store_id,
        "key": resp.get("key", key),
        "value": encoded,
        "value_text": unb64_text(encoded),
        "summary": f"Read '{key}' from the shared store.",
    }


def do_set(client: X0x, params: dict) -> dict:
    store_id = _store_id(params)
    key = _key(params)
    if "value" not in params or not isinstance(params["value"], str):
        raise X0xError("I need a text value to save; an empty string is allowed.")
    value = params["value"]
    body = {"value": b64(value)}
    if params.get("content_type") is not None:
        content_type = _required_text(
            params.get("content_type"),
            "The content_type must be a non-empty media type.",
            max_length=255,
        )
        body["content_type"] = content_type
    try:
        client.put(f"/stores/{_segment(store_id)}/{_segment(key)}", body)
    except X0xError:
        raise X0xError("I couldn't save that value to the shared store.") from None
    return {
        "ok": True,
        "store_id": store_id,
        "key": key,
        "content_type": body.get("content_type", "application/octet-stream"),
        "summary": f"Saved '{key}' in the shared store.",
    }


def do_rm(client: X0x, params: dict) -> dict:
    store_id = _store_id(params)
    key = _key(params)
    try:
        client.delete(f"/stores/{_segment(store_id)}/{_segment(key)}")
    except X0xError:
        raise X0xError("I couldn't remove that value from the shared store.") from None
    return {
        "ok": True,
        "store_id": store_id,
        "key": key,
        "summary": f"Removed '{key}' from the shared store.",
    }


def main() -> None:
    params = read_params()
    action = str(params.get("action") or "list").strip().lower()
    client = X0x(params.get("instance"))
    try:
        client.require_running()
        if action == "list":
            emit(do_list(client))
        elif action == "create":
            emit(do_create(client, params))
        elif action == "join":
            emit(do_join(client, params))
        elif action == "keys":
            emit(do_keys(client, params))
        elif action == "get":
            emit(do_get(client, params))
        elif action == "set":
            emit(do_set(client, params))
        elif action == "rm":
            emit(do_rm(client, params))
        else:
            fail(f"Unknown action '{action}'. Use list, create, join, keys, get, set, or rm.")
    except X0xError as error:
        fail(str(error))


if __name__ == "__main__":
    main()
