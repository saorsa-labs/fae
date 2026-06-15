#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["keyring>=24.0.0"]
# ///
"""Portable Fae connect-account flow — the single cross-platform engine
(macOS + Linux) for connecting the user's mail/calendar/contacts.

Derives a full mail/calendar/contacts configuration from the user's email plus
ONE app-specific password, stores everything in the system keyring (macOS
Keychain / Linux SecretService) + a himalaya config, and verifies mail live. On
macOS the keyring items are written under the same service/account the Swift
productivity skills read via `CredentialManager`, so the two interoperate.

Secret hygiene (the whole point of this feature):
- The password is NEVER read from argv or the request JSON. It comes from the
  `FAE_APP_PASSWORD` environment variable (injected by a secure runner) or, when
  absent and a terminal is attached, from `getpass` on the controlling tty.
- It is written only to the keyring and into the himalaya child process env; it
  is never printed, logged, or echoed back.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import webbrowser
from pathlib import Path
from typing import Any

import keyring

SERVICE = "com.saorsalabs.fae"
PASSWORD_ENV = "FAE_APP_PASSWORD"
HIMALAYA_PASSWORD_ENV = "HIMALAYA_PASSWORD"
HIMALAYA_ACCOUNT = "personal"

ICLOUD_DOMAINS = {"icloud.com", "me.com", "mac.com"}
GMAIL_DOMAINS = {"gmail.com", "googlemail.com"}

# Keychain/keyring keys — identical to Swift `AccountCredentialKeys`.
KEY_MAIL_PASSWORD = "productivity.mail.personal.password"
KEY_CAL_URL = "productivity.calendar.url"
KEY_CAL_USER = "productivity.calendar.username"
KEY_CAL_PASSWORD = "productivity.calendar.password"
KEY_CON_URL = "productivity.contacts.url"
KEY_CON_USER = "productivity.contacts.username"
KEY_CON_PASSWORD = "productivity.contacts.password"

ICLOUD = {
    "imap_host": "imap.mail.me.com",
    "imap_port": 993,
    "smtp_host": "smtp.mail.me.com",
    "smtp_port": 587,
    "caldav_url": "https://caldav.icloud.com",
    "carddav_url": "https://contacts.icloud.com",
}
ICLOUD_FOLDER_ALIASES = [
    ("inbox", "INBOX"),
    ("sent", "Sent Messages"),
    ("drafts", "Drafts"),
    ("trash", "Deleted Messages"),
]
GENERIC_FOLDER_ALIASES = [
    ("inbox", "INBOX"),
    ("sent", "Sent"),
    ("drafts", "Drafts"),
    ("trash", "Trash"),
]

GMAIL = {
    "imap_host": "imap.gmail.com",
    "imap_port": 993,
    "smtp_host": "smtp.gmail.com",
    "smtp_port": 587,
}
# Gmail's server folders differ from himalaya's canonical names; using the wrong
# aliases makes save-to-Sent fail AFTER SMTP delivery (duplicate-send risk).
GMAIL_FOLDER_ALIASES = [
    ("inbox", "INBOX"),
    ("sent", "[Gmail]/Sent Mail"),
    ("drafts", "[Gmail]/Drafts"),
    ("trash", "[Gmail]/Trash"),
]

# Capabilities that need a credential, per provider. iCloud/generic do all three
# over IMAP/CalDAV/CardDAV; Gmail does mail only here — Google calendar/contacts
# need OAuth (app-password CalDAV/CardDAV is deprecated), reserved for later.
def credentialed_capabilities(provider: str) -> list[str]:
    if provider == "gmail":
        return ["mail"]
    return ["mail", "calendar", "contacts"]

# Pinned himalaya release. Fae installs himalaya herself so a normal user never
# touches a terminal. Portable on every OS: download the pinned release archive,
# verify its SHA-256 against the digests below (published by the GitHub release
# API), and drop the binary in ~/.local/bin (already on Fae's PATH). Bump the
# version + digests together, like models.lock.
HIMALAYA_VERSION = "1.2.0"
HIMALAYA_RELEASE_BASE = (
    f"https://github.com/pimalaya/himalaya/releases/download/v{HIMALAYA_VERSION}"
)
HIMALAYA_DIGESTS = {
    "himalaya.aarch64-darwin.tgz": "f70230f4d92b5bdc505e0b482db32d587d28252173a34227d6167c109bfa64f7",
    "himalaya.x86_64-darwin.tgz": "4dd2aef8e9e0bbf20bd4aaa2db9b634377c0341070c52c0e182fd615324a6378",
    "himalaya.aarch64-linux.tgz": "643020b220991fac67726f3be11310fcf806e757feadbbab3efbddd713597872",
    "himalaya.x86_64-linux.tgz": "e04e6382e3e664ef34b01afa1a2216113194a2975d2859727647b22d9b36d4e4",
    "himalaya.armv7l-linux.tgz": "dfcb8e77d478ccae32a9b869e4e4899400435c3ba0c8bf7ed237c88d69efe89e",
    "himalaya.armv6l-linux.tgz": "1c398356bb5711bc8c3f5eff2d9d0b0fc1c35d654d0071df6923971354b5b385",
    "himalaya.i686-linux.tgz": "6f8a67b0d439418fcd22a4171c1a373d9f4306be5c61ed0e9ff29f7a2cfec083",
    "himalaya.x86_64-windows.tgz": "9bf560bf13346506a71d07b69cf2efb93c6cf60828784a8b7c0cb79b295a77db",
}


def emit(result: dict[str, Any], status: int = 0) -> int:
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), default=str))
    return status


def read_request() -> dict[str, Any]:
    payload = sys.stdin.read().strip()
    if not payload:
        return {}
    request = json.loads(payload)
    params = request.get("params") or request
    if not isinstance(params, dict):
        raise ValueError("params must be an object")
    return params


# ---------------------------------------------------------------------------
# Derivation
# ---------------------------------------------------------------------------


def detect_provider(email: str) -> str:
    parts = email.split("@")
    domain = parts[-1].strip().lower() if len(parts) > 1 and parts[-1] else ""
    if domain in ICLOUD_DOMAINS:
        return "icloud"
    if domain in GMAIL_DOMAINS:
        return "gmail"
    return "generic"


def toml_string(value: str) -> str:
    """TOML basic string with spec-compliant escaping (mirror of Swift)."""
    out = ['"']
    for ch in value:
        code = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\b":
            out.append("\\b")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\f":
            out.append("\\f")
        elif ch == "\r":
            out.append("\\r")
        elif code < 0x20 or code == 0x7F:
            out.append(f"\\u{code:04X}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def himalaya_toml(
    email: str,
    login: str,
    imap_host: str,
    imap_port: int,
    smtp_host: str,
    smtp_port: int,
    folder_aliases: list[tuple[str, str]],
) -> str:
    auth_cmd = "'printf %s \"$" + HIMALAYA_PASSWORD_ENV + "\"'"
    lines = [
        f"[accounts.{HIMALAYA_ACCOUNT}]",
        f"email = {toml_string(email)}",
        f"display-name = {toml_string(email)}",
        "default = true",
        "",
        'backend.type = "imap"',
        f"backend.host = {toml_string(imap_host)}",
        f"backend.port = {imap_port}",
        'backend.encryption.type = "tls"',
        f"backend.login = {toml_string(login)}",
        'backend.auth.type = "password"',
        f"backend.auth.cmd = {auth_cmd}",
        "",
        'message.send.backend.type = "smtp"',
        f"message.send.backend.host = {toml_string(smtp_host)}",
        f"message.send.backend.port = {smtp_port}",
        'message.send.backend.encryption.type = "start-tls"',
        f"message.send.backend.login = {toml_string(login)}",
        'message.send.backend.auth.type = "password"',
        f"message.send.backend.auth.cmd = {auth_cmd}",
        "",
    ]
    for canonical, server in folder_aliases:
        lines.append(f"folder.aliases.{canonical} = {toml_string(server)}")
    return "\n".join(lines) + "\n"


def derive(email: str, provider: str, primary_apple_id: str | None) -> dict[str, Any]:
    """Return the non-secret derived config (no password material)."""
    if provider == "icloud":
        login = (primary_apple_id or "").strip() or email
        toml = himalaya_toml(
            email, login,
            ICLOUD["imap_host"], ICLOUD["imap_port"],
            ICLOUD["smtp_host"], ICLOUD["smtp_port"],
            ICLOUD_FOLDER_ALIASES,
        )
        public = {
            KEY_CAL_URL: ICLOUD["caldav_url"],
            KEY_CAL_USER: login,
            KEY_CON_URL: ICLOUD["carddav_url"],
            KEY_CON_USER: login,
        }
        secret_keys = [KEY_MAIL_PASSWORD, KEY_CAL_PASSWORD, KEY_CON_PASSWORD]
    elif provider == "gmail":
        # Mail only: Google calendar/contacts need OAuth (app-password CalDAV/
        # CardDAV is deprecated), reserved for a later OAuth method.
        login = email
        toml = himalaya_toml(
            email, login,
            GMAIL["imap_host"], GMAIL["imap_port"],
            GMAIL["smtp_host"], GMAIL["smtp_port"],
            GMAIL_FOLDER_ALIASES,
        )
        public = {}
        secret_keys = [KEY_MAIL_PASSWORD]
    else:
        login = email
        domain = email.split("@")[-1].lower() if "@" in email else email
        toml = himalaya_toml(
            email, login,
            f"imap.{domain}", 993,
            f"smtp.{domain}", 587,
            GENERIC_FOLDER_ALIASES,
        )
        public = {
            KEY_CAL_URL: f"https://caldav.{domain}",
            KEY_CAL_USER: login,
            KEY_CON_URL: f"https://carddav.{domain}",
            KEY_CON_USER: login,
        }
        secret_keys = [KEY_MAIL_PASSWORD, KEY_CAL_PASSWORD, KEY_CON_PASSWORD]
    return {
        "provider": provider,
        "login": login,
        "public_keychain_entries": public,
        "secret_keychain_keys": secret_keys,
        "himalaya_account": HIMALAYA_ACCOUNT,
        "himalaya_toml": toml,
    }


# ---------------------------------------------------------------------------
# Filesystem / keyring helpers
# ---------------------------------------------------------------------------


def himalaya_config_path() -> Path:
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = Path(xdg) if xdg else Path.home() / ".config"
    return base / "himalaya" / "config.toml"


def keyring_backend_name() -> str:
    try:
        return type(keyring.get_keyring()).__name__
    except Exception:  # noqa: BLE001
        return "unknown"


def secure_password() -> str | None:
    """Read the password from env first, then the tty. Never argv/JSON."""
    env_val = os.environ.get(PASSWORD_ENV)
    if env_val:
        return env_val
    if sys.stdin.isatty() or os.path.exists("/dev/tty"):
        try:
            import getpass

            return getpass.getpass("Paste the app-specific password (hidden): ")
        except Exception:  # noqa: BLE001
            return None
    return None


# ---------------------------------------------------------------------------
# himalaya installer (Fae installs her own mail CLI, portably)
# ---------------------------------------------------------------------------


def local_bin() -> Path:
    path = Path.home() / ".local" / "bin"
    path.mkdir(parents=True, exist_ok=True)
    return path


def find_himalaya() -> str | None:
    """Locate himalaya on PATH or in the usual install dirs (the subprocess PATH
    may omit ~/.local/bin)."""
    found = shutil.which("himalaya")
    if found:
        return found
    for directory in (
        Path.home() / ".local" / "bin",
        Path.home() / ".cargo" / "bin",
        Path("/opt/homebrew/bin"),
        Path("/usr/local/bin"),
        Path("/usr/bin"),
    ):
        candidate = directory / "himalaya"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def himalaya_asset_name() -> str | None:
    os_part = {"darwin": "darwin", "linux": "linux", "windows": "windows"}.get(
        platform.system().lower()
    )
    arch_part = {
        "arm64": "aarch64", "aarch64": "aarch64",
        "x86_64": "x86_64", "amd64": "x86_64",
        "armv7l": "armv7l", "armv6l": "armv6l",
        "i686": "i686", "i386": "i686",
    }.get(platform.machine().lower())
    if os_part is None or arch_part is None:
        return None
    return f"himalaya.{arch_part}-{os_part}.tgz"


def install_himalaya() -> dict[str, Any]:
    """Download the pinned himalaya release, verify its SHA-256, and drop the
    binary into ~/.local/bin. Fails loud on an unsupported platform, a checksum
    mismatch, or a network error — never installs unverified bytes."""
    asset = himalaya_asset_name()
    if asset is None or asset not in HIMALAYA_DIGESTS:
        return {"ok": False, "detail": f"no pinned himalaya build for {platform.system()}/{platform.machine()}"}
    url = f"{HIMALAYA_RELEASE_BASE}/{asset}"
    expected = HIMALAYA_DIGESTS[asset]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / asset
            with urllib.request.urlopen(url, timeout=60) as resp:  # noqa: S310 - pinned https URL, verified below
                archive.write_bytes(resp.read())
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            if digest != expected:
                return {"ok": False, "detail": f"checksum mismatch for {asset} — refusing to install"}
            dest = local_bin() / "himalaya"
            with tarfile.open(archive, "r:gz") as tar:
                member = next(
                    (m for m in tar.getmembers() if m.isfile() and Path(m.name).name == "himalaya"),
                    None,
                )
                if member is None:
                    return {"ok": False, "detail": "himalaya binary not found in the archive"}
                extracted = tar.extractfile(member)
                if extracted is None:
                    return {"ok": False, "detail": "could not read himalaya binary from the archive"}
                dest.write_bytes(extracted.read())
            dest.chmod(0o755)
        return {"ok": True, "detail": f"installed himalaya {HIMALAYA_VERSION}", "path": str(dest)}
    except Exception as exc:  # noqa: BLE001 - network/IO boundary returns structured failure
        return {"ok": False, "detail": f"download/install failed: {exc}"}


def ensure_himalaya() -> dict[str, Any]:
    """Make himalaya available, installing it if missing."""
    existing = find_himalaya()
    if existing:
        return {"ok": True, "detail": "already installed", "path": existing, "installed_now": False}
    result = install_himalaya()
    result["installed_now"] = bool(result.get("ok"))
    return result


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------


def setup_page_url(provider: str) -> str | None:
    if provider == "icloud":
        return "https://account.apple.com"
    if provider == "gmail":
        return "https://myaccount.google.com/apppasswords"
    return None


def guidance(provider: str) -> str:
    if provider == "icloud":
        return (
            "Open account.apple.com, sign in, go to Sign-In and Security -> "
            "App-Specific Passwords, add one named 'Fae', and paste it when asked. "
            "It goes straight to your keyring, never into chat."
        )
    if provider == "gmail":
        return (
            "Open myaccount.google.com/apppasswords (you'll need 2-Step "
            "Verification on), create an app password named 'Fae', and paste it "
            "when asked. It goes straight to your keyring, never into chat."
        )
    return (
        "Create an app-specific password in your mail provider's security "
        "settings, name it 'Fae', and paste it when asked. It goes straight to "
        "your keyring, never into chat."
    )


def action_start(params: dict[str, Any]) -> dict[str, Any]:
    email = str(params.get("email") or "").strip()
    if not email:
        return {"ok": False, "error": "email is required"}
    provider = str(params.get("provider") or "").strip().lower() or detect_provider(email)
    page = setup_page_url(provider)
    if params.get("open_page") and page:
        try:
            webbrowser.open(page)
        except Exception:  # noqa: BLE001
            pass
    return {
        "ok": True,
        "action": "start",
        "provider": provider,
        "needs_credential": True,
        "capture_env": PASSWORD_ENV,
        "setup_page_url": page,
        "guidance": guidance(provider),
        "credentialed_capabilities": credentialed_capabilities(provider),
        "may_be_icloud_custom_domain": provider == "generic" and not params.get("provider"),
        "next": (
            f"Set {PASSWORD_ENV} securely (or run interactively for a hidden "
            "prompt), then call action 'connect' with the same email."
        ),
    }


def action_status() -> dict[str, Any]:
    cfg = himalaya_config_path()
    himalaya = find_himalaya()
    return {
        "ok": True,
        "action": "status",
        "himalaya_installed": himalaya is not None,
        "himalaya_path": himalaya,
        "himalaya_pinned_version": HIMALAYA_VERSION,
        "keyring_backend": keyring_backend_name(),
        "himalaya_config_exists": cfg.exists(),
        "himalaya_config_path": str(cfg),
    }


def action_ensure_tools() -> dict[str, Any]:
    """Make sure himalaya (the mail CLI) is installed — Fae installs it herself."""
    result = ensure_himalaya()
    return {"ok": bool(result.get("ok")), "action": "ensure_tools", "himalaya": result}


def action_selftest() -> dict[str, Any]:
    """Validate derivation without any account, secret, or network."""
    checks: list[tuple[str, bool]] = []
    ic = derive("jane@icloud.com", "icloud", None)
    checks.append(("icloud imap host", 'backend.host = "imap.mail.me.com"' in ic["himalaya_toml"]))
    checks.append(("icloud smtp host", 'message.send.backend.host = "smtp.mail.me.com"' in ic["himalaya_toml"]))
    checks.append(("auth via env, not raw", "auth.cmd = 'printf %s \"$HIMALAYA_PASSWORD\"'" in ic["himalaya_toml"]))
    checks.append(("no auth.raw", "auth.raw" not in ic["himalaya_toml"]))
    checks.append(("icloud caldav", ic["public_keychain_entries"][KEY_CAL_URL] == "https://caldav.icloud.com"))
    checks.append(("icloud carddav", ic["public_keychain_entries"][KEY_CON_URL] == "https://contacts.icloud.com"))
    checks.append(("3 secret keys", ic["secret_keychain_keys"] == [KEY_MAIL_PASSWORD, KEY_CAL_PASSWORD, KEY_CON_PASSWORD]))
    cd = derive("jane@her-own-domain.dev", "icloud", "jane@icloud.com")
    checks.append(("custom-domain from-addr keeps alias", 'email = "jane@her-own-domain.dev"' in cd["himalaya_toml"]))
    checks.append(("custom-domain auth uses primary", 'backend.login = "jane@icloud.com"' in cd["himalaya_toml"]))
    gen = derive("jane@fastmail.com", "generic", None)
    checks.append(("generic imap host", 'backend.host = "imap.fastmail.com"' in gen["himalaya_toml"]))
    # Gmail: detected, imap.gmail.com, [Gmail]/ folder aliases, mail-only.
    checks.append(("detect gmail", detect_provider("jane@gmail.com") == "gmail"))
    gm = derive("jane@gmail.com", "gmail", None)
    checks.append(("gmail imap host", 'backend.host = "imap.gmail.com"' in gm["himalaya_toml"]))
    checks.append(("gmail sent folder alias", 'folder.aliases.sent = "[Gmail]/Sent Mail"' in gm["himalaya_toml"]))
    checks.append(("gmail is mail-only", gm["secret_keychain_keys"] == [KEY_MAIL_PASSWORD] and gm["public_keychain_entries"] == {}))
    checks.append(("gmail credentialed caps", credentialed_capabilities("gmail") == ["mail"]))
    # Control-char escaping (mirror of Swift TOML hardening).
    checks.append(("toml escapes newline", toml_string("a\nb") == '"a\\nb"'))
    failed = [name for name, ok in checks if not ok]
    return {
        "ok": not failed,
        "action": "selftest",
        "passed": len(checks) - len(failed),
        "total": len(checks),
        "failed": failed,
    }


def _write_config(path: Path, contents: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass


def _verify_mail(config: dict[str, Any], password: str) -> dict[str, Any]:
    binary = find_himalaya()
    if binary is None:
        # Infrastructure gap, not a bad credential — caller treats this as
        # "deferred" (no rollback of a possibly-correct password).
        return {"capability": "mail", "state": "deferred", "detail": "himalaya unavailable"}
    env = os.environ.copy()
    env[HIMALAYA_PASSWORD_ENV] = password
    try:
        proc = subprocess.run(
            [binary, "--config", str(himalaya_config_path()),
             "--account", config["himalaya_account"],
             "--json", "envelope", "list", "-m", "INBOX"],
            capture_output=True, text=True, timeout=90, check=False, env=env,
        )
    except subprocess.TimeoutExpired:
        return {"capability": "mail", "state": "failed", "detail": "himalaya timed out"}
    if proc.returncode != 0:
        # Never surface stderr — it can mention secrets.
        return {"capability": "mail", "state": "failed", "detail": "mail login failed — check the app-specific password or 2FA"}
    count = 0
    try:
        obj = json.loads(proc.stdout)
        if isinstance(obj, dict) and isinstance(obj.get("envelopes"), list):
            count = len(obj["envelopes"])
        elif isinstance(obj, list):
            count = len(obj)
    except json.JSONDecodeError:
        count = 0
    return {"capability": "mail", "state": "verified", "detail": f"{count} inbox messages"}


def action_connect(params: dict[str, Any]) -> dict[str, Any]:
    email = str(params.get("email") or "").strip()
    if not email:
        return {"ok": False, "error": "email is required"}
    provider = str(params.get("provider") or "").strip().lower() or detect_provider(email)
    primary = str(params.get("primary_apple_id") or "").strip() or None

    password = secure_password()
    if not password:
        return {
            "ok": False,
            "error": f"no password available — set {PASSWORD_ENV} securely or run interactively",
        }

    config = derive(email, provider, primary)
    cfg_path = himalaya_config_path()

    # Capture prior state for rollback.
    all_keys = list(config["public_keychain_entries"].keys()) + config["secret_keychain_keys"]
    prior_values = {k: keyring.get_password(SERVICE, k) for k in all_keys}
    prior_config = cfg_path.read_text(encoding="utf-8") if cfg_path.exists() else None

    # Apply: public entries, password fanned to every secret key, himalaya config.
    for key, value in config["public_keychain_entries"].items():
        keyring.set_password(SERVICE, key, value)
    for key in config["secret_keychain_keys"]:
        keyring.set_password(SERVICE, key, password)
    _write_config(cfg_path, config["himalaya_toml"])

    # Fae installs himalaya herself if it's missing, then verifies mail live
    # (calendar/contacts are verified by their own skills). A failed *install*
    # (offline / unsupported arch) defers mail verification — it never rolls back
    # a possibly-correct password; only a real auth failure does.
    install = ensure_himalaya()
    outcome = _verify_mail(config, password)
    if outcome["state"] == "deferred" and not install.get("ok"):
        outcome["detail"] = f"mail stored but not verified — {install.get('detail', 'himalaya unavailable')}"

    if outcome["state"] == "failed":
        # Roll back to exact prior state.
        for key, prior in prior_values.items():
            if prior is None:
                try:
                    keyring.delete_password(SERVICE, key)
                except keyring.errors.PasswordDeleteError:
                    pass
            else:
                keyring.set_password(SERVICE, key, prior)
        if prior_config is None:
            cfg_path.unlink(missing_ok=True)
        else:
            _write_config(cfg_path, prior_config)
        return {
            "ok": False,
            "action": "connect",
            "provider": provider,
            "rolled_back": True,
            "outcomes": [outcome],
            "summary": f"Couldn't connect — {outcome['detail']}. Rolled everything back.",
            "keyring_backend": keyring_backend_name(),
        }

    has_cal_con = len(config["secret_keychain_keys"]) > 1
    if outcome["state"] == "verified":
        summary = f"Connected — mail verified ({outcome['detail']})."
        if has_cal_con:
            summary += (
                " Calendar and contacts stored; verify them with the "
                "calendar/contacts skills."
            )
    else:  # deferred
        summary = (
            f"Stored your account — {outcome['detail']}. Mail will verify once "
            "himalaya is available. Calendar and contacts are stored too."
        )
    return {
        "ok": True,
        "action": "connect",
        "provider": provider,
        "rolled_back": False,
        "outcomes": [outcome],
        "summary": summary,
        "keyring_backend": keyring_backend_name(),
    }


def main() -> int:
    try:
        params = read_request()
        action = str(params.get("action") or "status").strip().lower()
        if action == "start":
            return emit(action_start(params))
        if action == "connect":
            return emit(action_connect(params))
        if action == "status":
            return emit(action_status())
        if action == "ensure_tools":
            result = action_ensure_tools()
            return emit(result, status=0 if result["ok"] else 1)
        if action == "selftest":
            result = action_selftest()
            return emit(result, status=0 if result["ok"] else 1)
        return emit({"ok": False, "error": f"unsupported action: {action}"}, status=1)
    except Exception as exc:  # noqa: BLE001 - skill boundary returns structured JSON
        return emit({"ok": False, "error": str(exc)}, status=1)


if __name__ == "__main__":
    raise SystemExit(main())
