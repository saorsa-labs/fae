//! AppleScript-based implementations of Apple ecosystem store traits.
//!
//! Each store uses `osascript` (JXA / JavaScript for Automation) to interact
//! with the corresponding macOS application: Contacts, Calendar, Reminders,
//! Notes, and Mail.
//!
//! This approach requires no Objective-C bindings or Swift bridge changes —
//! `osascript` is available on all macOS systems and works under App Sandbox
//! when the appropriate entitlements are granted.
//!
//! Latency is 100-500ms per call, acceptable for voice interactions where Fae
//! speaks an acknowledgment while the background agent executes.

use std::io::Read;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use super::calendar::{
    CalendarEvent, CalendarInfo, CalendarStore, CalendarStoreError, EventPatch, EventQuery,
    NewCalendarEvent,
};
use super::contacts::{Contact, ContactQuery, ContactStore, ContactStoreError, NewContact};
use super::mail::{Mail, MailQuery, MailStore, MailStoreError, NewMail};
use super::notes::{NewNote, Note, NoteQuery, NoteStore, NoteStoreError};
use super::reminders::{
    NewReminder, Reminder, ReminderList, ReminderQuery, ReminderStore, ReminderStoreError,
};

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Run a JXA (JavaScript for Automation) script and parse the JSON output.
const OSASCRIPT_TIMEOUT: Duration = Duration::from_secs(15);
const OSASCRIPT_POLL_INTERVAL: Duration = Duration::from_millis(25);

fn run_jxa(script: &str) -> Result<serde_json::Value, String> {
    let mut child = Command::new("osascript")
        .arg("-l")
        .arg("JavaScript")
        .arg("-e")
        .arg(script)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("failed to execute osascript: {e}"))?;

    let started = Instant::now();
    loop {
        if let Some(_status) = child
            .try_wait()
            .map_err(|e| format!("failed waiting for osascript: {e}"))?
        {
            break;
        }

        if started.elapsed() >= OSASCRIPT_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!(
                "timeout|op=apple.applescript.execute timeout_ms={}",
                OSASCRIPT_TIMEOUT.as_millis()
            ));
        }

        thread::sleep(OSASCRIPT_POLL_INTERVAL);
    }

    let mut stdout_bytes = Vec::new();
    if let Some(mut stdout) = child.stdout.take() {
        stdout
            .read_to_end(&mut stdout_bytes)
            .map_err(|e| format!("failed to collect osascript output: {e}"))?;
    }

    let mut stderr_bytes = Vec::new();
    if let Some(mut stderr) = child.stderr.take() {
        stderr
            .read_to_end(&mut stderr_bytes)
            .map_err(|e| format!("failed to collect osascript output: {e}"))?;
    }

    let status = child
        .wait()
        .map_err(|e| format!("failed waiting for osascript: {e}"))?;

    if !status.success() {
        let stderr = String::from_utf8_lossy(&stderr_bytes);
        return Err(format!("osascript error: {stderr}"));
    }

    let stdout = String::from_utf8_lossy(&stdout_bytes);
    let trimmed = stdout.trim();
    if trimmed.is_empty() {
        return Ok(serde_json::Value::Null);
    }

    serde_json::from_str(trimmed).map_err(|e| format!("failed to parse osascript JSON output: {e}"))
}

/// Escape a string for safe embedding in JXA scripts.
fn jxa_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
}

// ─── ContactStore ────────────────────────────────────────────────────────────

/// AppleScript-backed contact store using JXA to bridge to Contacts.app.
pub struct ApplescriptContactStore;

impl ContactStore for ApplescriptContactStore {
    fn search(&self, query: &ContactQuery) -> Result<Vec<Contact>, ContactStoreError> {
        let search_clause = if let Some(ref q) = query.query {
            let escaped = jxa_escape(q);
            format!(
                r#"
                var lower = "{escaped}".toLowerCase();
                people = people.filter(function(p) {{
                    var name = ((p.firstName() || "") + " " + (p.lastName() || "")).toLowerCase();
                    var emails = (p.emails() || []).map(function(e) {{ return e.value().toLowerCase(); }});
                    var phones = (p.phones() || []).map(function(ph) {{ return ph.value(); }});
                    return name.indexOf(lower) !== -1
                        || emails.some(function(e) {{ return e.indexOf(lower) !== -1; }})
                        || phones.some(function(ph) {{ return ph.indexOf(lower) !== -1; }});
                }});
                "#
            )
        } else {
            String::new()
        };

        let script = format!(
            r#"
            var app = Application("Contacts");
            var people = app.people();
            {search_clause}
            people = people.slice(0, {limit});
            JSON.stringify(people.map(function(p) {{
                return {{
                    identifier: p.id(),
                    given_name: p.firstName() || "",
                    family_name: p.lastName() || "",
                    emails: (p.emails() || []).map(function(e) {{ return e.value(); }}),
                    phones: (p.phones() || []).map(function(ph) {{ return ph.value(); }}),
                    addresses: [],
                    birthday: null,
                    organization: p.organization() || null,
                    note: p.note() || null
                }};
            }}));
            "#,
            limit = query.limit,
        );

        let value = run_jxa(&script).map_err(ContactStoreError::Backend)?;
        parse_contacts_json(&value)
    }

    fn get(&self, identifier: &str) -> Result<Option<Contact>, ContactStoreError> {
        let escaped_id = jxa_escape(identifier);
        let script = format!(
            r#"
            var app = Application("Contacts");
            var matches = app.people.whose({{id: "{escaped_id}"}})();
            if (matches.length === 0) {{ JSON.stringify(null); }}
            else {{
                var p = matches[0];
                JSON.stringify({{
                    identifier: p.id(),
                    given_name: p.firstName() || "",
                    family_name: p.lastName() || "",
                    emails: (p.emails() || []).map(function(e) {{ return e.value(); }}),
                    phones: (p.phones() || []).map(function(ph) {{ return ph.value(); }}),
                    addresses: [],
                    birthday: null,
                    organization: p.organization() || null,
                    note: p.note() || null
                }});
            }}
            "#,
        );

        let value = run_jxa(&script).map_err(ContactStoreError::Backend)?;
        if value.is_null() {
            return Ok(None);
        }
        let contact = parse_single_contact(&value)
            .map_err(|e| ContactStoreError::Backend(format!("parse error: {e}")))?;
        Ok(Some(contact))
    }

    fn create(&self, contact: &NewContact) -> Result<Contact, ContactStoreError> {
        let given = jxa_escape(&contact.given_name);
        let family = contact
            .family_name
            .as_deref()
            .map(jxa_escape)
            .unwrap_or_default();
        let email_line = contact
            .email
            .as_deref()
            .map(|e| {
                let escaped = jxa_escape(e);
                format!(r#"p.emails.push(app.Email({{value: "{escaped}"}}));"#)
            })
            .unwrap_or_default();
        let phone_line = contact
            .phone
            .as_deref()
            .map(|ph| {
                let escaped = jxa_escape(ph);
                format!(r#"p.phones.push(app.Phone({{value: "{escaped}"}}));"#)
            })
            .unwrap_or_default();
        let org_line = contact
            .organization
            .as_deref()
            .map(|o| {
                let escaped = jxa_escape(o);
                format!(r#"p.organization = "{escaped}";"#)
            })
            .unwrap_or_default();
        let note_line = contact
            .note
            .as_deref()
            .map(|n| {
                let escaped = jxa_escape(n);
                format!(r#"p.note = "{escaped}";"#)
            })
            .unwrap_or_default();

        let script = format!(
            r#"
            var app = Application("Contacts");
            var p = app.Person({{firstName: "{given}", lastName: "{family}"}});
            app.people.push(p);
            {email_line}
            {phone_line}
            {org_line}
            {note_line}
            app.save();
            JSON.stringify({{
                identifier: p.id(),
                given_name: p.firstName() || "",
                family_name: p.lastName() || "",
                emails: (p.emails() || []).map(function(e) {{ return e.value(); }}),
                phones: (p.phones() || []).map(function(ph) {{ return ph.value(); }}),
                addresses: [],
                birthday: null,
                organization: p.organization() || null,
                note: p.note() || null
            }});
            "#,
        );

        let value = run_jxa(&script).map_err(ContactStoreError::Backend)?;
        parse_single_contact(&value)
            .map_err(|e| ContactStoreError::Backend(format!("parse error: {e}")))
    }
}

fn parse_contacts_json(value: &serde_json::Value) -> Result<Vec<Contact>, ContactStoreError> {
    let arr = value
        .as_array()
        .ok_or_else(|| ContactStoreError::Backend("expected JSON array".to_owned()))?;
    let mut contacts = Vec::with_capacity(arr.len());
    for item in arr {
        contacts.push(
            parse_single_contact(item)
                .map_err(|e| ContactStoreError::Backend(format!("parse error: {e}")))?,
        );
    }
    Ok(contacts)
}

fn parse_single_contact(v: &serde_json::Value) -> Result<Contact, String> {
    Ok(Contact {
        identifier: v["identifier"].as_str().unwrap_or_default().to_owned(),
        given_name: v["given_name"].as_str().unwrap_or_default().to_owned(),
        family_name: v["family_name"].as_str().unwrap_or_default().to_owned(),
        emails: v["emails"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|e| e.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default(),
        phones: v["phones"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|e| e.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default(),
        addresses: v["addresses"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|e| e.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default(),
        birthday: v["birthday"].as_str().map(str::to_owned),
        organization: v["organization"].as_str().map(str::to_owned),
        note: v["note"].as_str().map(str::to_owned),
    })
}

// ─── CalendarStore ───────────────────────────────────────────────────────────

/// AppleScript-backed calendar store using JXA to bridge to Calendar.app.
pub struct ApplescriptCalendarStore;

impl CalendarStore for ApplescriptCalendarStore {
    fn list_calendars(&self) -> Result<Vec<CalendarInfo>, CalendarStoreError> {
        let script = r#"
            var app = Application("Calendar");
            var cals = app.calendars();
            JSON.stringify(cals.map(function(c) {
                return {
                    identifier: c.id(),
                    title: c.name(),
                    color: c.color() || null,
                    is_writable: c.writable()
                };
            }));
        "#;

        let value = run_jxa(script).map_err(CalendarStoreError::Backend)?;
        let arr = value
            .as_array()
            .ok_or_else(|| CalendarStoreError::Backend("expected JSON array".to_owned()))?;

        let mut calendars = Vec::with_capacity(arr.len());
        for item in arr {
            calendars.push(CalendarInfo {
                identifier: item["identifier"].as_str().unwrap_or_default().to_owned(),
                title: item["title"].as_str().unwrap_or_default().to_owned(),
                color: item["color"].as_str().map(str::to_owned),
                is_writable: item["is_writable"].as_bool().unwrap_or(false),
            });
        }
        Ok(calendars)
    }

    fn list_events(&self, query: &EventQuery) -> Result<Vec<CalendarEvent>, CalendarStoreError> {
        // Build date range filter for JXA.
        let start_filter = query
            .start_after
            .as_deref()
            .map(|s| {
                let escaped = jxa_escape(s);
                format!(r#"var startDate = new Date("{escaped}");"#)
            })
            .unwrap_or_else(|| {
                "var startDate = new Date(); startDate.setDate(startDate.getDate());".to_owned()
            });

        let end_filter = query
            .end_before
            .as_deref()
            .map(|e| {
                let escaped = jxa_escape(e);
                format!(r#"var endDate = new Date("{escaped}");"#)
            })
            .unwrap_or_else(|| {
                "var endDate = new Date(); endDate.setDate(endDate.getDate() + 30);".to_owned()
            });

        let cal_filter = if !query.calendar_ids.is_empty() {
            let ids: Vec<String> = query
                .calendar_ids
                .iter()
                .map(|id| format!(r#""{}""#, jxa_escape(id)))
                .collect();
            format!(
                r#"
                var calIds = [{}];
                cals = cals.filter(function(c) {{ return calIds.indexOf(c.id()) !== -1; }});
                "#,
                ids.join(", ")
            )
        } else {
            String::new()
        };

        let script = format!(
            r#"
            var app = Application("Calendar");
            {start_filter}
            {end_filter}
            var cals = app.calendars();
            {cal_filter}
            var events = [];
            cals.forEach(function(cal) {{
                var calEvents = cal.events.whose({{
                    _and: [
                        {{startDate: {{_greaterThan: startDate}}}},
                        {{startDate: {{_lessThan: endDate}}}}
                    ]
                }})();
                calEvents.forEach(function(ev) {{
                    events.push({{
                        identifier: ev.id(),
                        calendar_id: cal.id(),
                        title: ev.summary() || "",
                        start: ev.startDate().toISOString(),
                        end: ev.endDate().toISOString(),
                        location: ev.location() || null,
                        notes: ev.description() || null,
                        is_all_day: ev.alldayEvent(),
                        alarms: []
                    }});
                }});
            }});
            events = events.slice(0, {limit});
            JSON.stringify(events);
            "#,
            limit = query.limit,
        );

        let value = run_jxa(&script).map_err(CalendarStoreError::Backend)?;
        parse_events_json(&value)
    }

    fn create_event(&self, event: &NewCalendarEvent) -> Result<CalendarEvent, CalendarStoreError> {
        let title = jxa_escape(&event.title);
        let start = jxa_escape(&event.start);
        let end_str = event.end.as_deref().map(jxa_escape).unwrap_or_else(|| {
            // Default to start + 1 hour (handled in JXA).
            String::new()
        });

        let end_line = if end_str.is_empty() {
            r#"var endD = new Date(startD.getTime() + 3600000);"#.to_owned()
        } else {
            format!(r#"var endD = new Date("{end_str}");"#)
        };

        let cal_line = if let Some(ref cal_id) = event.calendar_id {
            let escaped = jxa_escape(cal_id);
            format!(
                r#"var cal = app.calendars.whose({{id: "{escaped}"}})()[0];
                if (!cal) {{ throw new Error("Calendar not found: {escaped}"); }}"#
            )
        } else {
            "var cal = app.defaultCalendar();".to_owned()
        };

        let location_line = event
            .location
            .as_deref()
            .map(|l| format!(r#", location: "{}""#, jxa_escape(l)))
            .unwrap_or_default();

        let notes_line = event
            .notes
            .as_deref()
            .map(|n| format!(r#", description: "{}""#, jxa_escape(n)))
            .unwrap_or_default();

        let allday = if event.is_all_day { "true" } else { "false" };

        let script = format!(
            r#"
            var app = Application("Calendar");
            {cal_line}
            var startD = new Date("{start}");
            {end_line}
            var ev = app.Event({{
                summary: "{title}",
                startDate: startD,
                endDate: endD,
                alldayEvent: {allday}
                {location_line}
                {notes_line}
            }});
            cal.events.push(ev);
            JSON.stringify({{
                identifier: ev.id(),
                calendar_id: cal.id(),
                title: ev.summary(),
                start: ev.startDate().toISOString(),
                end: ev.endDate().toISOString(),
                location: ev.location() || null,
                notes: ev.description() || null,
                is_all_day: ev.alldayEvent(),
                alarms: []
            }});
            "#,
        );

        let value = run_jxa(&script).map_err(CalendarStoreError::Backend)?;
        parse_single_event(&value)
            .map_err(|e| CalendarStoreError::Backend(format!("parse error: {e}")))
    }

    fn update_event(
        &self,
        id: &str,
        patch: &EventPatch,
    ) -> Result<CalendarEvent, CalendarStoreError> {
        let escaped_id = jxa_escape(id);
        let mut update_lines = Vec::new();

        if let Some(ref title) = patch.title {
            update_lines.push(format!(r#"ev.summary = "{}";"#, jxa_escape(title)));
        }
        if let Some(ref start) = patch.start {
            update_lines.push(format!(
                r#"ev.startDate = new Date("{}");"#,
                jxa_escape(start)
            ));
        }
        if let Some(ref end) = patch.end {
            update_lines.push(format!(r#"ev.endDate = new Date("{}");"#, jxa_escape(end)));
        }
        if let Some(ref loc_opt) = patch.location {
            match loc_opt {
                Some(loc) => {
                    update_lines.push(format!(r#"ev.location = "{}";"#, jxa_escape(loc)));
                }
                None => {
                    update_lines.push(r#"ev.location = "";"#.to_owned());
                }
            }
        }
        if let Some(ref notes_opt) = patch.notes {
            match notes_opt {
                Some(notes) => {
                    update_lines.push(format!(r#"ev.description = "{}";"#, jxa_escape(notes)));
                }
                None => {
                    update_lines.push(r#"ev.description = "";"#.to_owned());
                }
            }
        }

        let updates = update_lines.join("\n");

        let script = format!(
            r#"
            var app = Application("Calendar");
            var ev = null;
            var cals = app.calendars();
            for (var i = 0; i < cals.length; i++) {{
                var matches = cals[i].events.whose({{id: "{escaped_id}"}})();
                if (matches.length > 0) {{ ev = matches[0]; break; }}
            }}
            if (!ev) {{ throw new Error("Event not found: {escaped_id}"); }}
            {updates}
            JSON.stringify({{
                identifier: ev.id(),
                calendar_id: ev.calendar.id ? ev.calendar.id() : "",
                title: ev.summary() || "",
                start: ev.startDate().toISOString(),
                end: ev.endDate().toISOString(),
                location: ev.location() || null,
                notes: ev.description() || null,
                is_all_day: ev.alldayEvent(),
                alarms: []
            }});
            "#,
        );

        let value = run_jxa(&script).map_err(|e| {
            if e.contains("not found") {
                CalendarStoreError::NotFound
            } else {
                CalendarStoreError::Backend(e)
            }
        })?;
        parse_single_event(&value)
            .map_err(|e| CalendarStoreError::Backend(format!("parse error: {e}")))
    }

    fn delete_event(&self, id: &str) -> Result<(), CalendarStoreError> {
        let escaped_id = jxa_escape(id);
        let script = format!(
            r#"
            var app = Application("Calendar");
            var cals = app.calendars();
            var found = false;
            for (var i = 0; i < cals.length; i++) {{
                var matches = cals[i].events.whose({{id: "{escaped_id}"}})();
                if (matches.length > 0) {{
                    matches[0].delete();
                    found = true;
                    break;
                }}
            }}
            if (!found) {{ throw new Error("Event not found: {escaped_id}"); }}
            JSON.stringify({{ deleted: true }});
            "#,
        );

        run_jxa(&script).map_err(|e| {
            if e.contains("not found") {
                CalendarStoreError::NotFound
            } else {
                CalendarStoreError::Backend(e)
            }
        })?;
        Ok(())
    }
}

fn parse_events_json(value: &serde_json::Value) -> Result<Vec<CalendarEvent>, CalendarStoreError> {
    let arr = value
        .as_array()
        .ok_or_else(|| CalendarStoreError::Backend("expected JSON array".to_owned()))?;
    let mut events = Vec::with_capacity(arr.len());
    for item in arr {
        events.push(
            parse_single_event(item)
                .map_err(|e| CalendarStoreError::Backend(format!("parse error: {e}")))?,
        );
    }
    Ok(events)
}

fn parse_single_event(v: &serde_json::Value) -> Result<CalendarEvent, String> {
    Ok(CalendarEvent {
        identifier: v["identifier"].as_str().unwrap_or_default().to_owned(),
        calendar_id: v["calendar_id"].as_str().unwrap_or_default().to_owned(),
        title: v["title"].as_str().unwrap_or_default().to_owned(),
        start: v["start"].as_str().unwrap_or_default().to_owned(),
        end: v["end"].as_str().unwrap_or_default().to_owned(),
        location: v["location"].as_str().map(str::to_owned),
        notes: v["notes"].as_str().map(str::to_owned),
        is_all_day: v["is_all_day"].as_bool().unwrap_or(false),
        alarms: v["alarms"]
            .as_array()
            .map(|a| a.iter().filter_map(|v| v.as_i64()).collect())
            .unwrap_or_default(),
    })
}

// ─── ReminderStore ───────────────────────────────────────────────────────────

/// AppleScript-backed reminder store using JXA to bridge to Reminders.app.
pub struct ApplescriptReminderStore;

impl ReminderStore for ApplescriptReminderStore {
    fn list_reminder_lists(&self) -> Result<Vec<ReminderList>, ReminderStoreError> {
        let script = r#"
            var app = Application("Reminders");
            var lists = app.lists();
            JSON.stringify(lists.map(function(l) {
                return {
                    identifier: l.id(),
                    title: l.name(),
                    item_count: l.reminders.whose({completed: false})().length
                };
            }));
        "#;

        let value = run_jxa(script).map_err(ReminderStoreError::Backend)?;
        let arr = value
            .as_array()
            .ok_or_else(|| ReminderStoreError::Backend("expected JSON array".to_owned()))?;

        let mut lists = Vec::with_capacity(arr.len());
        for item in arr {
            lists.push(ReminderList {
                identifier: item["identifier"].as_str().unwrap_or_default().to_owned(),
                title: item["title"].as_str().unwrap_or_default().to_owned(),
                item_count: item["item_count"].as_u64().unwrap_or(0) as usize,
            });
        }
        Ok(lists)
    }

    fn list_reminders(&self, query: &ReminderQuery) -> Result<Vec<Reminder>, ReminderStoreError> {
        let list_filter = if let Some(ref list_id) = query.list_id {
            let escaped = jxa_escape(list_id);
            format!(r#"var lists = app.lists.whose({{id: "{escaped}"}})();"#)
        } else {
            "var lists = app.lists();".to_owned()
        };

        let completed_filter = if query.include_completed {
            "".to_owned()
        } else {
            "rems = rems.filter(function(r) { return !r.completed(); });".to_owned()
        };

        let script = format!(
            r#"
            var app = Application("Reminders");
            {list_filter}
            var rems = [];
            lists.forEach(function(l) {{
                l.reminders().forEach(function(r) {{
                    rems.push(r);
                }});
            }});
            {completed_filter}
            rems = rems.slice(0, {limit});
            JSON.stringify(rems.map(function(r) {{
                return {{
                    identifier: r.id(),
                    list_id: r.container().id(),
                    title: r.name(),
                    notes: r.body() || null,
                    due_date: r.dueDate() ? r.dueDate().toISOString() : null,
                    priority: r.priority(),
                    is_completed: r.completed(),
                    completion_date: r.completionDate() ? r.completionDate().toISOString() : null
                }};
            }}));
            "#,
            limit = query.limit,
        );

        let value = run_jxa(&script).map_err(ReminderStoreError::Backend)?;
        parse_reminders_json(&value)
    }

    fn get_reminder(&self, identifier: &str) -> Result<Option<Reminder>, ReminderStoreError> {
        let escaped_id = jxa_escape(identifier);
        let script = format!(
            r#"
            var app = Application("Reminders");
            var found = null;
            var lists = app.lists();
            for (var i = 0; i < lists.length; i++) {{
                var matches = lists[i].reminders.whose({{id: "{escaped_id}"}})();
                if (matches.length > 0) {{
                    var r = matches[0];
                    found = {{
                        identifier: r.id(),
                        list_id: r.container().id(),
                        title: r.name(),
                        notes: r.body() || null,
                        due_date: r.dueDate() ? r.dueDate().toISOString() : null,
                        priority: r.priority(),
                        is_completed: r.completed(),
                        completion_date: r.completionDate() ? r.completionDate().toISOString() : null
                    }};
                    break;
                }}
            }}
            JSON.stringify(found);
            "#,
        );

        let value = run_jxa(&script).map_err(ReminderStoreError::Backend)?;
        if value.is_null() {
            return Ok(None);
        }
        let reminder = parse_single_reminder(&value)
            .map_err(|e| ReminderStoreError::Backend(format!("parse error: {e}")))?;
        Ok(Some(reminder))
    }

    fn create_reminder(&self, reminder: &NewReminder) -> Result<Reminder, ReminderStoreError> {
        let title = jxa_escape(&reminder.title);
        let list_line = if let Some(ref list_id) = reminder.list_id {
            let escaped = jxa_escape(list_id);
            format!(
                r#"var list = app.lists.whose({{id: "{escaped}"}})()[0];
                if (!list) {{ list = app.defaultList(); }}"#
            )
        } else {
            "var list = app.defaultList();".to_owned()
        };

        let notes_prop = reminder
            .notes
            .as_deref()
            .map(|n| format!(r#", body: "{}""#, jxa_escape(n)))
            .unwrap_or_default();

        let due_prop = reminder
            .due_date
            .as_deref()
            .map(|d| format!(r#", dueDate: new Date("{}")"#, jxa_escape(d)))
            .unwrap_or_default();

        let priority = reminder.priority.unwrap_or(0);

        let script = format!(
            r#"
            var app = Application("Reminders");
            {list_line}
            var r = app.Reminder({{
                name: "{title}",
                priority: {priority}
                {notes_prop}
                {due_prop}
            }});
            list.reminders.push(r);
            JSON.stringify({{
                identifier: r.id(),
                list_id: list.id(),
                title: r.name(),
                notes: r.body() || null,
                due_date: r.dueDate() ? r.dueDate().toISOString() : null,
                priority: r.priority(),
                is_completed: r.completed(),
                completion_date: null
            }});
            "#,
        );

        let value = run_jxa(&script).map_err(ReminderStoreError::Backend)?;
        parse_single_reminder(&value)
            .map_err(|e| ReminderStoreError::Backend(format!("parse error: {e}")))
    }

    fn set_completed(
        &self,
        identifier: &str,
        completed: bool,
    ) -> Result<Reminder, ReminderStoreError> {
        let escaped_id = jxa_escape(identifier);
        let completed_val = if completed { "true" } else { "false" };

        let script = format!(
            r#"
            var app = Application("Reminders");
            var found = null;
            var lists = app.lists();
            for (var i = 0; i < lists.length; i++) {{
                var matches = lists[i].reminders.whose({{id: "{escaped_id}"}})();
                if (matches.length > 0) {{
                    var r = matches[0];
                    r.completed = {completed_val};
                    found = {{
                        identifier: r.id(),
                        list_id: r.container().id(),
                        title: r.name(),
                        notes: r.body() || null,
                        due_date: r.dueDate() ? r.dueDate().toISOString() : null,
                        priority: r.priority(),
                        is_completed: r.completed(),
                        completion_date: r.completionDate() ? r.completionDate().toISOString() : null
                    }};
                    break;
                }}
            }}
            if (!found) {{ throw new Error("Reminder not found: {escaped_id}"); }}
            JSON.stringify(found);
            "#,
        );

        let value = run_jxa(&script).map_err(|e| {
            if e.contains("not found") {
                ReminderStoreError::NotFound
            } else {
                ReminderStoreError::Backend(e)
            }
        })?;
        parse_single_reminder(&value)
            .map_err(|e| ReminderStoreError::Backend(format!("parse error: {e}")))
    }
}

fn parse_reminders_json(value: &serde_json::Value) -> Result<Vec<Reminder>, ReminderStoreError> {
    let arr = value
        .as_array()
        .ok_or_else(|| ReminderStoreError::Backend("expected JSON array".to_owned()))?;
    let mut reminders = Vec::with_capacity(arr.len());
    for item in arr {
        reminders.push(
            parse_single_reminder(item)
                .map_err(|e| ReminderStoreError::Backend(format!("parse error: {e}")))?,
        );
    }
    Ok(reminders)
}

fn parse_single_reminder(v: &serde_json::Value) -> Result<Reminder, String> {
    Ok(Reminder {
        identifier: v["identifier"].as_str().unwrap_or_default().to_owned(),
        list_id: v["list_id"].as_str().unwrap_or_default().to_owned(),
        title: v["title"].as_str().unwrap_or_default().to_owned(),
        notes: v["notes"].as_str().map(str::to_owned),
        due_date: v["due_date"].as_str().map(str::to_owned),
        priority: v["priority"].as_u64().unwrap_or(0) as u8,
        is_completed: v["is_completed"].as_bool().unwrap_or(false),
        completion_date: v["completion_date"].as_str().map(str::to_owned),
    })
}

// ─── NoteStore ───────────────────────────────────────────────────────────────

/// AppleScript-backed note store using JXA to bridge to Notes.app.
pub struct ApplescriptNoteStore;

impl NoteStore for ApplescriptNoteStore {
    fn list_notes(&self, query: &NoteQuery) -> Result<Vec<Note>, NoteStoreError> {
        let folder_filter = if let Some(ref folder) = query.folder {
            let escaped = jxa_escape(folder);
            format!(
                r#"var folders = app.folders.whose({{name: "{escaped}"}})();
                var notes = [];
                folders.forEach(function(f) {{ notes = notes.concat(f.notes()); }});"#
            )
        } else {
            "var notes = app.notes();".to_owned()
        };

        let search_filter = if let Some(ref search) = query.search {
            let escaped = jxa_escape(search);
            format!(
                r#"
                var lower = "{escaped}".toLowerCase();
                notes = notes.filter(function(n) {{
                    return n.name().toLowerCase().indexOf(lower) !== -1
                        || n.plaintext().toLowerCase().indexOf(lower) !== -1;
                }});
                "#
            )
        } else {
            String::new()
        };

        let script = format!(
            r#"
            var app = Application("Notes");
            {folder_filter}
            {search_filter}
            notes = notes.slice(0, {limit});
            JSON.stringify(notes.map(function(n) {{
                return {{
                    identifier: n.id(),
                    title: n.name(),
                    body: n.plaintext().substring(0, 200),
                    folder: n.container() ? n.container().name() : null,
                    created_at: n.creationDate() ? n.creationDate().toISOString() : null,
                    modified_at: n.modificationDate() ? n.modificationDate().toISOString() : null
                }};
            }}));
            "#,
            limit = query.limit,
        );

        let value = run_jxa(&script).map_err(NoteStoreError::Backend)?;
        parse_notes_json(&value)
    }

    fn get_note(&self, identifier: &str) -> Result<Option<Note>, NoteStoreError> {
        let escaped_id = jxa_escape(identifier);
        let script = format!(
            r#"
            var app = Application("Notes");
            var matches = app.notes.whose({{id: "{escaped_id}"}})();
            if (matches.length === 0) {{ JSON.stringify(null); }}
            else {{
                var n = matches[0];
                JSON.stringify({{
                    identifier: n.id(),
                    title: n.name(),
                    body: n.plaintext(),
                    folder: n.container() ? n.container().name() : null,
                    created_at: n.creationDate() ? n.creationDate().toISOString() : null,
                    modified_at: n.modificationDate() ? n.modificationDate().toISOString() : null
                }});
            }}
            "#,
        );

        let value = run_jxa(&script).map_err(NoteStoreError::Backend)?;
        if value.is_null() {
            return Ok(None);
        }
        let note = parse_single_note(&value)
            .map_err(|e| NoteStoreError::Backend(format!("parse error: {e}")))?;
        Ok(Some(note))
    }

    fn create_note(&self, note: &NewNote) -> Result<Note, NoteStoreError> {
        let title = jxa_escape(&note.title);
        let body = jxa_escape(&note.body);
        let folder_line = if let Some(ref folder) = note.folder {
            let escaped = jxa_escape(folder);
            format!(
                r#"var folder = app.folders.whose({{name: "{escaped}"}})()[0];
                if (folder) {{ folder.notes.push(n); }} else {{ app.notes.push(n); }}"#
            )
        } else {
            "app.notes.push(n);".to_owned()
        };

        let script = format!(
            r#"
            var app = Application("Notes");
            var n = app.Note({{name: "{title}", body: "{body}"}});
            {folder_line}
            JSON.stringify({{
                identifier: n.id(),
                title: n.name(),
                body: n.plaintext(),
                folder: n.container() ? n.container().name() : null,
                created_at: n.creationDate() ? n.creationDate().toISOString() : null,
                modified_at: n.modificationDate() ? n.modificationDate().toISOString() : null
            }});
            "#,
        );

        let value = run_jxa(&script).map_err(NoteStoreError::Backend)?;
        parse_single_note(&value).map_err(|e| NoteStoreError::Backend(format!("parse error: {e}")))
    }

    fn append_to_note(&self, identifier: &str, content: &str) -> Result<Note, NoteStoreError> {
        let escaped_id = jxa_escape(identifier);
        let escaped_content = jxa_escape(content);

        let script = format!(
            r#"
            var app = Application("Notes");
            var matches = app.notes.whose({{id: "{escaped_id}"}})();
            if (matches.length === 0) {{ throw new Error("Note not found: {escaped_id}"); }}
            var n = matches[0];
            n.body = n.plaintext() + "\n" + "{escaped_content}";
            JSON.stringify({{
                identifier: n.id(),
                title: n.name(),
                body: n.plaintext(),
                folder: n.container() ? n.container().name() : null,
                created_at: n.creationDate() ? n.creationDate().toISOString() : null,
                modified_at: n.modificationDate() ? n.modificationDate().toISOString() : null
            }});
            "#,
        );

        let value = run_jxa(&script).map_err(|e| {
            if e.contains("not found") {
                NoteStoreError::NotFound
            } else {
                NoteStoreError::Backend(e)
            }
        })?;
        parse_single_note(&value).map_err(|e| NoteStoreError::Backend(format!("parse error: {e}")))
    }
}

fn parse_notes_json(value: &serde_json::Value) -> Result<Vec<Note>, NoteStoreError> {
    let arr = value
        .as_array()
        .ok_or_else(|| NoteStoreError::Backend("expected JSON array".to_owned()))?;
    let mut notes = Vec::with_capacity(arr.len());
    for item in arr {
        notes.push(
            parse_single_note(item)
                .map_err(|e| NoteStoreError::Backend(format!("parse error: {e}")))?,
        );
    }
    Ok(notes)
}

fn parse_single_note(v: &serde_json::Value) -> Result<Note, String> {
    Ok(Note {
        identifier: v["identifier"].as_str().unwrap_or_default().to_owned(),
        title: v["title"].as_str().unwrap_or_default().to_owned(),
        body: v["body"].as_str().unwrap_or_default().to_owned(),
        folder: v["folder"].as_str().map(str::to_owned),
        created_at: v["created_at"].as_str().map(str::to_owned),
        modified_at: v["modified_at"].as_str().map(str::to_owned),
    })
}

// ─── MailStore ───────────────────────────────────────────────────────────────

/// AppleScript-backed mail store using JXA to bridge to Mail.app.
pub struct ApplescriptMailStore;

impl MailStore for ApplescriptMailStore {
    fn list_messages(&self, query: &MailQuery) -> Result<Vec<Mail>, MailStoreError> {
        let mailbox_filter = if let Some(ref mailbox) = query.mailbox {
            let escaped = jxa_escape(mailbox);
            format!(
                r#"
                var accts = app.accounts();
                var msgs = [];
                accts.forEach(function(a) {{
                    try {{
                        var mb = a.mailboxes.whose({{name: "{escaped}"}})()[0];
                        if (mb) {{ msgs = msgs.concat(mb.messages()); }}
                    }} catch(e) {{}}
                }});
                "#
            )
        } else {
            r#"
            var inbox = app.inbox();
            var msgs = inbox.messages();
            "#
            .to_owned()
        };

        let search_filter = if let Some(ref search) = query.search {
            let escaped = jxa_escape(search);
            format!(
                r#"
                var lower = "{escaped}".toLowerCase();
                msgs = msgs.filter(function(m) {{
                    return (m.subject() || "").toLowerCase().indexOf(lower) !== -1
                        || (m.sender() || "").toLowerCase().indexOf(lower) !== -1;
                }});
                "#
            )
        } else {
            String::new()
        };

        let unread_filter = if query.unread_only {
            "msgs = msgs.filter(function(m) { return !m.readStatus(); });".to_owned()
        } else {
            String::new()
        };

        let script = format!(
            r#"
            var app = Application("Mail");
            {mailbox_filter}
            {search_filter}
            {unread_filter}
            msgs = msgs.slice(0, {limit});
            JSON.stringify(msgs.map(function(m) {{
                return {{
                    identifier: m.id() + "",
                    from: m.sender() || "",
                    to: (m.toRecipients() || []).map(function(r) {{ return r.address(); }}).join(", "),
                    subject: m.subject() || "",
                    body: (m.content() || "").substring(0, 500),
                    mailbox: m.mailbox() ? m.mailbox().name() : null,
                    is_read: m.readStatus(),
                    date: m.dateReceived() ? m.dateReceived().toISOString() : null
                }};
            }}));
            "#,
            limit = query.limit,
        );

        let value = run_jxa(&script).map_err(MailStoreError::Backend)?;
        parse_mails_json(&value)
    }

    fn get_message(&self, identifier: &str) -> Result<Option<Mail>, MailStoreError> {
        let escaped_id = jxa_escape(identifier);
        let script = format!(
            r#"
            var app = Application("Mail");
            var found = null;
            var inbox = app.inbox();
            var msgs = inbox.messages();
            for (var i = 0; i < msgs.length; i++) {{
                if ((msgs[i].id() + "") === "{escaped_id}") {{
                    var m = msgs[i];
                    found = {{
                        identifier: m.id() + "",
                        from: m.sender() || "",
                        to: (m.toRecipients() || []).map(function(r) {{ return r.address(); }}).join(", "),
                        subject: m.subject() || "",
                        body: m.content() || "",
                        mailbox: m.mailbox() ? m.mailbox().name() : null,
                        is_read: m.readStatus(),
                        date: m.dateReceived() ? m.dateReceived().toISOString() : null
                    }};
                    break;
                }}
            }}
            JSON.stringify(found);
            "#,
        );

        let value = run_jxa(&script).map_err(MailStoreError::Backend)?;
        if value.is_null() {
            return Ok(None);
        }
        let mail = parse_single_mail(&value)
            .map_err(|e| MailStoreError::Backend(format!("parse error: {e}")))?;
        Ok(Some(mail))
    }

    fn compose(&self, mail: &NewMail) -> Result<Mail, MailStoreError> {
        let to = jxa_escape(&mail.to);
        let subject = jxa_escape(&mail.subject);
        let body = jxa_escape(&mail.body);
        let cc_line = mail
            .cc
            .as_deref()
            .map(|cc| {
                let escaped = jxa_escape(cc);
                format!(
                    r#"
                    "{escaped}".split(",").forEach(function(addr) {{
                        msg.ccRecipients.push(app.CcRecipient({{address: addr.trim()}}));
                    }});
                    "#
                )
            })
            .unwrap_or_default();

        let script = format!(
            r#"
            var app = Application("Mail");
            var msg = app.OutgoingMessage({{
                subject: "{subject}",
                content: "{body}",
                visible: true
            }});
            app.outgoingMessages.push(msg);
            "{to}".split(",").forEach(function(addr) {{
                msg.toRecipients.push(app.Recipient({{address: addr.trim()}}));
            }});
            {cc_line}
            msg.send();
            JSON.stringify({{
                identifier: msg.id() + "",
                from: "",
                to: "{to}",
                subject: "{subject}",
                body: "{body}",
                mailbox: "Sent",
                is_read: true,
                date: new Date().toISOString()
            }});
            "#,
        );

        let value = run_jxa(&script).map_err(MailStoreError::Backend)?;
        parse_single_mail(&value).map_err(|e| MailStoreError::Backend(format!("parse error: {e}")))
    }
}

fn parse_mails_json(value: &serde_json::Value) -> Result<Vec<Mail>, MailStoreError> {
    let arr = value
        .as_array()
        .ok_or_else(|| MailStoreError::Backend("expected JSON array".to_owned()))?;
    let mut mails = Vec::with_capacity(arr.len());
    for item in arr {
        mails.push(
            parse_single_mail(item)
                .map_err(|e| MailStoreError::Backend(format!("parse error: {e}")))?,
        );
    }
    Ok(mails)
}

fn parse_single_mail(v: &serde_json::Value) -> Result<Mail, String> {
    Ok(Mail {
        identifier: v["identifier"].as_str().unwrap_or_default().to_owned(),
        from: v["from"].as_str().unwrap_or_default().to_owned(),
        to: v["to"].as_str().unwrap_or_default().to_owned(),
        subject: v["subject"].as_str().unwrap_or_default().to_owned(),
        body: v["body"].as_str().unwrap_or_default().to_owned(),
        mailbox: v["mailbox"].as_str().map(str::to_owned),
        is_read: v["is_read"].as_bool().unwrap_or(false),
        date: v["date"].as_str().map(str::to_owned),
    })
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn jxa_escape_handles_special_chars() {
        assert_eq!(jxa_escape(r#"hello "world""#), r#"hello \"world\""#);
        assert_eq!(jxa_escape("line1\nline2"), "line1\\nline2");
        assert_eq!(jxa_escape(r"back\slash"), r"back\\slash");
    }

    #[test]
    fn parse_single_contact_from_json() {
        let json = serde_json::json!({
            "identifier": "ABC-123",
            "given_name": "Alice",
            "family_name": "Smith",
            "emails": ["alice@example.com"],
            "phones": ["+1234567890"],
            "addresses": [],
            "birthday": null,
            "organization": "Acme Corp",
            "note": null
        });
        let contact = parse_single_contact(&json).unwrap();
        assert_eq!(contact.identifier, "ABC-123");
        assert_eq!(contact.given_name, "Alice");
        assert_eq!(contact.family_name, "Smith");
        assert_eq!(contact.emails, vec!["alice@example.com"]);
        assert_eq!(contact.organization.as_deref(), Some("Acme Corp"));
    }

    #[test]
    fn parse_single_event_from_json() {
        let json = serde_json::json!({
            "identifier": "EVT-001",
            "calendar_id": "CAL-001",
            "title": "Team Meeting",
            "start": "2026-03-01T09:00:00Z",
            "end": "2026-03-01T10:00:00Z",
            "location": "Room 42",
            "notes": null,
            "is_all_day": false,
            "alarms": [-15]
        });
        let event = parse_single_event(&json).unwrap();
        assert_eq!(event.identifier, "EVT-001");
        assert_eq!(event.title, "Team Meeting");
        assert_eq!(event.location.as_deref(), Some("Room 42"));
        assert!(!event.is_all_day);
    }

    #[test]
    fn parse_single_reminder_from_json() {
        let json = serde_json::json!({
            "identifier": "REM-001",
            "list_id": "LIST-001",
            "title": "Buy groceries",
            "notes": "Milk, eggs",
            "due_date": "2026-03-01T18:00:00Z",
            "priority": 1,
            "is_completed": false,
            "completion_date": null
        });
        let reminder = parse_single_reminder(&json).unwrap();
        assert_eq!(reminder.identifier, "REM-001");
        assert_eq!(reminder.title, "Buy groceries");
        assert_eq!(reminder.priority, 1);
        assert!(!reminder.is_completed);
    }

    #[test]
    fn parse_single_note_from_json() {
        let json = serde_json::json!({
            "identifier": "NOTE-001",
            "title": "Shopping list",
            "body": "Apples, Oranges",
            "folder": "Personal",
            "created_at": "2026-02-20T10:00:00Z",
            "modified_at": "2026-02-24T12:00:00Z"
        });
        let note = parse_single_note(&json).unwrap();
        assert_eq!(note.identifier, "NOTE-001");
        assert_eq!(note.title, "Shopping list");
        assert_eq!(note.folder.as_deref(), Some("Personal"));
    }

    #[test]
    fn parse_single_mail_from_json() {
        let json = serde_json::json!({
            "identifier": "MAIL-001",
            "from": "bob@example.com",
            "to": "alice@example.com",
            "subject": "Hello",
            "body": "How are you?",
            "mailbox": "INBOX",
            "is_read": false,
            "date": "2026-02-24T08:00:00Z"
        });
        let mail = parse_single_mail(&json).unwrap();
        assert_eq!(mail.identifier, "MAIL-001");
        assert_eq!(mail.from, "bob@example.com");
        assert!(!mail.is_read);
    }

    #[test]
    fn stores_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ApplescriptContactStore>();
        assert_send_sync::<ApplescriptCalendarStore>();
        assert_send_sync::<ApplescriptReminderStore>();
        assert_send_sync::<ApplescriptNoteStore>();
        assert_send_sync::<ApplescriptMailStore>();
    }
}
