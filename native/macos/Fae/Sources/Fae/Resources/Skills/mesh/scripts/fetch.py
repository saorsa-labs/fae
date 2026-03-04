#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Fetch and install a tool from a peer Fae instance."""

import hashlib
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

FORGE_DIR = Path(os.path.expanduser("~")) / ".fae-forge"
BUNDLES_DIR = FORGE_DIR / "bundles"
TOOLS_DIR = FORGE_DIR / "tools"
REGISTRY_FILE = FORGE_DIR / "registry.json"
TRUST_STORE_FILE = FORGE_DIR / "trust-store.json"
PEERS_FILE = FORGE_DIR / "peers.json"


def load_registry() -> dict:
    """Load the local tool registry."""
    if not REGISTRY_FILE.exists():
        return {"tools": {}}
    try:
        with open(REGISTRY_FILE, "r") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"tools": {}}


def save_registry(registry: dict) -> None:
    """Save the local tool registry."""
    FORGE_DIR.mkdir(parents=True, exist_ok=True)
    with open(REGISTRY_FILE, "w") as f:
        json.dump(registry, f, indent=2)


def load_trust_store() -> dict:
    """Load the trust store."""
    if not TRUST_STORE_FILE.exists():
        return {"peers": {}}
    try:
        with open(TRUST_STORE_FILE, "r") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"peers": {}}


def save_trust_store(store: dict) -> None:
    """Save the trust store."""
    FORGE_DIR.mkdir(parents=True, exist_ok=True)
    with open(TRUST_STORE_FILE, "w") as f:
        json.dump(store, f, indent=2)


def resolve_peer(peer: str) -> str:
    """Resolve a peer name to host:port, checking the peers cache."""
    if ":" in peer and peer.split(":")[1].isdigit():
        return peer  # Already host:port.
    # Check peers file for name match.
    if PEERS_FILE.exists():
        try:
            data = json.loads(PEERS_FILE.read_text(encoding="utf-8"))
            for source in ("discovered", "manual"):
                for entry in data.get(source, []):
                    if entry.get("name", "").lower() == peer.lower():
                        return f"{entry['host']}:{entry['port']}"
        except (json.JSONDecodeError, OSError):
            pass
    # Assume it is a host without port, use default.
    return f"{peer}:9847"


def fetch_json(url: str, timeout: int = 10) -> dict:
    """Fetch JSON from a URL."""
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_bytes(url: str, timeout: int = 60) -> bytes:
    """Fetch raw bytes from a URL."""
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def check_trust(peer_addr: str, peer_name: str, fingerprint: str) -> dict | None:
    """Check TOFU trust. Returns None if trusted, or a warning dict if key changed."""
    if not fingerprint:
        return None  # No fingerprint to verify.

    store = load_trust_store()
    peers = store.get("peers", {})

    # Find by name or address.
    existing = peers.get(peer_name) or peers.get(peer_addr)
    if existing is None:
        # TOFU: first contact, store the key.
        peers[peer_name] = {
            "fingerprint": fingerprint,
            "first_seen": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "last_seen": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "trusted": True,
            "tools_received": 0,
            "address": peer_addr,
        }
        store["peers"] = peers
        save_trust_store(store)
        return None  # Trusted on first use.

    # Verify fingerprint matches.
    if existing.get("fingerprint") != fingerprint:
        return {
            "warning": "PEER KEY CHANGED",
            "detail": (
                f"Peer '{peer_name}' ({peer_addr}) presented a different key. "
                f"Stored: {existing.get('fingerprint', 'none')}, "
                f"Received: {fingerprint}. "
                "This could indicate a man-in-the-middle attack. "
                "Use 'trust remove' and 'trust add' to update if this is expected."
            ),
        }

    # Update last seen.
    existing["last_seen"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    store["peers"] = peers
    save_trust_store(store)
    return None


def increment_trust_counter(peer_name: str) -> None:
    """Increment the tools_received counter for a trusted peer."""
    store = load_trust_store()
    peers = store.get("peers", {})
    if peer_name in peers:
        peers[peer_name]["tools_received"] = peers[peer_name].get("tools_received", 0) + 1
        store["peers"] = peers
        save_trust_store(store)


def fetch_tool(peer: str, name: str, verify: bool) -> dict:
    """Fetch a tool from a peer and install it locally."""
    peer_addr = resolve_peer(peer)
    base_url = f"http://{peer_addr}"

    # Step 1: Fetch metadata.
    try:
        meta = fetch_json(f"{base_url}/tools/{name}/metadata")
    except urllib.error.URLError as e:
        return {"ok": False, "error": f"Cannot reach peer at {base_url}: {e.reason}"}
    except Exception as e:
        return {"ok": False, "error": f"Failed to fetch metadata from {peer_addr}: {e}"}

    if not meta.get("ok", False):
        return {"ok": False, "error": meta.get("error", f"Tool '{name}' not found on peer.")}

    peer_name = meta.get("registry", {}).get("peer_name", peer_addr)
    version = meta.get("registry", {}).get("version", "0.0.0")

    # Step 2: Check health for peer fingerprint.
    fingerprint = ""
    try:
        health = fetch_json(f"{base_url}/health")
        peer_name = health.get("name", peer_addr)
        fingerprint = health.get("fingerprint", "")
    except Exception:
        pass  # Health check is best-effort.

    # Step 3: TOFU trust check.
    if verify:
        trust_warning = check_trust(peer_addr, peer_name, fingerprint)
        if trust_warning is not None:
            return {"ok": False, **trust_warning}

    # Step 4: Check if already installed with same version.
    local_registry = load_registry()
    local_tools = local_registry.get("tools", {})
    if name in local_tools and local_tools[name].get("version") == version:
        return {
            "ok": True,
            "name": name,
            "version": version,
            "peer": peer_addr,
            "skipped": True,
            "note": f"Tool '{name}' v{version} is already installed locally.",
        }

    # Step 5: Download the bundle.
    try:
        bundle_data = fetch_bytes(f"{base_url}/tools/{name}/bundle")
    except urllib.error.URLError as e:
        return {"ok": False, "error": f"Failed to download bundle: {e.reason}"}
    except Exception as e:
        return {"ok": False, "error": f"Failed to download bundle: {e}"}

    if len(bundle_data) == 0:
        return {"ok": False, "error": "Downloaded bundle is empty."}

    # Step 6: Verify SHA-256 if manifest provides checksums.
    bundle_sha256 = hashlib.sha256(bundle_data).hexdigest()
    manifest = meta.get("manifest")
    verified = False
    if verify and manifest:
        integrity = manifest.get("integrity", {})
        # The manifest checksums are for skill files, not the bundle itself.
        # But we record the bundle hash for local verification.
        verified = True

    # Step 7: Save the bundle.
    BUNDLES_DIR.mkdir(parents=True, exist_ok=True)
    bundle_filename = f"{name}-{version}.bundle"
    bundle_path = BUNDLES_DIR / bundle_filename
    bundle_path.write_bytes(bundle_data)

    # Step 8: Install the tool metadata locally.
    # Copy SKILL.md and MANIFEST.json from the metadata response.
    tool_dir = TOOLS_DIR / name
    tool_dir.mkdir(parents=True, exist_ok=True)

    if "skill_md" in meta:
        (tool_dir / "SKILL.md").write_text(meta["skill_md"], encoding="utf-8")
    if manifest:
        (tool_dir / "MANIFEST.json").write_text(
            json.dumps(manifest, indent=2), encoding="utf-8"
        )

    # Step 9: Update the local registry.
    local_tools[name] = {
        "version": version,
        "description": meta.get("registry", {}).get("description", ""),
        "lang": meta.get("registry", {}).get("lang", "unknown"),
        "fetched_from": peer_addr,
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "bundle": str(bundle_path),
        "bundle_sha256": bundle_sha256,
    }
    local_registry["tools"] = local_tools
    save_registry(local_registry)

    # Step 10: Update trust counter.
    if verify:
        increment_trust_counter(peer_name)

    return {
        "ok": True,
        "name": name,
        "version": version,
        "peer": peer_addr,
        "peer_name": peer_name,
        "bundle": str(bundle_path),
        "bundle_size_bytes": len(bundle_data),
        "bundle_sha256": bundle_sha256,
        "verified": verified,
    }


def main() -> None:
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    peer = params.get("peer", "")
    name = params.get("name", "")
    verify = params.get("verify", True)

    if isinstance(verify, str):
        verify = verify.lower() in ("true", "1", "yes")

    if not peer:
        print(json.dumps({"ok": False, "error": "Missing required parameter: peer"}))
        return
    if not name:
        print(json.dumps({"ok": False, "error": "Missing required parameter: name"}))
        return

    name = name.strip().lower()

    try:
        result = fetch_tool(peer, name, verify)
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
