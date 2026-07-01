#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Open the x0x collaboration app in the user's default browser.

The GUI is served by x0xd at /gui and authenticates via a `?token=` query param
(the GUI page itself needs no Authorization header). We open the base /gui URL —
tabs are client-side, and the base URL is the reliable entry point.

The bearer token is required in the URL for the page to authenticate, but it is
NEVER returned in this script's JSON result — we redact it so it can't leak into
logs or the model's context.
"""

import os
import subprocess
import sys
import webbrowser

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, read_params, emit, fail, base_url, read_token  # noqa: E402


def open_url(url: str) -> bool:
    """Open url in the default browser. Returns True on a best-effort success."""
    try:
        if webbrowser.open(url):
            return True
    except (webbrowser.Error, OSError):
        pass
    # macOS fallback: `open <url>`.
    if sys.platform == "darwin":
        try:
            subprocess.run(["open", url], check=True, timeout=10)
            return True
        except (subprocess.SubprocessError, OSError):
            return False
    return False


def main() -> None:
    params = read_params()
    instance = params.get("instance")
    tab = params.get("tab")  # cosmetic — base /gui URL is opened regardless
    client = X0x(instance)
    try:
        client.require_running()
        base = base_url(instance)
        token = read_token(instance)
        if not base or not token:
            raise X0xError("x0x is not set up yet — run the `ensure` script first.")

        url = f"{base}/gui?token={token}"
        redacted = f"{base}/gui?token=<redacted>"

        if not open_url(url):
            raise X0xError(
                "I couldn't open your browser automatically. "
                f"You can open the app manually at {base}/gui (it needs the access token)."
            )

        where = f" to the {tab} view" if tab else ""
        emit({
            "ok": True,
            "opened": True,
            "url": redacted,
            "tab": tab,
            "instance": instance or "default",
            "summary": f"Opened the collaboration app in your browser{where}.",
        })
    except X0xError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
