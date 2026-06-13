---
name: calendar-caldav
description: List, create, update, and delete CalDAV events when the user asks for a portable calendar workflow.
tags: [calendar, caldav, productivity]
metadata:
  author: fae
  version: "1.0.0"
---

# Calendar CalDAV

Calendar CalDAV lets Fae work with cross-platform calendar servers, including iCloud and Google CalDAV, through a Python executable skill. It is additive to the privileged macOS EventKit path in `AppleTools.swift`.

## When to Use

- The user asks about calendars in a cross-platform or non-Apple context.
- The user wants to list upcoming events from iCloud/Google CalDAV using app-specific credentials.
- The user asks to create, update, or delete a simple event on a configured CalDAV calendar.
- Prefer the built-in `calendar` tool for macOS-local EventKit workflows unless portability is the point.

## Prerequisites

- Credentials must be stored in Keychain and injected with `run_skill.secret_bindings`; never store passwords in files or prompts.
- Required environment variables: `CALDAV_URL`, `CALDAV_USERNAME`, and `CALDAV_PASSWORD`.
- Optional environment variables: `CALDAV_CALENDAR` for the display name to prefer, `CALDAV_DEFAULT_TZ` for floating times.
- iCloud users need an app-specific password. Google users need the correct CalDAV URL and app/OAuth credential flow for their account.
- The script uses `uv run --script` with inline Python dependencies (`caldav`, `vobject`); Fae's Python runtime handles installation.

## How to Run

Use `run_skill` with skill `calendar-caldav` and script `calendar_caldav`.

```json
{
  "name":"calendar-caldav",
  "script":"calendar_caldav",
  "params":{"action":"list_events","days":7},
  "secret_bindings":{
    "CALDAV_URL":"productivity.calendar.url",
    "CALDAV_USERNAME":"productivity.calendar.username",
    "CALDAV_PASSWORD":"productivity.calendar.password"
  }
}
```

## Quick Reference

| Action | Required params | Purpose |
|---|---|---|
| `status` | none | Check environment readiness without revealing secrets |
| `list_calendars` | none | List visible calendars for the principal |
| `list_events` | optional `days`, `calendar`, `start`, `end` | List events in a date range |
| `create_event` | `summary`, `start`, `end` | Create a simple VEVENT |
| `update_event` | `uid` or `href`; plus changed fields | Update summary/start/end/description/location |
| `delete_event` | `uid` or `href` | Delete a matching event |

## Procedure

1. Run `status` if setup is uncertain. If anything is missing, ask only for the missing setup item.
2. For read-only questions, call `list_events` with the smallest range that answers the user.
3. Before creating/updating/deleting events, restate the exact calendar, date/time, title, and attendees/details if any; ask for confirmation.
4. Use ISO 8601 times. Include a timezone offset when possible.
5. After mutation, run `list_events` for the affected window or return the server `href`/`uid` as proof.

## Pitfalls

- CalDAV URLs differ by provider and account. Ask for the provider setup page or test credentials rather than guessing.
- Floating datetimes can land in the wrong timezone. Prefer offset timestamps such as `2026-06-13T09:30:00+01:00`.
- Recurring event edits are provider-sensitive. This v1 skill handles simple events; ask before touching recurrence.
- Do not reveal `CALDAV_PASSWORD` or raw Authorization headers in user-visible output.

## Verification

- `list_calendars` shows the expected iCloud or Google calendar.
- `list_events` over the next seven days returns real event titles and times.
- Create an event named `fae-skill-test`, then delete it by `uid` or `href`.
- AppleTools calendar tests still pass; this skill does not replace EventKit.
