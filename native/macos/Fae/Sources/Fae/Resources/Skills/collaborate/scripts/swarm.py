#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Swarm: publish tasks to and register interest in x0x pub/sub topics.

x0x swarm is generic gossip pub/sub (not a durable job queue). Results stream
over the /events SSE channel, which a one-shot script cannot tail — so `read`
points the user at the app rather than fabricating a results endpoint.

Actions (params.action):
  publish   — publish `payload` to a `topic` (default x0x-swarm/tasks).
  subscribe — register interest in a `topic` (default x0x-swarm/results).
  read      — explain where live results appear.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, read_params, emit, fail, b64  # noqa: E402

DEFAULT_TASK_TOPIC = "x0x-swarm/tasks"
DEFAULT_RESULT_TOPIC = "x0x-swarm/results"


def do_publish(client: X0x, params: dict) -> dict:
    payload = params.get("payload")
    if payload is None or not isinstance(payload, str) or payload == "":
        raise X0xError("I need the task payload to publish.")
    topic = (params.get("topic") or DEFAULT_TASK_TOPIC).strip()
    # Subscribe before publishing: the x0x gossip layer silently drops publishes
    # from agents that are not mesh members of the topic.  Subscribing here is
    # idempotent and ensures local mesh membership before the payload goes out.
    subscribed = True
    try:
        client.post("/subscribe", {"topic": topic})
    except X0xError:
        subscribed = False
    # pub/sub payloads are base64-encoded.
    resp = client.post("/publish", {"topic": topic, "payload": b64(payload)})
    warning = (
        ""
        if subscribed
        else (
            " Note: could not confirm mesh subscription before publishing"
            " — the message may not reach all peers."
        )
    )
    return {
        "ok": True,
        "message_id": resp.get("message_id"),
        "topic": topic,
        "subscribed_before_publish": subscribed,
        "summary": f"Published the task to '{topic}'.{warning}",
    }


def do_subscribe(client: X0x, params: dict) -> dict:
    topic = (params.get("topic") or DEFAULT_RESULT_TOPIC).strip()
    resp = client.post("/subscribe", {"topic": topic})
    return {
        "ok": True,
        "subscription_id": resp.get("subscription_id"),
        "topic": topic,
        "summary": (f"Subscribed to '{topic}'. Results arrive live over the network — "
                    "open the app's swarm view to watch them come in."),
    }


def do_read(_client: X0x, _params: dict) -> dict:
    return {
        "ok": True,
        "summary": ("Swarm results stream live over the network and can't be replayed "
                    "from here. Open the app's swarm view to see results as they arrive."),
    }


def main() -> None:
    params = read_params()
    action = (params.get("action") or "publish").strip().lower()
    client = X0x(params.get("instance"))
    try:
        client.require_running()
        if action == "publish":
            emit(do_publish(client, params))
        elif action == "subscribe":
            emit(do_subscribe(client, params))
        elif action == "read":
            emit(do_read(client, params))
        else:
            fail(f"Unknown action '{action}'. Use publish, subscribe, or read.")
    except X0xError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
