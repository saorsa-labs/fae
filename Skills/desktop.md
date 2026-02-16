# Desktop Automation

Use the `desktop` tool to interact with the user's GUI when they ask you to:

- Take screenshots of the screen or specific applications
- Click on buttons, labels, or screen coordinates
- Type text into fields or applications
- Press keys or key combinations (hotkeys)
- Manage windows (list, focus, resize)
- Launch or list applications
- Automate multi-step GUI workflows

## Actions

| Action | Required args | Description |
|--------|---------------|-------------|
| `screenshot` | — | Capture full screen (add `app` to scope to one app) |
| `click` | `target` OR `coordinates` | Click a UI label or {x, y} position |
| `type` | `text` | Type text via keyboard |
| `press` | `key` | Press a single key (e.g. "return", "escape", "tab") |
| `hotkey` | `keys` | Press a combo (e.g. ["cmd", "shift", "s"]) |
| `scroll` | — | Scroll (optional `direction`, `amount`) |
| `list_windows` | — | List open windows |
| `focus_window` | `title` | Bring a window to front by title substring |
| `list_apps` | — | List running applications |
| `launch_app` | `name` | Launch an application by name |
| `raw` | `command` | Pass a raw command to the backend |

## Examples

```json
{"action": "screenshot"}
{"action": "screenshot", "app": "Safari"}
{"action": "click", "target": "Save"}
{"action": "click", "coordinates": {"x": 512, "y": 384}}
{"action": "type", "text": "Hello, world!"}
{"action": "press", "key": "return"}
{"action": "hotkey", "keys": ["cmd", "c"]}
{"action": "list_windows"}
{"action": "focus_window", "title": "Terminal"}
{"action": "launch_app", "name": "Calculator"}
```

## Safety rules

1. **Always describe what you are about to do** before executing a desktop action.
2. **Never automate credential entry** (passwords, tokens, keys) without explicit user permission.
3. **Prefer label-based clicks** over coordinates when possible — they are more robust.
4. **Take a screenshot first** when unsure of the screen state, so you can plan accurately.
5. Use the `raw` action sparingly — only for platform-specific features not covered by standard actions.

## Platform notes

### macOS (Peekaboo)

- Install: `brew install steipete/tap/peekaboo`
- Requires **Accessibility permission** in System Settings > Privacy & Security
- Peekaboo supports accessibility labels for precise element targeting
- Use `raw` for Peekaboo-specific features like `agent` mode

### Linux (xdotool)

- Install: `sudo apt install xdotool scrot`
- Requires an **X11 session** (Wayland support is experimental)
- Label-based clicking is limited — prefer coordinates on Linux
- Screenshots use `scrot`; install it alongside xdotool
