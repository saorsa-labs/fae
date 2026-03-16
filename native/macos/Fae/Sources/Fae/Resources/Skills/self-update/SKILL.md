---
name: self-update
description: Check for and install Fae updates. Activate when the user asks you to update yourself or check for new versions.
metadata:
  author: fae
  version: "1.0"
---

# Self-Update

The user is asking you to check for updates or update yourself. Fae uses Sparkle for automatic updates from GitHub Releases.

## What You Can Do

You have a **`scheduler_trigger`** tool that can trigger the `check_fae_update` task, and you can read version info. But the actual update check and installation is handled natively by Sparkle — you just need to nudge the right mechanism.

## Flow

### 1. Report Current Version

Read the app version from the bundle:

```
I'm currently running Fae v{version}.
```

You can get the version from the `self_config` tool with `get_settings` — it includes the app version.

### 2. Trigger the Update Check

Use the `scheduler_trigger` tool to fire `check_fae_update`. This tells Sparkle to check the appcast feed for a newer version.

Then tell the user:

> "I've triggered an update check. If there's a newer version available, you'll see Sparkle's update dialog — it'll ask if you want to download and install it."

### 3. If They Ask About What's New

Use `web_search` to search for the latest Fae release:
- Search: `site:github.com saorsa-labs/fae releases`
- Or use `fetch_url` on `https://github.com/saorsa-labs/fae/releases/latest` to read the release notes.

Summarise the highlights conversationally — don't dump raw changelogs.

### 4. If They Ask to Update Now

Sparkle handles the download, verification, and installation. You cannot force-install an update programmatically. Tell them:

> "The update dialog should appear shortly. If it doesn't, try Fae > Check for Updates in the menu bar."

## Tone

- Straightforward and confident — this is a routine operation
- Don't over-explain Sparkle internals
- If the feed URL isn't configured (dev build), say: "Update checking isn't wired up in this build — it works in release builds."

## What NOT to Do

- Don't try to download DMGs or run install scripts via bash
- Don't modify Info.plist or any app bundle files
- Don't promise specific version numbers you haven't verified
- Don't restart the app — Sparkle handles relaunch after install
