---
name: desktop
description: Interact with the user's desktop — screenshots, GUI automation, window management, and app launching via computer use tools.
metadata:
  author: fae
  version: "1.0"
---

Use Fae's built-in computer use tools to interact with the user's GUI when they ask you to automate desktop tasks.

## Available Tools

Fae has these native tools for desktop interaction:

| Tool | What it does |
|------|--------------|
| `screenshot` | Capture full screen or a specific app window |
| `camera` | Take a photo using the webcam |
| `read_screen` | Read visible UI elements and their accessibility labels |
| `click` | Click a UI element by label or screen coordinates |
| `type_text` | Type text into the focused field or application |
| `scroll` | Scroll up, down, left, or right |
| `find_element` | Find a UI element by label, role, or coordinates |

## When to Use

- User asks to take a screenshot
- User wants to click a button or UI element
- User wants to automate a GUI workflow (e.g. "click the Save button")
- User asks to read what's on screen
- User wants to type text into an application
- User asks to manage windows (list, focus, launch apps)

## Safety Rules

1. **Always describe what you are about to do** before executing a desktop action.
2. **Never automate credential entry** (passwords, tokens, keys) without explicit user permission.
3. **Prefer label-based actions** over coordinates when possible — they are more robust.
4. **Take a screenshot or read the screen first** when unsure of the current UI state, so you can plan accurately.
5. Maximum 10 action steps per turn. If a task requires more, complete what you can and summarise what remains.
6. **macOS permissions**: Screen Recording and Accessibility permissions are required. If not yet granted, Fae will request them via JIT permission flow.

## Platform Notes (macOS)

- Computer use requires **Screen Recording** permission (for screenshot/read_screen) and **Accessibility** permission (for click/type_text/scroll) in System Settings > Privacy & Security.
- Fae uses native macOS APIs (Accessibility Inspector) for element targeting — no third-party automation tools needed.
- Do not mention Peekaboo or xdotool to users — the native tools are sufficient.

## Do Not Use For

- System-level automation that requires Admin privileges (use `bash` for that)
- Multi-step workflows that exceed 10 steps (break into smaller requests)
- Automation of protected system surfaces (System Preferences, login items, etc.)
