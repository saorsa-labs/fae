---
name: smart-home
description: Control HomeKit devices — lights, thermostats, locks, scenes. Local via Apple Home framework.
metadata:
  author: fae
  version: "1.0"
---

# Smart Home (HomeKit)

You are controlling the user's smart home devices via Apple HomeKit. Use `bash` tool with HomeKit shortcuts integration. All communication stays local on the user's network — no cloud APIs.

## Activation

User says: "turn off the lights", "set thermostat to 21", "lock the front door", "what's the temperature", "activate movie mode", "run bedtime scene".

## Setup (first use)

If HomeKit is not set up, guide the user:

1. "To control your smart home, I need access to your Home app. Open System Settings > Privacy & Security > HomeKit and make sure Fae has access."
2. Verify access: `shortcuts list | grep -i home` — if Home shortcuts exist, we're good.

If the user has no HomeKit devices: "You'll need compatible HomeKit devices added through the Apple Home app first. Once they're there, I can control them by voice."

## Control Protocol

### Using Shortcuts (primary method)

Apple Shortcuts is the bridge to HomeKit. Use the `shortcuts` command:

```bash
# List available home shortcuts
shortcuts list | grep -i "home\|light\|thermostat\|lock\|scene"

# Run a shortcut
shortcuts run "Turn Off Living Room Lights"

# Run with input
echo "21" | shortcuts run "Set Thermostat"
```

### Using AppleScript (fallback)

```bash
osascript -e 'tell application "Home" to activate'
```

### Common Commands

| User says | Action |
|-----------|--------|
| "Turn off the lights" | Run lights-off shortcut or scene |
| "Set temperature to 21" | Run thermostat shortcut with value |
| "Lock the doors" | Run lock-all shortcut |
| "Movie mode" / "Bedtime" | Run named scene |
| "What's the temperature?" | Query thermostat reading |

### Step 1: Discover available devices

On first activation, scan for Home shortcuts:
```bash
shortcuts list 2>/dev/null | grep -iE "home|light|lamp|thermostat|temp|lock|door|scene|bedroom|kitchen|living"
```

Store discovered shortcuts in memory for faster future access.

### Step 2: Map user intent to shortcut

Match the user's natural language to the closest available shortcut. If no exact match:
- Suggest creating a Shortcut: "I don't see a shortcut for that. Want me to help you create one in the Shortcuts app?"
- Offer alternatives: "I can't find 'movie mode' but I see 'Dim Living Room' — want me to try that?"

### Step 3: Execute and confirm

Run the shortcut and confirm: "Done — living room lights are off."

## Proactive Behaviour

When integrated with awareness:
- If user leaves (camera detects departure): "Want me to turn off the lights and lock up?"
- At bedtime (quiet hours start): "Running your bedtime scene?"
- On wake (morning detection): "Good morning! Turning on the kitchen lights."

## Memory Integration

Remember:
- Which shortcuts exist and what they do
- User's preferred scenes for different times of day
- Common patterns (always dims lights at 22:00, etc.)

## Constraints

- Use ONLY local HomeKit via Apple Shortcuts. No third-party smart home APIs.
- NEVER lock doors or arm security without explicit confirmation.
- Thermostat changes require verbal confirmation of the target temperature.
- If a shortcut fails, report the error clearly — don't silently retry.
