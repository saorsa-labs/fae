#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Manage x0x tailnet TCP port-forwards.

Actions (params.action):
  list (default) — list configured forwards.
  add            — create a forward (local_addr, peer_agent, target_host, target_port).
  rm             — remove a forward (local_addr).
"""

import ipaddress
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, read_params, emit, fail  # noqa: E402


def _port(value, label: str) -> int:
    if isinstance(value, bool):
        raise X0xError(f"The {label} port must be between 1 and 65535.")
    if isinstance(value, int):
        port = value
    elif isinstance(value, str) and value.isdigit():
        port = int(value)
    else:
        raise X0xError(f"The {label} port must be between 1 and 65535.")
    if not 1 <= port <= 65535:
        raise X0xError(f"The {label} port must be between 1 and 65535.")
    return port


def _loopback_ip(value, label: str) -> str:
    text = str(value or "").strip()
    try:
        address = ipaddress.ip_address(text)
    except ValueError:
        raise X0xError(f"The {label} must be a numeric loopback address, such as 127.0.0.1.") from None
    if not address.is_loopback:
        raise X0xError(f"The {label} must be a loopback address on this machine.")
    return address.compressed


def _local_address(value) -> tuple[str, int]:
    text = str(value or "").strip()
    if text.startswith("["):
        closing = text.find("]")
        host = text[1:closing] if closing > 0 else ""
        separator = text[closing + 1:closing + 2] if closing >= 0 else ""
        port_text = text[closing + 2:] if separator == ":" else ""
    else:
        host, separator, port_text = text.rpartition(":")
    if separator != ":" or not host or not port_text:
        raise X0xError("The local address must look like 127.0.0.1:15432.")
    host = _loopback_ip(host, "local address")
    port = _port(port_text, "local")
    normalized = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
    return normalized, port


def _peer_agent(value) -> str:
    agent = str(value or "").strip().lower()
    if len(agent) != 64 or any(char not in "0123456789abcdef" for char in agent):
        raise X0xError("I need a valid 64-character agent id for the other machine.")
    return agent


def do_add(client: X0x, params: dict) -> dict:
    local_addr, local_port = _local_address(params.get("local_addr"))
    peer_agent = _peer_agent(params.get("peer_agent"))
    target_host = _loopback_ip(params.get("target_host"), "target host")
    target_port = _port(params.get("target_port"), "target")
    body = {
        "local_addr": local_addr,
        "peer_agent": peer_agent,
        "target_host": target_host,
        "target_port": target_port,
    }
    try:
        resp = client.post("/forwards", body)
    except X0xError:
        short_peer = peer_agent[:12] + "…"
        raise X0xError(
            "I couldn't create that tunnel. "
            f"Is {short_peer} online, trusted, and allowed by this machine's connect policy?"
        ) from None
    return {
        "ok": True,
        "local_addr": resp.get("local_addr", local_addr),
        "peer_agent": resp.get("peer_agent", peer_agent),
        "target_host": target_host,
        "target_port": target_port,
        "summary": f"Forwarding local port {local_port} to port {target_port} on that machine.",
    }


def do_list(client: X0x) -> dict:
    try:
        resp = client.get("/forwards")
    except X0xError:
        raise X0xError("I couldn't list the tailnet forwards right now.") from None
    forwards = resp.get("forwards", []) or []
    summary = (
        f"{len(forwards)} tailnet forward(s) configured."
        if forwards
        else "No tailnet forwards are configured."
    )
    return {"ok": True, "forwards": forwards, "count": len(forwards), "summary": summary}


def do_rm(client: X0x, params: dict) -> dict:
    local_addr, local_port = _local_address(params.get("local_addr"))
    encoded_addr = urllib.parse.quote(local_addr, safe="")
    try:
        resp = client.delete(f"/forwards/{encoded_addr}")
    except X0xError:
        raise X0xError(f"I couldn't remove the forward on local port {local_port}.") from None
    return {
        "ok": True,
        "local_addr": local_addr,
        "removed": bool(resp.get("removed", True)),
        "summary": f"Removed the forward on local port {local_port}.",
    }


def main() -> None:
    params = read_params()
    action = str(params.get("action") or "list").strip().lower()
    client = X0x(params.get("instance"))
    try:
        client.require_running()
        if action == "list":
            emit(do_list(client))
        elif action == "add":
            emit(do_add(client, params))
        elif action == "rm":
            emit(do_rm(client, params))
        else:
            fail(f"Unknown action '{action}'. Use list, add, or rm.")
    except X0xError as error:
        fail(str(error))


if __name__ == "__main__":
    main()
