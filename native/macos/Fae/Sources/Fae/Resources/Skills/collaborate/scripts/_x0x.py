# Shared x0xd REST client for the Fae `collaborate` skill.
#
# This module is imported (not run) by the executable scripts in this directory.
# It deliberately uses only the Python standard library so it adds no PEP-723
# dependency and starts instantly.
#
# Contracts here are grounded in the x0x source (src/server/mod.rs, src/api/mod.rs,
# src/gui/x0x-gui.html) — see docs/plans/fae-collaborate-skill-design-2026-06-29.md.

import base64
import json
import os
import platform
import sys
import urllib.error
import urllib.request
from pathlib import Path


class X0xError(Exception):
    """A user-facing error from talking to x0xd. The message is safe to speak."""


def data_dir(instance: str | None = None) -> Path:
    """Resolve the x0x data directory for the default or a named instance.

    macOS:  ~/Library/Application Support/x0x[-<instance>]
    Linux:  ~/.local/share/x0x[-<instance>]
    """
    name = "x0x" if not instance else f"x0x-{instance}"
    home = Path(os.path.expanduser("~"))
    if platform.system() == "Darwin":
        return home / "Library" / "Application Support" / name
    return home / ".local" / "share" / name


def read_port(instance: str | None = None) -> str | None:
    """Return the daemon address (e.g. '127.0.0.1:12700') or None if not present."""
    f = data_dir(instance) / "api.port"
    try:
        return f.read_text(encoding="utf-8").strip()
    except OSError:
        return None


def read_token(instance: str | None = None) -> str | None:
    """Return the bearer token, or None if not present."""
    f = data_dir(instance) / "api-token"
    try:
        return f.read_text(encoding="utf-8").strip()
    except OSError:
        return None


def base_url(instance: str | None = None) -> str | None:
    addr = read_port(instance)
    if not addr:
        return None
    return f"http://{addr}"


class X0x:
    """Thin authenticated REST client for one x0xd instance."""

    def __init__(self, instance: str | None = None):
        self.instance = instance
        self.base = base_url(instance)
        self.token = read_token(instance)

    # ---- lifecycle / health -------------------------------------------------

    def is_running(self, timeout: float = 2.0) -> bool:
        """True if the daemon answers /health (which needs no auth)."""
        if not self.base:
            return False
        try:
            req = urllib.request.Request(f"{self.base}/health", method="GET")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = json.loads(resp.read().decode("utf-8"))
                return bool(body.get("ok"))
        except (urllib.error.URLError, OSError, ValueError):
            return False

    def require_running(self) -> None:
        if not self.base or not self.token:
            raise X0xError(
                "x0x is not set up yet — no api.port/api-token found. "
                "Run the collaborate skill's `ensure` script first."
            )
        if not self.is_running():
            raise X0xError(
                "The x0x daemon (x0xd) is not responding. "
                "Run the collaborate skill's `ensure` script to start it."
            )

    # ---- core request -------------------------------------------------------

    def call(self, method: str, path: str, body: dict | None = None,
             timeout: float = 30.0, raise_on_not_ok: bool = True) -> dict:
        """Make an authenticated request and return the parsed JSON dict.

        Raises X0xError on transport failure or non-2xx status. By default also
        raises on an `{"ok": false}` envelope; pass raise_on_not_ok=False for
        endpoints where `{"ok": false}` is a valid "not found" answer (e.g.
        /presence/find), so the caller can inspect it. The returned dict is the
        x0xd ApiResponse with `ok` flattened in.
        """
        if not self.base:
            raise X0xError("x0x is not set up (no api.port). Run `ensure` first.")
        if not self.token:
            raise X0xError("x0x api-token not found. Run `ensure` first.")

        url = f"{self.base}{path}"
        data = None
        headers = {"Authorization": f"Bearer {self.token}"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"

        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                err_body = json.loads(e.read().decode("utf-8"))
                detail = err_body.get("error") or err_body.get("message") or ""
            except (ValueError, OSError):
                detail = ""
            raise X0xError(
                f"x0x request failed ({method} {path}): HTTP {e.code}"
                + (f" — {detail}" if detail else "")
            )
        except (urllib.error.URLError, OSError) as e:
            raise X0xError(f"Could not reach x0x daemon ({method} {path}): {e}")

        if not raw:
            return {"ok": True}
        try:
            parsed = json.loads(raw)
        except ValueError:
            raise X0xError(f"x0x returned a non-JSON response for {method} {path}.")
        if raise_on_not_ok and isinstance(parsed, dict) and parsed.get("ok") is False:
            raise X0xError(parsed.get("error") or f"x0x reported failure for {method} {path}.")
        return parsed

    # convenience verbs
    def get(self, path: str, **kw) -> dict:
        return self.call("GET", path, None, **kw)

    def post(self, path: str, body: dict | None = None, **kw) -> dict:
        return self.call("POST", path, body, **kw)

    def put(self, path: str, body: dict | None = None, **kw) -> dict:
        return self.call("PUT", path, body, **kw)

    def delete(self, path: str, **kw) -> dict:
        return self.call("DELETE", path, None, **kw)


# ---- base64 helpers (publish/direct payloads are base64) --------------------

def b64(text_or_bytes) -> str:
    if isinstance(text_or_bytes, str):
        text_or_bytes = text_or_bytes.encode("utf-8")
    return base64.b64encode(text_or_bytes).decode("ascii")


def unb64(s: str) -> bytes:
    return base64.b64decode(s)


def unb64_text(s: str) -> str:
    try:
        return unb64(s).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return ""


# ---- skill IO contract (matches the `mesh` skill) ---------------------------

def read_params() -> dict:
    """Read the JSON-RPC-style request on stdin and return its `params` dict."""
    try:
        request = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return {}
    if isinstance(request, dict):
        return request.get("params", {}) or {}
    return {}


def emit(result: dict) -> None:
    """Print a JSON result object to stdout (the skill executor captures stdout)."""
    print(json.dumps(result, indent=2))


def fail(message: str) -> None:
    emit({"ok": False, "error": message})
