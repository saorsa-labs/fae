#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["caldav>=1.4.0", "vobject>=0.9.8"]
# ///
"""Fae executable skill for CalDAV calendar operations."""

from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import UTC, date, datetime, time, timedelta
from typing import Any

import caldav
import vobject


REQUIRED_ENV = ["CALDAV_URL", "CALDAV_USERNAME", "CALDAV_PASSWORD"]


def emit(result: dict[str, Any], status: int = 0) -> int:
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), default=str))
    return status


def read_request() -> dict[str, Any]:
    payload = sys.stdin.read().strip()
    if not payload:
        raise ValueError("empty request")
    request = json.loads(payload)
    params = request.get("params") or {}
    if not isinstance(params, dict):
        raise ValueError("params must be an object")
    return params


def env_status() -> dict[str, bool]:
    return {name: bool(os.environ.get(name)) for name in REQUIRED_ENV}


def missing_env() -> list[str]:
    return [name for name in REQUIRED_ENV if not os.environ.get(name)]


def status() -> dict[str, Any]:
    missing = missing_env()
    return {
        "ok": True,
        "ready": not missing,
        "state": "ready" if not missing else "missing_env",
        "required_env_present": env_status(),
        "missing_env": missing,
        "optional_env_present": {
            "CALDAV_CALENDAR": bool(os.environ.get("CALDAV_CALENDAR")),
            "CALDAV_DEFAULT_TZ": bool(os.environ.get("CALDAV_DEFAULT_TZ")),
        },
    }


def require_env() -> tuple[str, str, str]:
    missing = missing_env()
    if missing:
        raise ValueError("missing required environment variables: " + ", ".join(missing))
    return (
        os.environ["CALDAV_URL"],
        os.environ["CALDAV_USERNAME"],
        os.environ["CALDAV_PASSWORD"],
    )


def client() -> caldav.DAVClient:
    url, username, password = require_env()
    return caldav.DAVClient(url=url, username=username, password=password)


def principal() -> Any:
    return client().principal()


def calendar_name(calendar: Any) -> str:
    for attr in ("name", "id"):
        try:
            value = getattr(calendar, attr)
            if callable(value):
                value = value()
            if value:
                return str(value)
        except Exception:  # noqa: BLE001 - provider metadata can be quirky.
            continue
    return str(getattr(calendar, "url", "calendar"))


def calendars() -> list[Any]:
    found = principal().calendars()
    if not isinstance(found, list):
        return list(found)
    return found


def select_calendar(params: dict[str, Any]) -> Any:
    wanted = str(params.get("calendar") or os.environ.get("CALDAV_CALENDAR") or "").strip().lower()
    found = calendars()
    if not found:
        raise ValueError("no CalDAV calendars found")
    if not wanted:
        return found[0]
    for calendar in found:
        name = calendar_name(calendar).lower()
        url = str(getattr(calendar, "url", "")).lower()
        if wanted == name or wanted in name or wanted in url:
            return calendar
    names = [calendar_name(calendar) for calendar in found]
    raise ValueError(f"calendar not found: {wanted}; available: {names}")


def list_calendars(_: dict[str, Any]) -> dict[str, Any]:
    items = []
    for calendar in calendars():
        items.append({"name": calendar_name(calendar), "url": str(getattr(calendar, "url", ""))})
    return {"ok": True, "calendars": items}


def parse_datetime(value: Any, *, default: datetime | None = None) -> datetime:
    if value is None or str(value).strip() == "":
        if default is None:
            raise ValueError("datetime value is required")
        return default
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    return parsed


def range_from_params(params: dict[str, Any]) -> tuple[datetime, datetime]:
    now = datetime.now(UTC)
    days_value = params.get("days", 7)
    try:
        days = int(days_value)
    except (TypeError, ValueError):
        days = 7
    days = max(1, min(366, days))
    start = parse_datetime(params.get("start"), default=now)
    end = parse_datetime(params.get("end"), default=start + timedelta(days=days))
    return start, end


def iso_value(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, date):
        return value.isoformat()
    return str(value)


def parse_event(event: Any) -> dict[str, Any]:
    data = getattr(event, "data", None)
    if not data and hasattr(event, "load"):
        event.load()
        data = getattr(event, "data", None)
    if not data:
        return {"href": str(getattr(event, "url", "")), "summary": "(no data)"}

    component = vobject.readOne(data)
    vevent = component.vevent
    summary = getattr(getattr(vevent, "summary", None), "value", "")
    uid = getattr(getattr(vevent, "uid", None), "value", "")
    location = getattr(getattr(vevent, "location", None), "value", None)
    description = getattr(getattr(vevent, "description", None), "value", None)
    dtstart = getattr(getattr(vevent, "dtstart", None), "value", None)
    dtend = getattr(getattr(vevent, "dtend", None), "value", None)
    return {
        "uid": str(uid),
        "summary": str(summary),
        "start": iso_value(dtstart),
        "end": iso_value(dtend),
        "location": str(location) if location else None,
        "description": str(description) if description else None,
        "href": str(getattr(event, "url", "")),
    }


def list_events(params: dict[str, Any]) -> dict[str, Any]:
    calendar = select_calendar(params)
    start, end = range_from_params(params)
    events = calendar.events(start=start, end=end)
    parsed = [parse_event(event) for event in events]
    parsed.sort(key=lambda item: item.get("start") or "")
    limit = int(params.get("limit") or 50)
    return {
        "ok": True,
        "calendar": calendar_name(calendar),
        "start": start.isoformat(),
        "end": end.isoformat(),
        "events": parsed[: max(1, min(200, limit))],
    }


def escape_ical_text(value: Any) -> str:
    text = str(value or "")
    return (
        text.replace("\\", "\\\\")
        .replace(";", "\\;")
        .replace(",", "\\,")
        .replace("\r\n", "\\n")
        .replace("\n", "\\n")
    )


def ical_datetime(value: datetime) -> str:
    if value.tzinfo is not None:
        return value.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")
    return value.strftime("%Y%m%dT%H%M%S")


def build_ical(params: dict[str, Any], *, uid: str | None = None) -> tuple[str, str]:
    summary = str(params.get("summary") or "").strip()
    if not summary:
        raise ValueError("summary is required")
    start = parse_datetime(params.get("start"))
    end = parse_datetime(params.get("end"))
    if end <= start:
        raise ValueError("end must be after start")
    event_uid = uid or str(params.get("uid") or uuid.uuid4())
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Fae//calendar-caldav//EN",
        "BEGIN:VEVENT",
        f"UID:{event_uid}",
        f"DTSTAMP:{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}",
        f"DTSTART:{ical_datetime(start)}",
        f"DTEND:{ical_datetime(end)}",
        f"SUMMARY:{escape_ical_text(summary)}",
    ]
    if params.get("description"):
        lines.append(f"DESCRIPTION:{escape_ical_text(params.get('description'))}")
    if params.get("location"):
        lines.append(f"LOCATION:{escape_ical_text(params.get('location'))}")
    lines.extend(["END:VEVENT", "END:VCALENDAR", ""])
    return "\r\n".join(lines), event_uid


def create_event(params: dict[str, Any]) -> dict[str, Any]:
    calendar = select_calendar(params)
    data, uid = build_ical(params)
    event = calendar.add_event(data)
    return {
        "ok": True,
        "action": "create_event",
        "calendar": calendar_name(calendar),
        "uid": uid,
        "href": str(getattr(event, "url", "")),
    }


def find_event(params: dict[str, Any]) -> Any:
    href = str(params.get("href") or "").strip()
    uid = str(params.get("uid") or "").strip()
    if not href and not uid:
        raise ValueError("uid or href is required")
    calendar = select_calendar(params)
    start = datetime.now(UTC) - timedelta(days=366)
    end = datetime.now(UTC) + timedelta(days=366 * 2)
    for event in calendar.events(start=start, end=end):
        if href and str(getattr(event, "url", "")) == href:
            return event
        parsed = parse_event(event)
        if uid and parsed.get("uid") == uid:
            return event
    raise ValueError("matching event not found")


def delete_event(params: dict[str, Any]) -> dict[str, Any]:
    event = find_event(params)
    parsed = parse_event(event)
    event.delete()
    return {"ok": True, "action": "delete_event", "deleted": parsed}


def ensure_child(component: Any, name: str, value: Any) -> None:
    if hasattr(component, name):
        getattr(component, name).value = value
    else:
        component.add(name).value = value


def update_event(params: dict[str, Any]) -> dict[str, Any]:
    event = find_event(params)
    parsed_before = parse_event(event)
    data = getattr(event, "data", None)
    if not data and hasattr(event, "load"):
        event.load()
        data = getattr(event, "data", None)
    component = vobject.readOne(data)
    vevent = component.vevent
    if params.get("summary") is not None:
        ensure_child(vevent, "summary", str(params.get("summary")))
    if params.get("description") is not None:
        ensure_child(vevent, "description", str(params.get("description")))
    if params.get("location") is not None:
        ensure_child(vevent, "location", str(params.get("location")))
    if params.get("start") is not None:
        ensure_child(vevent, "dtstart", parse_datetime(params.get("start")))
    if params.get("end") is not None:
        ensure_child(vevent, "dtend", parse_datetime(params.get("end")))
    event.data = component.serialize()
    event.save()
    return {"ok": True, "action": "update_event", "before": parsed_before, "after": parse_event(event)}


def dispatch(params: dict[str, Any]) -> dict[str, Any]:
    action = str(params.get("action") or "status").strip()
    if action == "status":
        return status()
    if action == "list_calendars":
        return list_calendars(params)
    if action == "list_events":
        return list_events(params)
    if action == "create_event":
        return create_event(params)
    if action == "update_event":
        return update_event(params)
    if action == "delete_event":
        return delete_event(params)
    return {"ok": False, "error": f"unsupported action: {action}"}


def main() -> int:
    try:
        result = dispatch(read_request())
        return emit(result, status=0 if result.get("ok") else 1)
    except Exception as exc:  # noqa: BLE001 - skill boundary returns structured JSON.
        return emit({"ok": False, "error": str(exc), "required_env_present": env_status()}, status=1)


if __name__ == "__main__":
    raise SystemExit(main())
