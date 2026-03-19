---
name: system-health
description: Monitor Mac health — CPU, memory, disk, battery, thermal state, and running processes.
metadata:
  author: fae
  version: "1.0"
---

# System Health Monitor

You are checking the health of the user's Mac. Use `bash` tool for all system queries. Everything is local — no telemetry.

## Activation

User says: "how's my Mac doing", "check system health", "is my Mac running hot", "what's eating my battery", "disk space check".

## Health Check Protocol

### Quick Check (default)

Run these in sequence:

```bash
# CPU + Memory
top -l 1 -n 5 -stats pid,command,cpu,mem | head -15

# Disk
df -h / | tail -1

# Battery
pmset -g batt 2>/dev/null | head -3

# Thermal
pmset -g therm 2>/dev/null

# Load average
sysctl -n vm.loadavg
```

Present as a spoken summary:
"Your Mac is healthy. CPU is at 23%, you have 8GB of 16GB RAM free, 45GB disk space remaining. Battery is at 78% and not charging. No thermal throttling."

### Deep Check (on request)

```bash
# Top CPU consumers
ps aux --sort=-%cpu | head -8

# Top memory consumers
ps aux --sort=-%mem | head -8

# Disk usage by folder
du -sh ~/Desktop ~/Downloads ~/Documents ~/Library/Caches 2>/dev/null

# Uptime
uptime

# macOS version
sw_vers

# Network
networksetup -getairportnetwork en0 2>/dev/null || echo "No WiFi info"
```

### Battery Deep Dive

```bash
# Battery health
system_profiler SPPowerDataType 2>/dev/null | grep -E "Cycle Count|Condition|Maximum Capacity|Charging"

# Power consumers
pmset -g assertions 2>/dev/null | head -20
```

## Proactive Alerts

When activated by scheduler or awareness checks, flag:
- Disk < 10GB free: "Your disk is getting full. Want me to find large files to clean up?"
- Battery < 15% and not charging: "Battery is low. Plug in soon."
- CPU consistently > 80%: "Something is using a lot of CPU. Want me to check what?"
- Thermal throttling active: "Your Mac is running hot. Close resource-heavy apps?"

## Memory Integration

Track trends: "Your disk was 45GB free last week, now it's 30GB. Downloads folder grew significantly."

## Constraints

- Use ONLY local system commands. No external monitoring services.
- NEVER kill processes without explicit user approval.
- For `sudo` commands, inform the user it needs their password and ask first.
- Present technical data in plain English, not raw terminal output.
