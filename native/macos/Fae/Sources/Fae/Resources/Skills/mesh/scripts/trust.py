#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Manage the TOFU trust store for peer Fae instances."""

import json
import os
import sys
import time
from pathlib import Path

FORGE_DIR = Path(os.path.expanduser("~")) / ".fae-forge"
TRUST_STORE_FILE = FORGE_DIR / "trust-store.json"


def load_trust_store() -> dict:
    """Load the trust store."""
    if not TRUST_STORE_FILE.exists():
        return {"peers": {}}
    try:
        with open(TRUST_STORE_FILE, "r") as f:
            data = json.load(f)
        if "peers" not in data:
            data["peers"] = {}
        return data
    except (json.JSONDecodeError, OSError):
        return {"peers": {}}


def save_trust_store(store: dict) -> None:
    """Save the trust store."""
    FORGE_DIR.mkdir(parents=True, exist_ok=True)
    with open(TRUST_STORE_FILE, "w") as f:
        json.dump(store, f, indent=2)


def trust_list() -> dict:
    """List all peers in the trust store."""
    store = load_trust_store()
    peers = store.get("peers", {})
    if not peers:
        return {
            "ok": True,
            "peers": [],
            "count": 0,
            "note": "No peers in trust store. Peers are added automatically on first connection (TOFU).",
        }
    peer_list = []
    for name, info in peers.items():
        peer_list.append({
            "name": name,
            "fingerprint": info.get("fingerprint", ""),
            "address": info.get("address", ""),
            "trusted": info.get("trusted", False),
            "first_seen": info.get("first_seen", ""),
            "last_seen": info.get("last_seen", ""),
            "tools_received": info.get("tools_received", 0),
        })
    return {"ok": True, "peers": peer_list, "count": len(peer_list)}


def trust_add(peer: str, pubkey: str) -> dict:
    """Add a peer to the trust store with their public key."""
    if not peer:
        return {"ok": False, "error": "Missing required parameter: peer (name or address)."}

    store = load_trust_store()
    peers = store.get("peers", {})

    # Compute fingerprint from pubkey if provided.
    fingerprint = ""
    if pubkey:
        import hashlib
        import base64

        # Parse SSH public key to get the raw key data.
        parts = pubkey.strip().split()
        if len(parts) >= 2:
            try:
                key_bytes = base64.b64decode(parts[1])
                raw_hash = hashlib.sha256(key_bytes).digest()
                b64_hash = base64.b64encode(raw_hash).decode("ascii").rstrip("=")
                fingerprint = f"SHA256:{b64_hash}"
            except Exception:
                fingerprint = f"SHA256:{hashlib.sha256(pubkey.encode()).hexdigest()[:43]}"
        else:
            fingerprint = f"SHA256:{hashlib.sha256(pubkey.encode()).hexdigest()[:43]}"

    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    if peer in peers:
        # Update existing peer.
        if fingerprint:
            peers[peer]["fingerprint"] = fingerprint
        if pubkey:
            peers[peer]["pubkey"] = pubkey
        peers[peer]["last_seen"] = now
        peers[peer]["trusted"] = True
        action = "updated"
    else:
        # Add new peer.
        peers[peer] = {
            "fingerprint": fingerprint,
            "pubkey": pubkey if pubkey else "",
            "first_seen": now,
            "last_seen": now,
            "trusted": True,
            "tools_received": 0,
        }
        action = "added"

    store["peers"] = peers
    save_trust_store(store)
    return {
        "ok": True,
        "action": action,
        "peer": peer,
        "fingerprint": fingerprint,
        "trusted": True,
    }


def trust_remove(peer: str) -> dict:
    """Remove a peer from the trust store."""
    if not peer:
        return {"ok": False, "error": "Missing required parameter: peer (name or fingerprint)."}

    store = load_trust_store()
    peers = store.get("peers", {})

    # Try by name first.
    if peer in peers:
        removed = peers.pop(peer)
        store["peers"] = peers
        save_trust_store(store)
        return {
            "ok": True,
            "removed": peer,
            "fingerprint": removed.get("fingerprint", ""),
        }

    # Try by fingerprint.
    for name, info in list(peers.items()):
        if info.get("fingerprint", "") == peer:
            removed = peers.pop(name)
            store["peers"] = peers
            save_trust_store(store)
            return {
                "ok": True,
                "removed": name,
                "fingerprint": peer,
            }

    return {"ok": False, "error": f"Peer '{peer}' not found in trust store."}


def trust_verify(peer: str) -> dict:
    """Verify a peer's current key against the stored key."""
    if not peer:
        return {"ok": False, "error": "Missing required parameter: peer (name or address)."}

    store = load_trust_store()
    peers = store.get("peers", {})

    # Find the peer entry.
    entry = peers.get(peer)
    if entry is None:
        # Try to find by address.
        for name, info in peers.items():
            if info.get("address", "") == peer:
                entry = info
                peer = name
                break

    if entry is None:
        return {
            "ok": False,
            "error": f"Peer '{peer}' not found in trust store. Connect to them first to establish TOFU trust.",
        }

    # Try to reach the peer and compare keys.
    address = entry.get("address", "")
    if not address:
        return {
            "ok": True,
            "peer": peer,
            "trusted": entry.get("trusted", False),
            "fingerprint": entry.get("fingerprint", ""),
            "note": "No address stored. Cannot verify remotely. Trust status is based on last known key.",
        }

    try:
        import urllib.request
        url = f"http://{address}/health"
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=5) as resp:
            health = json.loads(resp.read().decode("utf-8"))
        remote_fingerprint = health.get("fingerprint", "")
        stored_fingerprint = entry.get("fingerprint", "")

        if not remote_fingerprint:
            return {
                "ok": True,
                "peer": peer,
                "address": address,
                "online": True,
                "verified": None,
                "note": "Peer is online but did not provide a fingerprint.",
            }

        match = remote_fingerprint == stored_fingerprint
        return {
            "ok": True,
            "peer": peer,
            "address": address,
            "online": True,
            "verified": match,
            "stored_fingerprint": stored_fingerprint,
            "remote_fingerprint": remote_fingerprint,
            "warning": None if match else "KEY MISMATCH: Peer's key has changed since first contact!",
        }
    except Exception as e:
        return {
            "ok": True,
            "peer": peer,
            "address": address,
            "online": False,
            "verified": None,
            "note": f"Cannot reach peer: {e}",
            "stored_fingerprint": entry.get("fingerprint", ""),
        }


def main() -> None:
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    action = params.get("action", "")

    if not action:
        print(json.dumps({
            "ok": False,
            "error": "Missing required parameter: action (list, add, remove, or verify).",
        }))
        return

    try:
        if action == "list":
            result = trust_list()
        elif action == "add":
            peer = params.get("peer", "")
            pubkey = params.get("pubkey", "")
            result = trust_add(peer, pubkey)
        elif action == "remove":
            peer = params.get("peer", "")
            result = trust_remove(peer)
        elif action == "verify":
            peer = params.get("peer", "")
            result = trust_verify(peer)
        else:
            result = {
                "ok": False,
                "error": f"Unknown action: {action}. Use 'list', 'add', 'remove', or 'verify'.",
            }
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
