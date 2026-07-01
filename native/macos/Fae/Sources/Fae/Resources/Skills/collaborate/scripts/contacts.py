#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Manage x0x contacts — the people and agents the user is connected to.

This is how Fae connects the user to other humans AND their agents: import a
person's agent card, or add an agent_id directly, and set a trust level.

Actions (params.action):
  list   (default) — list contacts.
  mycard — produce the user's OWN shareable card link and show it on screen, so
           they can hand their identity to someone out-of-band (optional display_name).
  import — import a peer's agent card (param: card; optional trust_level).
  add    — add a contact by agent_id (param: agent_id; optional trust_level, label).
  trust  — set the trust level of a known agent_id (params: agent_id, level).
"""

import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
import webbrowser
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, read_params, emit, fail  # noqa: E402

TRUST_LEVELS = ("blocked", "unknown", "known", "trusted")

# Where the x0x CLI commonly lives (the shareable card link is produced by the
# CLI, which emits x0x's own canonical, signed serialization — reconstructing it
# from REST would risk breaking the card signature).
EXTRA_BIN_DIRS = [
    os.path.expanduser("~/.cargo/bin"),
    os.path.expanduser("~/.local/bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
]


def find_x0x() -> str | None:
    found = shutil.which("x0x")
    if found:
        return found
    for d in EXTRA_BIN_DIRS:
        candidate = os.path.join(d, "x0x")
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def open_url(url: str) -> bool:
    try:
        if webbrowser.open(url):
            return True
    except (webbrowser.Error, OSError):
        pass
    if sys.platform == "darwin":
        try:
            subprocess.run(["open", url], check=True, timeout=10)
            return True
        except (subprocess.SubprocessError, OSError):
            return False
    return False


def is_hex64(s: str) -> bool:
    return isinstance(s, str) and len(s) == 64 and all(c in "0123456789abcdef" for c in s)


def do_list(client: X0x) -> dict:
    resp = client.get("/contacts")
    contacts = resp.get("contacts", []) or []
    labels = []
    for c in contacts[:5]:
        name = c.get("label") or (c.get("agent_id", "")[:12] + "…")
        labels.append(f"{name} ({c.get('trust_level', '?')})")
    if contacts:
        summary = f"{len(contacts)} contact(s): " + ", ".join(labels)
        if len(contacts) > 5:
            summary += ", …"
    else:
        summary = "No contacts yet."
    return {"ok": True, "contacts": contacts, "count": len(contacts), "summary": summary}


def _card_html(display_name: str, agent_id: str, link: str) -> str:
    """A small self-contained page that shows the user's shareable card link.

    The 20 KB link lives HERE (copyable on screen), never in Fae's context.
    """
    name = html.escape(display_name) if display_name else "Your"
    aid = html.escape(agent_id)
    safe_link = html.escape(link)
    title = f"{name} x0x card" if display_name else "Your x0x card"
    return f"""<!doctype html><html><head><meta charset="utf-8">
<title>{title}</title>
<style>
  body{{font-family:-apple-system,system-ui,sans-serif;max-width:680px;margin:40px auto;
       padding:0 20px;color:#1d2733;background:#f6f8fa}}
  .card{{background:#fff;border:1px solid #d8dee4;border-radius:14px;padding:28px}}
  h1{{font-size:22px;margin:0 0 4px}} .sub{{color:#5b6876;margin:0 0 20px}}
  .id{{font-family:ui-monospace,Menlo,monospace;font-size:13px;color:#3b4a59;
       word-break:break-all;background:#f0f3f6;padding:8px 10px;border-radius:8px}}
  textarea{{width:100%;height:120px;margin-top:14px;font-family:ui-monospace,Menlo,monospace;
       font-size:11px;border:1px solid #d8dee4;border-radius:8px;padding:10px;box-sizing:border-box}}
  button{{margin-top:12px;padding:10px 18px;font-size:15px;border:0;border-radius:9px;
       background:#2f6f4f;color:#fff;cursor:pointer}}
  .hint{{margin-top:18px;color:#5b6876;font-size:14px;line-height:1.5}}
</style></head><body>
<div class="card">
  <h1>{title}</h1>
  <p class="sub">Share this with the person (or agent) you want to collaborate with.
     They import it and you're connected — both ways.</p>
  <div class="id"><b>agent id:</b> {aid}</div>
  <textarea id="lnk" readonly onclick="this.select()">{safe_link}</textarea>
  <button onclick="navigator.clipboard.writeText(document.getElementById('lnk').value);
     this.textContent='Copied ✓'">Copy link</button>
  <p class="hint">Send it however you like — message, email, AirDrop. On their side they run
     <code>x0x agent import &lt;link&gt;</code> or ask their Fae to import it.</p>
</div></body></html>"""


def do_mycard(client: X0x, params: dict) -> dict:
    agent = client.get("/agent")
    agent_id = agent.get("agent_id") or ""
    display_name = (params.get("display_name") or "").strip()

    binary = find_x0x()
    if not binary:
        raise X0xError(
            "x0x is not installed, so I can't generate your shareable card link. "
            "Let's get x0x set up first.")
    argv = [binary]
    instance = params.get("instance")
    if instance:
        argv += ["--name", instance]
    argv += ["agent", "card"]
    if display_name:
        argv += [display_name]
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=20, check=False)
    except (subprocess.SubprocessError, OSError) as e:
        raise X0xError(f"I couldn't generate your card: {e}")
    match = re.search(r"x0x://agent/[A-Za-z0-9_\-]+", proc.stdout)
    if not match:
        raise X0xError("x0x didn't return a shareable card link — is the daemon running?")
    link = match.group(0)

    # Render + open the on-screen card. The link stays in the page, not in the result.
    cache = (Path(os.path.expanduser("~/Library/Caches/Fae/render"))
             if sys.platform == "darwin" else Path(tempfile.gettempdir()))
    cache.mkdir(parents=True, exist_ok=True)
    page = cache / f"x0x-card-{agent_id[:8] or 'me'}.html"
    page.write_text(_card_html(display_name, agent_id, link), encoding="utf-8")
    opened = open_url(page.as_uri())

    whose = f"{display_name}'s" if display_name else "your"
    return {
        "ok": True,
        "agent_id": agent_id,
        "display_name": display_name or None,
        "shown_on_screen": opened,
        "card_page": str(page),
        "summary": (
            f"I've put {whose} x0x card on screen — share the link with the person you "
            f"want to collaborate with, and they import it to connect. "
            f"Your agent id starts {agent_id[:12]}…."),
    }


def do_import(client: X0x, params: dict) -> dict:
    card = params.get("card")
    if not card or not isinstance(card, str):
        raise X0xError("To import a contact I need their agent card (an x0x:// link or code).")
    trust = (params.get("trust_level") or "known").strip().lower()
    if trust not in TRUST_LEVELS:
        raise X0xError(f"trust_level must be one of {', '.join(TRUST_LEVELS)}.")
    client.post("/agent/card/import", {"card": card, "trust_level": trust})
    return {
        "ok": True,
        "imported": True,
        "trust_level": trust,
        "summary": f"Imported the contact and set trust to {trust}.",
    }


def do_add(client: X0x, params: dict) -> dict:
    agent_id = (params.get("agent_id") or "").strip().lower()
    if not is_hex64(agent_id):
        raise X0xError("I need a valid 64-character agent id to add a contact.")
    trust = (params.get("trust_level") or "known").strip().lower()
    if trust not in TRUST_LEVELS:
        raise X0xError(f"trust_level must be one of {', '.join(TRUST_LEVELS)}.")
    body = {"agent_id": agent_id, "trust_level": trust}
    label = params.get("label")
    if label:
        body["label"] = str(label)
    client.post("/contacts", body)
    who = label or (agent_id[:12] + "…")
    return {
        "ok": True,
        "added": True,
        "agent_id": agent_id,
        "trust_level": trust,
        "summary": f"Added {who} as a contact ({trust}).",
    }


def do_trust(client: X0x, params: dict) -> dict:
    agent_id = (params.get("agent_id") or "").strip().lower()
    if not is_hex64(agent_id):
        raise X0xError("I need a valid 64-character agent id to set trust.")
    level = (params.get("level") or params.get("trust_level") or "").strip().lower()
    if level not in TRUST_LEVELS:
        raise X0xError(f"level must be one of {', '.join(TRUST_LEVELS)}.")
    client.post("/contacts/trust", {"agent_id": agent_id, "level": level})
    return {
        "ok": True,
        "agent_id": agent_id,
        "level": level,
        "summary": f"Set trust for {agent_id[:12]}… to {level}.",
    }


def main() -> None:
    params = read_params()
    action = (params.get("action") or "list").strip().lower()
    client = X0x(params.get("instance"))
    try:
        client.require_running()
        if action == "list":
            emit(do_list(client))
        elif action == "mycard":
            emit(do_mycard(client, params))
        elif action == "import":
            emit(do_import(client, params))
        elif action == "add":
            emit(do_add(client, params))
        elif action == "trust":
            emit(do_trust(client, params))
        else:
            fail(f"Unknown action '{action}'. Use list, mycard, import, add, or trust.")
    except X0xError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
