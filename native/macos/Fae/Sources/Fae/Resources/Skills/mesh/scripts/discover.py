#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["zeroconf"]
# ///
"""Discover peer Fae instances on the local network via Bonjour/mDNS or manual peer list."""

import json
import os
import sys
import threading
import time
from pathlib import Path

FORGE_DIR = Path(os.path.expanduser("~")) / ".fae-forge"
PEERS_FILE = FORGE_DIR / "peers.json"
SERVICE_TYPE = "_fae-tools._tcp.local."


def load_peers_file() -> dict:
    """Load the manual peers file."""
    if not PEERS_FILE.exists():
        return {"manual": [], "discovered": []}
    try:
        with open(PEERS_FILE, "r") as f:
            data = json.load(f)
        if "manual" not in data:
            data["manual"] = []
        if "discovered" not in data:
            data["discovered"] = []
        return data
    except (json.JSONDecodeError, OSError):
        return {"manual": [], "discovered": []}


def save_peers_file(data: dict) -> None:
    """Persist the peers file."""
    FORGE_DIR.mkdir(parents=True, exist_ok=True)
    with open(PEERS_FILE, "w") as f:
        json.dump(data, f, indent=2)


def discover_bonjour(timeout: int) -> list[dict]:
    """Use zeroconf to browse for _fae-tools._tcp services."""
    from zeroconf import ServiceBrowser, ServiceStateChange, Zeroconf
    import socket

    peers: list[dict] = []
    lock = threading.Lock()
    zc = Zeroconf()

    def on_state_change(
        zeroconf: Zeroconf,
        service_type: str,
        name: str,
        state_change: ServiceStateChange,
    ) -> None:
        if state_change is not ServiceStateChange.Added:
            return
        info = zeroconf.get_service_info(service_type, name)
        if info is None:
            return
        addresses = info.parsed_addresses()
        if not addresses:
            return
        # Prefer IPv4.
        ipv4 = [a for a in addresses if ":" not in a]
        host = ipv4[0] if ipv4 else addresses[0]
        port = info.port
        # Extract TXT record fields.
        props = {}
        if info.properties:
            for k, v in info.properties.items():
                key = k.decode("utf-8", errors="replace") if isinstance(k, bytes) else str(k)
                val = v.decode("utf-8", errors="replace") if isinstance(v, bytes) else str(v)
                props[key] = val
        peer = {
            "name": props.get("instance", name.replace(f".{SERVICE_TYPE}", "")),
            "host": host,
            "port": port,
            "tools": int(props.get("tools", "0")),
            "fingerprint": props.get("fingerprint", ""),
            "method": "bonjour",
        }
        with lock:
            # Deduplicate by host:port.
            if not any(p["host"] == host and p["port"] == port for p in peers):
                peers.append(peer)

    browser = ServiceBrowser(zc, SERVICE_TYPE, handlers=[on_state_change])
    time.sleep(timeout)
    browser.cancel()
    zc.close()
    return peers


def discover_manual() -> list[dict]:
    """Check manually-added peers by pinging their health endpoints."""
    import urllib.request
    import urllib.error

    data = load_peers_file()
    results: list[dict] = []
    for entry in data.get("manual", []):
        host = entry.get("host", "")
        port = entry.get("port", 9847)
        name = entry.get("name", f"{host}:{port}")
        url = f"http://{host}:{port}/health"
        try:
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req, timeout=3) as resp:
                body = json.loads(resp.read().decode("utf-8"))
            results.append({
                "name": body.get("name", name),
                "host": host,
                "port": port,
                "tools": body.get("tools", 0),
                "fingerprint": body.get("fingerprint", ""),
                "method": "manual",
                "online": True,
            })
        except (urllib.error.URLError, OSError, json.JSONDecodeError, ValueError):
            results.append({
                "name": name,
                "host": host,
                "port": port,
                "tools": 0,
                "fingerprint": "",
                "method": "manual",
                "online": False,
            })
    return results


def update_discovered_cache(peers: list[dict]) -> None:
    """Update the discovered peers in the peers file."""
    data = load_peers_file()
    data["discovered"] = [
        {
            "name": p["name"],
            "host": p["host"],
            "port": p["port"],
            "tools": p["tools"],
            "fingerprint": p["fingerprint"],
            "method": p["method"],
            "last_seen": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        for p in peers
    ]
    save_peers_file(data)


def main() -> None:
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    method = params.get("method", "bonjour")
    timeout = int(params.get("timeout", 5))

    if timeout < 1:
        timeout = 1
    if timeout > 30:
        timeout = 30

    all_peers: list[dict] = []

    try:
        if method in ("bonjour", "all"):
            bonjour_peers = discover_bonjour(timeout)
            all_peers.extend(bonjour_peers)

        if method in ("manual", "all"):
            manual_peers = discover_manual()
            all_peers.extend(manual_peers)

        if method not in ("bonjour", "manual", "all"):
            print(json.dumps({
                "ok": False,
                "error": f"Unknown method: {method}. Use 'bonjour', 'manual', or 'all'.",
            }))
            return

        # Cache discovered peers.
        update_discovered_cache(all_peers)

        print(json.dumps({
            "ok": True,
            "peers": all_peers,
            "count": len(all_peers),
            "method": method,
            "timeout": timeout,
        }, indent=2))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
