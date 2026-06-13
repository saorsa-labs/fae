#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["vobject>=0.9.8"]
# ///
"""Fae executable skill for CardDAV contact lookup."""

from __future__ import annotations

import base64
import html
import json
import os
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from typing import Any

import vobject


REQUIRED_ENV = ["CARDDAV_URL", "CARDDAV_USERNAME", "CARDDAV_PASSWORD"]
DAV_NS = "DAV:"
CARD_NS = "urn:ietf:params:xml:ns:carddav"


def emit(result: dict[str, Any], status: int = 0) -> int:
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), default=str))
    return status


def read_request() -> dict[str, Any]:
    payload = sys.stdin.read().strip()
    if not payload:
        raise ValueError("empty request")
    request = json.loads(payload)
    params = request.get("params") or {}
    if not isinstance(params, dict):
        raise ValueError("params must be an object")
    return params


def env_status() -> dict[str, bool]:
    return {name: bool(os.environ.get(name)) for name in REQUIRED_ENV}


def missing_env() -> list[str]:
    return [name for name in REQUIRED_ENV if not os.environ.get(name)]


def status() -> dict[str, Any]:
    missing = missing_env()
    return {
        "ok": True,
        "ready": not missing,
        "state": "ready" if not missing else "missing_env",
        "required_env_present": env_status(),
        "missing_env": missing,
    }


def require_env() -> tuple[str, str, str]:
    missing = missing_env()
    if missing:
        raise ValueError("missing required environment variables: " + ", ".join(missing))
    return (
        os.environ["CARDDAV_URL"],
        os.environ["CARDDAV_USERNAME"],
        os.environ["CARDDAV_PASSWORD"],
    )


def auth_header(username: str, password: str) -> str:
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return f"Basic {token}"


def request_xml(url: str, method: str, body: str, *, depth: str = "1") -> bytes:
    _, username, password = require_env()
    data = body.encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", auth_header(username, password))
    request.add_header("Content-Type", "application/xml; charset=utf-8")
    request.add_header("Depth", depth)
    request.add_header("User-Agent", "Fae contacts-carddav skill")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")[:1000]
        raise RuntimeError(f"CardDAV HTTP {exc.code}: {details}") from exc


def addressbook_url(params: dict[str, Any]) -> str:
    env_url, _, _ = require_env()
    url = str(params.get("url") or env_url).strip()
    if not url:
        raise ValueError("CARDDAV_URL is required")
    return url


def report_body(query: str) -> str:
    escaped = html.escape(query, quote=True)
    if escaped:
        filter_xml = f"""
      <card:filter test="anyof">
        <card:prop-filter name="FN"><card:text-match collation="i;unicode-casemap" match-type="contains">{escaped}</card:text-match></card:prop-filter>
        <card:prop-filter name="N"><card:text-match collation="i;unicode-casemap" match-type="contains">{escaped}</card:text-match></card:prop-filter>
        <card:prop-filter name="EMAIL"><card:text-match collation="i;unicode-casemap" match-type="contains">{escaped}</card:text-match></card:prop-filter>
        <card:prop-filter name="TEL"><card:text-match collation="i;unicode-casemap" match-type="contains">{escaped}</card:text-match></card:prop-filter>
      </card:filter>"""
    else:
        filter_xml = ""
    return f"""<?xml version="1.0" encoding="utf-8" ?>
<card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
  <d:prop>
    <d:getetag />
    <card:address-data />
  </d:prop>
{filter_xml}
</card:addressbook-query>"""


def find_text(element: ET.Element, namespace: str, local: str) -> str | None:
    found = element.find(f".//{{{namespace}}}{local}")
    if found is not None and found.text:
        return found.text
    for child in element.iter():
        if child.tag.endswith("}" + local) and child.text:
            return child.text
    return None


def parse_multistatus(payload: bytes) -> list[dict[str, str]]:
    root = ET.fromstring(payload)
    responses = []
    for response in root.findall(f".//{{{DAV_NS}}}response"):
        href = find_text(response, DAV_NS, "href") or ""
        etag = find_text(response, DAV_NS, "getetag") or ""
        card = find_text(response, CARD_NS, "address-data") or ""
        if card:
            responses.append({"href": href, "etag": etag, "vcard": card})
    if not responses:
        for response in root.iter():
            if response.tag.endswith("}response"):
                href = find_text(response, DAV_NS, "href") or ""
                card = find_text(response, CARD_NS, "address-data") or ""
                if card:
                    responses.append({"href": href, "etag": "", "vcard": card})
    return responses


def first_values(card: Any, name: str) -> list[str]:
    values = []
    for item in card.contents.get(name, []):
        value = getattr(item, "value", None)
        if value:
            values.append(str(value))
    return values


def contact_summary(item: dict[str, str]) -> dict[str, Any]:
    card = vobject.readOne(item["vcard"])
    full_name = first_values(card, "fn")
    emails = first_values(card, "email")
    phones = first_values(card, "tel")
    org_values = first_values(card, "org")
    org = org_values[0] if org_values else None
    if isinstance(org, list):
        org = " ".join(str(part) for part in org)
    return {
        "href": item.get("href"),
        "etag": item.get("etag"),
        "name": full_name[0] if full_name else "",
        "emails": emails,
        "phones": phones,
        "organization": org,
    }


def search(params: dict[str, Any]) -> dict[str, Any]:
    query = str(params.get("query") or "").strip()
    if not query:
        raise ValueError("query is required")
    try:
        limit = int(params.get("limit") or 10)
    except (TypeError, ValueError):
        limit = 10
    limit = max(1, min(50, limit))
    payload = request_xml(addressbook_url(params), "REPORT", report_body(query), depth="1")
    contacts = [contact_summary(item) for item in parse_multistatus(payload)]
    return {"ok": True, "query": query, "count": len(contacts[:limit]), "contacts": contacts[:limit]}


def raw_report(params: dict[str, Any]) -> dict[str, Any]:
    query = str(params.get("query") or "").strip()
    if not query:
        raise ValueError("query is required")
    payload = request_xml(addressbook_url(params), "REPORT", report_body(query), depth="1")
    entries = parse_multistatus(payload)
    return {
        "ok": True,
        "query": query,
        "entries": [{"href": item.get("href"), "etag": item.get("etag"), "vcard_bytes": len(item.get("vcard", ""))} for item in entries[:20]],
        "total_entries": len(entries),
    }


def dispatch(params: dict[str, Any]) -> dict[str, Any]:
    action = str(params.get("action") or "status").strip()
    if action == "status":
        return status()
    if action == "search":
        return search(params)
    if action == "raw_report":
        return raw_report(params)
    return {"ok": False, "error": f"unsupported action: {action}"}


def main() -> int:
    try:
        result = dispatch(read_request())
        return emit(result, status=0 if result.get("ok") else 1)
    except Exception as exc:  # noqa: BLE001 - skill boundary returns structured JSON.
        return emit({"ok": False, "error": str(exc), "required_env_present": env_status()}, status=1)


if __name__ == "__main__":
    raise SystemExit(main())
