#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Search for tools in the local registry and optionally across known peers."""

import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path


FORGE_DIR = Path(os.path.expanduser("~/.fae-forge"))
REGISTRY_PATH = FORGE_DIR / "registry.json"
TOOLS_DIR = FORGE_DIR / "tools"
PEERS_PATH = FORGE_DIR / "peers.json"


def load_registry() -> dict:
    """Load registry, returning empty structure if missing."""
    if not REGISTRY_PATH.exists():
        return {"version": 1, "tools": {}}
    try:
        with open(REGISTRY_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict) or "tools" not in data:
            return {"version": 1, "tools": {}}
        return data
    except (json.JSONDecodeError, OSError):
        return {"version": 1, "tools": {}}


def load_peers() -> list[dict]:
    """Load peer catalog endpoints from peers.json."""
    if not PEERS_PATH.exists():
        return []
    try:
        with open(PEERS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            return data
        if isinstance(data, dict) and "peers" in data:
            return data["peers"]
        return []
    except (json.JSONDecodeError, OSError):
        return []


def matches_query(query: str, tool_meta: dict) -> bool:
    """Check if a tool matches the search query (case-insensitive substring)."""
    q = query.lower()
    searchable = " ".join([
        tool_meta.get("name", ""),
        tool_meta.get("description", ""),
        tool_meta.get("lang", ""),
    ]).lower()
    return q in searchable


def search_local(query: str, registry: dict) -> list[dict]:
    """Search the local registry for matching tools."""
    results = []
    registered = registry.get("tools", {})

    for name, meta in sorted(registered.items()):
        if matches_query(query, meta):
            results.append({
                "name": name,
                "version": meta.get("version", "unknown"),
                "description": meta.get("description", ""),
                "source": "local",
                "installed": True,
            })

    # Also scan tools/ for orphan directories that match.
    registered_names = set(registered.keys())
    if TOOLS_DIR.is_dir():
        for child in sorted(TOOLS_DIR.iterdir()):
            if child.is_dir() and child.name not in registered_names:
                skill_md = child / "SKILL.md"
                if skill_md.exists():
                    orphan_meta = _parse_skill_md_simple(skill_md)
                    if matches_query(query, orphan_meta):
                        results.append({
                            "name": child.name,
                            "version": orphan_meta.get("version", "unknown"),
                            "description": orphan_meta.get("description", ""),
                            "source": "local (orphan)",
                            "installed": True,
                        })

    return results


def search_peers(query: str, installed_names: set[str]) -> list[dict]:
    """Search known peer catalogs for matching tools."""
    peers = load_peers()
    if not peers:
        return []

    results = []
    for peer in peers:
        peer_name = peer.get("name", "unknown-peer")
        catalog_url = peer.get("catalog_url", "")
        if not catalog_url:
            continue

        try:
            req = urllib.request.Request(
                catalog_url,
                method="GET",
                headers={"Accept": "application/json", "User-Agent": "fae-toolbox/1.0"},
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                catalog = json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, json.JSONDecodeError, OSError, TimeoutError):
            # Peer unavailable, skip silently.
            continue

        tools_list = catalog if isinstance(catalog, list) else catalog.get("tools", [])
        for tool in tools_list:
            if not isinstance(tool, dict):
                continue
            if matches_query(query, tool):
                tool_name = tool.get("name", "")
                results.append({
                    "name": tool_name,
                    "version": tool.get("version", "unknown"),
                    "description": tool.get("description", ""),
                    "source": f"peer:{peer_name}",
                    "installed": tool_name in installed_names,
                })

    return results


def _parse_skill_md_simple(path: Path) -> dict:
    """Minimal YAML frontmatter parser for name/description/version."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {}

    if not text.startswith("---"):
        return {}

    end = text.find("---", 3)
    if end < 0:
        return {}

    result = {}
    for line in text[3:end].strip().splitlines():
        line = line.strip()
        if ":" in line and not line.startswith("#"):
            key, _, val = line.partition(":")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key in ("name", "description", "version"):
                result[key] = val
    return result


def search_tools(query: str, scope: str = "local") -> dict:
    """Search for tools matching the query within the given scope."""
    registry = load_registry()
    installed_names = set(registry.get("tools", {}).keys())

    all_results = []

    # Always include local results.
    if scope in ("local", "all"):
        all_results.extend(search_local(query, registry))

    # Include peer results when requested.
    if scope in ("peers", "all"):
        peer_results = search_peers(query, installed_names)
        all_results.extend(peer_results)

    # De-duplicate by name (prefer local over peer).
    seen = set()
    deduped = []
    for r in all_results:
        key = r["name"]
        if key not in seen:
            seen.add(key)
            deduped.append(r)

    return {
        "ok": True,
        "query": query,
        "scope": scope,
        "results": deduped,
        "count": len(deduped),
    }


def main() -> int:
    try:
        payload = sys.stdin.read().strip()
        if not payload:
            print(json.dumps({"ok": False, "error": "empty request"}))
            return 1

        request = json.loads(payload)
    except json.JSONDecodeError:
        print(json.dumps({"ok": False, "error": "invalid JSON input"}))
        return 1

    params = request.get("params", {})
    query = params.get("query", "")
    if not query:
        print(json.dumps({"ok": False, "error": "query parameter is required"}))
        return 1

    scope = params.get("scope", "local")
    if scope not in ("local", "peers", "all"):
        print(json.dumps({"ok": False, "error": f"invalid scope: {scope}. Use local, peers, or all."}))
        return 1

    try:
        result = search_tools(query=query, scope=scope)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
