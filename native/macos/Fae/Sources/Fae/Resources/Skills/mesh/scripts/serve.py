#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["zeroconf"]
# ///
"""HTTP catalog server for sharing forge-built tools with peer Fae instances."""

import json
import os
import signal
import socket
import sys
import time
from functools import partial
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from threading import Thread

FORGE_DIR = Path(os.path.expanduser("~")) / ".fae-forge"
PID_FILE = FORGE_DIR / "serve.pid"
REGISTRY_FILE = FORGE_DIR / "registry.json"
TOOLS_DIR = FORGE_DIR / "tools"
BUNDLES_DIR = FORGE_DIR / "bundles"
SERVICE_TYPE = "_fae-tools._tcp.local."


def get_instance_name() -> str:
    """Generate a friendly instance name."""
    hostname = socket.gethostname().replace(".local", "")
    return f"{hostname}'s Fae"


def load_registry() -> dict:
    """Load the tool registry."""
    if not REGISTRY_FILE.exists():
        return {"tools": {}}
    try:
        with open(REGISTRY_FILE, "r") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"tools": {}}


class CatalogHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the tool catalog."""

    def log_message(self, format: str, *args) -> None:
        """Suppress default stderr logging."""
        pass

    def send_json(self, data: dict, status: int = 200) -> None:
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path: Path, content_type: str = "application/octet-stream") -> None:
        if not path.exists():
            self.send_json({"error": "Not found"}, 404)
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        path = self.path.rstrip("/")

        if path == "/health":
            registry = load_registry()
            self.send_json({
                "ok": True,
                "name": get_instance_name(),
                "tools": len(registry.get("tools", {})),
                "version": "1.0",
            })
            return

        if path == "/catalog":
            registry = load_registry()
            tools_list = []
            for name, info in registry.get("tools", {}).items():
                tools_list.append({
                    "name": name,
                    "version": info.get("version", "0.0.0"),
                    "description": info.get("description", ""),
                    "lang": info.get("lang", "unknown"),
                    "released_at": info.get("released_at", ""),
                })
            self.send_json({"ok": True, "tools": tools_list, "count": len(tools_list)})
            return

        # /tools/{name}/metadata
        if path.startswith("/tools/") and path.endswith("/metadata"):
            parts = path.split("/")
            if len(parts) == 4:
                tool_name = parts[2]
                tool_dir = TOOLS_DIR / tool_name
                skill_md = tool_dir / "SKILL.md"
                manifest = tool_dir / "MANIFEST.json"
                if not tool_dir.exists():
                    self.send_json({"error": f"Tool '{tool_name}' not found"}, 404)
                    return
                result: dict = {"name": tool_name}
                if skill_md.exists():
                    result["skill_md"] = skill_md.read_text(encoding="utf-8")
                if manifest.exists():
                    try:
                        result["manifest"] = json.loads(manifest.read_text(encoding="utf-8"))
                    except json.JSONDecodeError:
                        result["manifest"] = None
                # Include registry info.
                registry = load_registry()
                if tool_name in registry.get("tools", {}):
                    result["registry"] = registry["tools"][tool_name]
                self.send_json({"ok": True, **result})
                return

        # /tools/{name}/bundle
        if path.startswith("/tools/") and path.endswith("/bundle"):
            parts = path.split("/")
            if len(parts) == 4:
                tool_name = parts[2]
                # Find the bundle file (latest version).
                if not BUNDLES_DIR.exists():
                    self.send_json({"error": "No bundles directory"}, 404)
                    return
                bundles = sorted(BUNDLES_DIR.glob(f"{tool_name}*.bundle"), reverse=True)
                if not bundles:
                    self.send_json({"error": f"No bundle found for '{tool_name}'"}, 404)
                    return
                self.send_file(bundles[0])
                return

        self.send_json({"error": "Not found"}, 404)


def start_server(port: int, advertise: bool) -> None:
    """Start the catalog server, fork into background, and return."""
    FORGE_DIR.mkdir(parents=True, exist_ok=True)

    # Check if already running.
    if PID_FILE.exists():
        try:
            pid_data = json.loads(PID_FILE.read_text(encoding="utf-8"))
            old_pid = pid_data.get("pid", 0)
            if old_pid > 0:
                os.kill(old_pid, 0)  # Check if process exists.
                print(json.dumps({
                    "ok": False,
                    "error": f"Server already running (PID {old_pid}, port {pid_data.get('port', '?')}). Stop it first.",
                }))
                return
        except (ProcessLookupError, PermissionError, OSError, json.JSONDecodeError, ValueError):
            # Process not running, clean up stale PID file.
            PID_FILE.unlink(missing_ok=True)

    # Bind to get the actual port before forking.
    server = HTTPServer(("0.0.0.0", port), CatalogHandler)
    actual_port = server.server_address[1]

    # Fork into background.
    child_pid = os.fork()
    if child_pid > 0:
        # Parent: close our copy of the socket and report success.
        server.server_close()
        print(json.dumps({
            "ok": True,
            "port": actual_port,
            "pid": child_pid,
            "advertised": advertise,
            "name": get_instance_name(),
        }, indent=2))
        return

    # Child: become a daemon.
    os.setsid()

    # Write PID file.
    pid_info = {
        "pid": os.getpid(),
        "port": actual_port,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "advertise": advertise,
    }
    PID_FILE.write_text(json.dumps(pid_info, indent=2), encoding="utf-8")

    # Bonjour advertisement.
    zc = None
    svc_info = None
    if advertise:
        try:
            from zeroconf import ServiceInfo, Zeroconf
            import hashlib

            instance_name = get_instance_name()
            registry = load_registry()
            tool_count = len(registry.get("tools", {}))

            svc_info = ServiceInfo(
                SERVICE_TYPE,
                f"{instance_name}.{SERVICE_TYPE}",
                addresses=[socket.inet_aton(get_local_ip())],
                port=actual_port,
                properties={
                    "instance": instance_name,
                    "tools": str(tool_count),
                    "version": "1.0",
                },
            )
            zc = Zeroconf()
            zc.register_service(svc_info)
        except Exception:
            # Bonjour registration failed -- continue without it.
            zc = None
            svc_info = None

    # Graceful shutdown handler.
    def shutdown_handler(signum, frame):
        if zc is not None and svc_info is not None:
            try:
                zc.unregister_service(svc_info)
                zc.close()
            except Exception:
                pass
        server.shutdown()
        PID_FILE.unlink(missing_ok=True)
        os._exit(0)

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    # Redirect stdio to /dev/null for daemon.
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    os.close(devnull)

    # Serve forever.
    server.serve_forever()


def get_local_ip() -> str:
    """Get the machine's LAN IP address."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def stop_server() -> None:
    """Stop the running catalog server."""
    if not PID_FILE.exists():
        print(json.dumps({"ok": False, "error": "No server running (no PID file found)."}))
        return
    try:
        pid_data = json.loads(PID_FILE.read_text(encoding="utf-8"))
        pid = pid_data.get("pid", 0)
        if pid <= 0:
            PID_FILE.unlink(missing_ok=True)
            print(json.dumps({"ok": False, "error": "Invalid PID in PID file."}))
            return
        os.kill(pid, signal.SIGTERM)
        # Wait briefly for process to exit.
        for _ in range(10):
            try:
                os.kill(pid, 0)
                time.sleep(0.2)
            except ProcessLookupError:
                break
        PID_FILE.unlink(missing_ok=True)
        print(json.dumps({"ok": True, "stopped": True, "pid": pid}))
    except ProcessLookupError:
        PID_FILE.unlink(missing_ok=True)
        print(json.dumps({"ok": True, "stopped": True, "note": "Process was already gone."}))
    except (json.JSONDecodeError, OSError) as e:
        print(json.dumps({"ok": False, "error": str(e)}))


def server_status() -> None:
    """Check if the catalog server is running."""
    if not PID_FILE.exists():
        print(json.dumps({"ok": True, "running": False}))
        return
    try:
        pid_data = json.loads(PID_FILE.read_text(encoding="utf-8"))
        pid = pid_data.get("pid", 0)
        port = pid_data.get("port", 0)
        started_at = pid_data.get("started_at", "")
        advertise = pid_data.get("advertise", False)
        # Check if process is alive.
        os.kill(pid, 0)
        print(json.dumps({
            "ok": True,
            "running": True,
            "pid": pid,
            "port": port,
            "started_at": started_at,
            "advertise": advertise,
            "name": get_instance_name(),
        }, indent=2))
    except ProcessLookupError:
        PID_FILE.unlink(missing_ok=True)
        print(json.dumps({"ok": True, "running": False, "note": "Stale PID file cleaned up."}))
    except (json.JSONDecodeError, OSError) as e:
        print(json.dumps({"ok": False, "error": str(e)}))


def main() -> None:
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    action = params.get("action", "")

    if not action:
        print(json.dumps({"ok": False, "error": "Missing required parameter: action (start, stop, or status)."}))
        return

    try:
        if action == "start":
            port = int(params.get("port", 0))
            advertise = params.get("advertise", True)
            if isinstance(advertise, str):
                advertise = advertise.lower() in ("true", "1", "yes")
            start_server(port, advertise)
        elif action == "stop":
            stop_server()
        elif action == "status":
            server_status()
        else:
            print(json.dumps({"ok": False, "error": f"Unknown action: {action}. Use 'start', 'stop', or 'status'."}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
