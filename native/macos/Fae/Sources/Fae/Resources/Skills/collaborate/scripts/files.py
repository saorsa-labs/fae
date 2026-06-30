#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Send and manage P2P file transfers over x0x.

Sending computes size + sha256 from the file on disk and INCLUDES the local
`path` in the request — the x0x GUI omits `path`, which can make accepted sends
fail "No source path available". Including it fixes that.

Actions (params.action):
  send   — send a file to an agent (params: agent_id, path).
  list   (default) — list transfers.
  accept — accept an incoming transfer (param: transfer_id).
  reject — reject an incoming transfer (param: transfer_id).
"""

import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, read_params, emit, fail  # noqa: E402


def is_hex64(s: str) -> bool:
    return isinstance(s, str) and len(s) == 64 and all(c in "0123456789abcdef" for c in s)


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def do_send(client: X0x, params: dict) -> dict:
    agent_id = (params.get("agent_id") or "").strip().lower()
    if not is_hex64(agent_id):
        raise X0xError("I need a valid 64-character agent id to send a file to.")
    raw_path = params.get("path")
    if not raw_path or not isinstance(raw_path, str):
        raise X0xError("I need the path to the file you want to send.")
    path = os.path.abspath(os.path.expanduser(raw_path))
    if not os.path.isfile(path):
        raise X0xError(f"I couldn't find a file at {raw_path}.")

    size = os.path.getsize(path)
    digest = sha256_of(path)
    body = {
        "agent_id": agent_id,
        "filename": os.path.basename(path),
        "size": size,
        "sha256": digest,
        "path": path,  # the fix: the daemon needs the source path to read bytes.
    }
    resp = client.post("/files/send", body)
    return {
        "ok": True,
        "transfer_id": resp.get("transfer_id"),
        "filename": body["filename"],
        "size": size,
        "agent_id": agent_id,
        "summary": f"Sending {body['filename']} ({size} bytes) to {agent_id[:12]}….",
    }


def do_list(client: X0x) -> dict:
    resp = client.get("/files/transfers")
    transfers = resp.get("transfers", []) or []
    summary = f"{len(transfers)} transfer(s)." if transfers else "No file transfers."
    return {"ok": True, "transfers": transfers, "count": len(transfers), "summary": summary}


def do_accept(client: X0x, params: dict) -> dict:
    tid = (params.get("transfer_id") or "").strip()
    if not tid:
        raise X0xError("I need the transfer_id to accept.")
    client.post(f"/files/accept/{tid}")
    return {"ok": True, "transfer_id": tid, "summary": "Accepted the file transfer."}


def do_reject(client: X0x, params: dict) -> dict:
    tid = (params.get("transfer_id") or "").strip()
    if not tid:
        raise X0xError("I need the transfer_id to reject.")
    client.post(f"/files/reject/{tid}")
    return {"ok": True, "transfer_id": tid, "summary": "Rejected the file transfer."}


def main() -> None:
    params = read_params()
    action = (params.get("action") or "list").strip().lower()
    client = X0x(params.get("instance"))
    try:
        client.require_running()
        if action == "send":
            emit(do_send(client, params))
        elif action == "list":
            emit(do_list(client))
        elif action == "accept":
            emit(do_accept(client, params))
        elif action == "reject":
            emit(do_reject(client, params))
        else:
            fail(f"Unknown action '{action}'. Use send, list, accept, or reject.")
    except X0xError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
