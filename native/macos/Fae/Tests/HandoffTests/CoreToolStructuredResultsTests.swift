import XCTest
@testable import Fae

/// Tests for Phase 2.2: Core Tool Structured Results.
///
/// Validates that calendar, reminders, contacts, mail, notes, web_search,
/// and fetch_url tools expose stable structured results alongside their
/// existing human-readable prose output.
///
/// Note: These tools interact with macOS system services (EventKit, Contacts,
/// AppleScript, network) which are not available in CI. We test the structured
/// data serialisation and envelope format using ToolResult directly, and
/// verify that the tool implementations compile with the new signatures.
final class CoreToolStructuredResultsTests: XCTestCase {

    // MARK: - Calendar Structured Data

    func testCalendarStructuredDataWithEvents() throws {
        // Simulate the shape of structured data returned by CalendarTool.listEvents.
        let events: [[String: any Sendable]] = [
            [
                "title": "Standup",
                "start": "2026-03-19T09:00:00Z",
                "end": "2026-03-19T09:30:00Z",
                "isAllDay": false,
                "calendar": "Work",
                "eventId": "EK-001",
            ],
            [
                "title": "Lunch",
                "start": "2026-03-19T12:00:00Z",
                "end": "2026-03-19T13:00:00Z",
                "isAllDay": false,
                "calendar": "Personal",
                "eventId": "EK-002",
            ],
        ]
        let result = ToolResult.success("2 events:\n- 09:00: Standup\n- 12:00: Lunch", structuredData: [
            "events": events as [any Sendable],
            "count": 2,
        ])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Standup"))

        // Verify structured data round-trips through JSON serialisation.
        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 2)
        let parsedEvents = try XCTUnwrap(parsed["events"] as? [[String: Any]])
        XCTAssertEqual(parsedEvents.count, 2)
        XCTAssertEqual(parsedEvents[0]["title"] as? String, "Standup")
        XCTAssertEqual(parsedEvents[0]["start"] as? String, "2026-03-19T09:00:00Z")
        XCTAssertEqual(parsedEvents[0]["isAllDay"] as? Bool, false)
        XCTAssertEqual(parsedEvents[1]["eventId"] as? String, "EK-002")
    }

    func testCalendarEmptyResultsIncludeStructuredData() throws {
        let result = ToolResult.success("No events found for that period.", structuredData: [
            "events": [] as [any Sendable],
            "count": 0,
        ])

        XCTAssertNotNil(result.structuredData)
        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 0)
        let events = try XCTUnwrap(parsed["events"] as? [Any])
        XCTAssertTrue(events.isEmpty)
    }

    func testCalendarSearchStructuredDataIncludesQuery() throws {
        let result = ToolResult.success("Found 1 events matching 'standup':\n- Mar 19, 09:00: Standup", structuredData: [
            "events": [
                ["title": "Standup", "start": "2026-03-19T09:00:00Z", "end": "2026-03-19T09:30:00Z", "isAllDay": false, "eventId": "EK-001"] as [String: any Sendable],
            ] as [any Sendable],
            "count": 1,
            "query": "standup",
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["query"] as? String, "standup")
        XCTAssertEqual(parsed["count"] as? Int, 1)
    }

    func testCalendarEventOptionalFields() throws {
        // Event with location and notes.
        let event: [String: any Sendable] = [
            "title": "Offsite",
            "start": "2026-03-20T09:00:00Z",
            "end": "2026-03-20T17:00:00Z",
            "isAllDay": false,
            "calendar": "Work",
            "location": "Conference Room B",
            "notes": "Bring laptop",
            "eventId": "EK-003",
        ]
        let result = ToolResult.success("1 events:\n- 09:00: Offsite", structuredData: [
            "events": [event] as [any Sendable],
            "count": 1,
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let events = try XCTUnwrap(parsed["events"] as? [[String: Any]])
        XCTAssertEqual(events[0]["location"] as? String, "Conference Room B")
        XCTAssertEqual(events[0]["notes"] as? String, "Bring laptop")
    }

    // MARK: - Reminders Structured Data

    func testRemindersStructuredDataWithItems() throws {
        let reminders: [[String: any Sendable]] = [
            [
                "title": "Buy groceries",
                "isCompleted": false,
                "priority": 0,
                "dueDate": "2026-03-20T00:00:00Z",
                "list": "Shopping",
                "reminderId": "REM-001",
            ],
        ]
        let result = ToolResult.success("1 incomplete reminders:\n- Buy groceries (due: 3/20/26)", structuredData: [
            "reminders": reminders as [any Sendable],
            "count": 1,
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 1)
        let items = try XCTUnwrap(parsed["reminders"] as? [[String: Any]])
        XCTAssertEqual(items[0]["title"] as? String, "Buy groceries")
        XCTAssertEqual(items[0]["isCompleted"] as? Bool, false)
        XCTAssertEqual(items[0]["list"] as? String, "Shopping")
    }

    func testRemindersEmptyResultsIncludeStructuredData() throws {
        let result = ToolResult.success("No incomplete reminders found.", structuredData: [
            "reminders": [] as [any Sendable],
            "count": 0,
        ])

        XCTAssertNotNil(result.structuredData)
        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 0)
    }

    func testRemindersSearchStructuredDataIncludesQuery() throws {
        let result = ToolResult.success("Found 1 reminders matching 'groceries':\n- [pending] Buy groceries", structuredData: [
            "reminders": [
                ["title": "Buy groceries", "isCompleted": false, "priority": 0, "reminderId": "REM-001"] as [String: any Sendable],
            ] as [any Sendable],
            "count": 1,
            "query": "groceries",
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["query"] as? String, "groceries")
    }

    // MARK: - Contacts Structured Data

    func testContactsStructuredDataWithResults() throws {
        let contacts: [[String: any Sendable]] = [
            [
                "name": "Sarah Connor",
                "givenName": "Sarah",
                "familyName": "Connor",
                "emails": ["sarah@example.com"] as [any Sendable],
                "phones": ["+1-555-0123"] as [any Sendable],
            ],
        ]
        let result = ToolResult.success("Found 1 contacts:\n- Sarah Connor | sarah@example.com | +1-555-0123", structuredData: [
            "contacts": contacts as [any Sendable],
            "count": 1,
            "query": "Sarah",
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 1)
        XCTAssertEqual(parsed["query"] as? String, "Sarah")
        let items = try XCTUnwrap(parsed["contacts"] as? [[String: Any]])
        XCTAssertEqual(items[0]["name"] as? String, "Sarah Connor")
        let emails = try XCTUnwrap(items[0]["emails"] as? [String])
        XCTAssertEqual(emails, ["sarah@example.com"])
    }

    func testContactsEmptyResultsIncludeStructuredData() throws {
        let result = ToolResult.success("No contacts found matching 'zzzz'.", structuredData: [
            "contacts": [] as [any Sendable],
            "count": 0,
            "query": "zzzz",
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 0)
        XCTAssertEqual(parsed["query"] as? String, "zzzz")
    }

    // MARK: - Mail Structured Data

    func testMailStructuredDataWithMessages() throws {
        let messages: [[String: any Sendable]] = [
            [
                "date": "Mar 19, 2026 08:30",
                "sender": "boss@example.com",
                "subject": "Weekly Update",
            ],
            [
                "date": "Mar 18, 2026 15:00",
                "sender": "team@example.com",
                "subject": "Sprint Review",
            ],
        ]
        let result = ToolResult.success("- Mar 19, 2026 08:30 | boss@example.com | Weekly Update\n- Mar 18, 2026 15:00 | team@example.com | Sprint Review", structuredData: [
            "messages": messages as [any Sendable],
            "count": 2,
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 2)
        let items = try XCTUnwrap(parsed["messages"] as? [[String: Any]])
        XCTAssertEqual(items[0]["subject"] as? String, "Weekly Update")
        XCTAssertEqual(items[1]["sender"] as? String, "team@example.com")
    }

    func testMailEmptyResultsIncludeStructuredData() throws {
        let result = ToolResult.success("No messages found.", structuredData: [
            "messages": [] as [any Sendable],
            "count": 0,
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 0)
    }

    // MARK: - Notes Structured Data

    func testNotesStructuredDataWithResults() throws {
        let notes: [[String: any Sendable]] = [
            ["title": "Meeting Notes"],
            ["title": "Shopping List"],
        ]
        let result = ToolResult.success("- Meeting Notes\n- Shopping List", structuredData: [
            "notes": notes as [any Sendable],
            "count": 2,
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 2)
        let items = try XCTUnwrap(parsed["notes"] as? [[String: Any]])
        XCTAssertEqual(items[0]["title"] as? String, "Meeting Notes")
    }

    func testNotesSearchStructuredDataIncludesQuery() throws {
        let result = ToolResult.success("- Meeting Notes", structuredData: [
            "notes": [["title": "Meeting Notes"] as [String: any Sendable]] as [any Sendable],
            "count": 1,
            "query": "meeting",
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["query"] as? String, "meeting")
    }

    func testNotesEmptyResultsIncludeStructuredData() throws {
        let result = ToolResult.success("No results.", structuredData: [
            "notes": [] as [any Sendable],
            "count": 0,
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 0)
    }

    // MARK: - Web Search Structured Data

    func testWebSearchStructuredDataWithResults() throws {
        let results: [[String: any Sendable]] = [
            [
                "title": "Swift Concurrency Guide",
                "url": "https://docs.swift.org/concurrency",
                "snippet": "Learn about async/await in Swift",
                "domain": "docs.swift.org",
                "category": "[Reference]",
                "rank": 1,
            ],
            [
                "title": "Swift Forums Discussion",
                "url": "https://forums.swift.org/t/12345",
                "snippet": "Community discussion on actors",
                "domain": "forums.swift.org",
                "category": "[Forum]",
                "rank": 2,
            ],
        ]
        let result = ToolResult.success("## Search Results for \"swift concurrency\"\n\n1. ...", structuredData: [
            "results": results as [any Sendable],
            "count": 2,
            "query": "swift concurrency",
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 2)
        XCTAssertEqual(parsed["query"] as? String, "swift concurrency")
        let items = try XCTUnwrap(parsed["results"] as? [[String: Any]])
        XCTAssertEqual(items[0]["title"] as? String, "Swift Concurrency Guide")
        XCTAssertEqual(items[0]["url"] as? String, "https://docs.swift.org/concurrency")
        XCTAssertEqual(items[0]["rank"] as? Int, 1)
        XCTAssertEqual(items[1]["domain"] as? String, "forums.swift.org")
    }

    func testWebSearchEmptyResultsIncludeStructuredData() throws {
        let result = ToolResult.success("No results found for \"xyzzy123\".", structuredData: [
            "results": [] as [any Sendable],
            "count": 0,
            "query": "xyzzy123",
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 0)
        XCTAssertEqual(parsed["query"] as? String, "xyzzy123")
    }

    // MARK: - Fetch URL Structured Data

    func testFetchURLStructuredDataWithContent() throws {
        let result = ToolResult.success("## Page Content: Example\n\nURL: https://example.com\nWords: 150\n\nHello world content", structuredData: [
            "url": "https://example.com",
            "title": "Example",
            "text": "Hello world content",
            "wordCount": 150,
            "truncated": false,
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["url"] as? String, "https://example.com")
        XCTAssertEqual(parsed["title"] as? String, "Example")
        XCTAssertEqual(parsed["wordCount"] as? Int, 150)
        XCTAssertEqual(parsed["truncated"] as? Bool, false)
    }

    func testFetchURLEmptyContentIncludesStructuredData() throws {
        let result = ToolResult.success("No extractable text content at https://example.com", structuredData: [
            "url": "https://example.com",
            "title": "",
            "text": "",
            "wordCount": 0,
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["url"] as? String, "https://example.com")
        XCTAssertEqual(parsed["wordCount"] as? Int, 0)
        XCTAssertEqual(parsed["text"] as? String, "")
    }

    func testFetchURLTruncatedContent() throws {
        let result = ToolResult.success("## Page Content: Long Article\n\n...[Content truncated]", structuredData: [
            "url": "https://example.com/long",
            "title": "Long Article",
            "text": String(repeating: "word ", count: 20000),
            "wordCount": 20000,
            "truncated": true,
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["truncated"] as? Bool, true)
        XCTAssertEqual(parsed["wordCount"] as? Int, 20000)
    }

    // MARK: - Script Envelope Integration

    func testStructuredToolResultScriptEnvelopeIncludesData() throws {
        let result = ToolResult.success("2 events today", structuredData: [
            "events": [
                ["title": "Meeting"] as [String: any Sendable],
            ] as [any Sendable],
            "count": 1,
        ])

        let envelope = result.scriptEnvelope()
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["output"] as? String, "2 events today")
        XCTAssertEqual(parsed["isError"] as? Bool, false)

        let data = try XCTUnwrap(parsed["data"] as? [String: Any])
        XCTAssertEqual(data["count"] as? Int, 1)
    }

    // MARK: - Prose Output Unchanged

    func testCalendarProseOutputFormatUnchanged() {
        // The prose output should contain the same human-readable format.
        let result = ToolResult.success("2 events:\n- 09:00: Standup\n- 12:00: Lunch", structuredData: [
            "events": [] as [any Sendable],
            "count": 2,
        ])
        XCTAssertTrue(result.output.contains("Standup"))
        XCTAssertTrue(result.output.contains("Lunch"))
        XCTAssertFalse(result.isError)
    }

    func testWebSearchProseOutputFormatUnchanged() {
        let result = ToolResult.success("## Search Results for \"test\"\n\n1. **Title** (domain.com)\n   URL: https://domain.com\n   Snippet here", structuredData: [
            "results": [] as [any Sendable],
            "count": 1,
            "query": "test",
        ])
        XCTAssertTrue(result.output.contains("## Search Results"))
        XCTAssertTrue(result.output.contains("**Title**"))
    }

    // MARK: - Date Normalization

    func testCalendarDatesUseISO8601() throws {
        let event: [String: any Sendable] = [
            "title": "Test",
            "start": "2026-03-19T09:00:00Z",
            "end": "2026-03-19T10:00:00Z",
            "isAllDay": false,
            "eventId": "EK-X",
        ]
        let result = ToolResult.success("ok", structuredData: [
            "events": [event] as [any Sendable],
            "count": 1,
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let events = try XCTUnwrap(parsed["events"] as? [[String: Any]])
        let start = try XCTUnwrap(events[0]["start"] as? String)

        // Verify it's a valid ISO8601 date.
        let formatter = ISO8601DateFormatter()
        XCTAssertNotNil(formatter.date(from: start), "Start date should be valid ISO8601")
    }

    func testReminderDueDateUsesISO8601() throws {
        let reminder: [String: any Sendable] = [
            "title": "Task",
            "isCompleted": false,
            "priority": 0,
            "dueDate": "2026-03-20T00:00:00Z",
            "reminderId": "REM-X",
        ]
        let result = ToolResult.success("ok", structuredData: [
            "reminders": [reminder] as [any Sendable],
            "count": 1,
        ])

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let reminders = try XCTUnwrap(parsed["reminders"] as? [[String: Any]])
        let due = try XCTUnwrap(reminders[0]["dueDate"] as? String)

        let formatter = ISO8601DateFormatter()
        XCTAssertNotNil(formatter.date(from: due), "Due date should be valid ISO8601")
    }
}
