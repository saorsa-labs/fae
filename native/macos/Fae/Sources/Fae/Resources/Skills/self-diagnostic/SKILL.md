---
name: self-diagnostic
description: Run a comprehensive self-diagnostic check of system health, pipeline state, memory, tools, and speaker profiles. Activate when asked to diagnose, health check, or troubleshoot issues.
metadata:
  author: fae
  version: "1.0"
  tags:
    - system
    - diagnostics
---

# Self-Diagnostic

You are running a comprehensive self-diagnostic. Work through each section methodically and report findings in clear, spoken language. Skip sections gracefully if a tool is unavailable.

## 1. System Health

Use `bash` to check system resources:

```
bash "top -l 1 -n 0 | head -12"
```

Report: CPU usage, memory pressure, and swap usage. Flag if memory pressure is "critical" or swap exceeds 4 GB.

```
bash "df -h / | tail -1"
```

Report: Available disk space. Flag if below 10 GB free.

```
bash "pmset -g batt 2>/dev/null || echo 'No battery (desktop)'"
```

Report: Battery level and charging state. Flag if below 20% and not charging.

```
bash "uptime"
```

Report: System uptime. Note if uptime exceeds 14 days (suggest restart for performance).

## 2. Pipeline State

Check what I know about my own state:
- Am I in degraded mode? (STT/LLM/TTS missing or failed to load)
- What model am I currently using?
- Is the voice pipeline active and processing?

Report any degraded components. If everything is loaded, confirm "All pipeline components are healthy."

## 3. Recent Security Events

```
bash "tail -20 ~/Library/Application\\ Support/fae/security-events.jsonl 2>/dev/null || echo 'No security log found'"
```

Summarize: Count of events by level (info/warning/error) in the last 20 entries. Flag any "error" or "critical" level events with a brief description.

## 4. Tool Health

```
scheduler_list
```

Review the scheduler task list:
- Are all expected tasks present and enabled?
- Have any tasks not run recently (stale)?
- Are there any tasks in an error state?

Report: "All scheduled tasks are healthy" or list specific issues.

## 5. Memory Health

Use what you know from memory context:
- Approximate record count (from recall context)
- Last digest time
- Any memory errors in recent security log

Report: Memory system status. Flag if no recent digests or if record count seems unusually low.

## 6. Speaker Profile Status

Use `voice_identity check_status` to review:
- Is a primary user enrolled?
- How many speaker profiles exist?
- Any profiles with very low sample counts (< 3)?

Report: Voice identity status. Flag if no owner is enrolled or if profiles seem degraded.

## 7. Summary

Provide a spoken summary:
- "Everything looks good" if no issues found
- Or list the issues found, ordered by severity (critical first)
- Suggest remediation for each issue (restart, free disk space, re-enroll voice, etc.)

Keep the summary conversational and reassuring. End with "Let me know if you want me to look into anything specific."
