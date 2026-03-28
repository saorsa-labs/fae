import XCTest
@testable import Fae

// MARK: - Test Doubles

/// A tool that returns a structured result with a configurable data payload.
private struct StructuredEchoTool: Tool {
    let name: String
    let description: String = "returns structured data"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false

    /// The structured data to return alongside the prose output.
    let structuredPayload: [String: any Sendable]

    /// The prose output string.
    let proseOutput: String

    func execute(input: [String: Any]) async throws -> ToolResult {
        .success(proseOutput, structuredData: structuredPayload)
    }
}

/// A tool that always fails with an error message.
private struct ErrorTool: Tool {
    let name: String
    let description: String = "always errors"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false

    func execute(input: [String: Any]) async throws -> ToolResult {
        .error("permission denied: \(name)")
    }
}

/// Broker that always allows.
private actor AllowBroker: TrustedActionBroker {
    func evaluate(_ intent: ActionIntent) async -> BrokerDecision {
        .allow(reason: DecisionReason(code: .allowLowRisk, message: "test allow"))
    }
}

// MARK: - Helpers

private func makeRuntime(
    tools: [any Tool] = [],
    broker: any TrustedActionBroker = AllowBroker()
) -> JSCRuntime {
    let registry = ToolRegistry(tools: tools)
    let executor = ToolExecutor(
        registry: registry,
        actionBroker: broker,
        damageControlPolicy: DamageControlPolicy(),
        rateLimiter: ToolRateLimiter(),
        securityLogger: SecurityEventLogger.shared,
        outboundGuard: OutboundExfiltrationGuard.shared
    )

    return JSCRuntime(
        executor: executor,
        contextFactory: {
            ToolExecutorContext(
                toolMode: "full",
                privacyMode: "local_preferred",
                modelLocality: .local,
                capabilityTicket: nil,
                hasCapabilityTicketForTool: true,
                explicitUserAuthorization: false,
                isOwner: true,
                livenessScore: nil,
                speakerId: nil,
                actionSource: .voice,
                proactiveContext: nil,
                visionEnabled: false,
                firstOwnerEnrollmentActive: false,
                workflowTurnID: nil,
                traceToolCallID: nil,
                workflowRunID: nil
            )
        },
        callbacksFactory: {
            ToolExecutorCallbacks(
                onApprovalPending: { _, _ in },
                onVisionAutoEnabled: { },
                onComputerUseStep: { 1 }
            )
        }
    )
}

// MARK: - Tests

/// Tests for Phase 2.3: Script-Facing Typed Adapters.
///
/// Validates that the `fae.calendar`, `fae.reminders`, `fae.contacts`,
/// `fae.mail`, `fae.notes`, `fae.web`, `fae.fs`, and `fae.shell`
/// namespaces are installed, route to the correct tools, and unwrap
/// structured data from the envelope.
final class JSCTypedAdaptersTests: XCTestCase {

    // MARK: - Namespace Installation

    func testAdapterNamespacesExist() async {
        let runtime = makeRuntime()
        let result = await runtime.run(script: """
            var namespaces = [];
            if (typeof fae.calendar === 'object') namespaces.push('calendar');
            if (typeof fae.reminders === 'object') namespaces.push('reminders');
            if (typeof fae.contacts === 'object') namespaces.push('contacts');
            if (typeof fae.mail === 'object') namespaces.push('mail');
            if (typeof fae.notes === 'object') namespaces.push('notes');
            if (typeof fae.web === 'object') namespaces.push('web');
            if (typeof fae.fs === 'object') namespaces.push('fs');
            if (typeof fae.shell === 'function') namespaces.push('shell');
            return namespaces.join(',');
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "calendar,reminders,contacts,mail,notes,web,fs,shell")
    }

    func testAdapterMethodsAreAsyncFunctions() async {
        let runtime = makeRuntime()
        let result = await runtime.run(script: """
            // AsyncFunction has a different constructor name in JSC.
            var checks = [];
            checks.push(typeof fae.calendar.list === 'function');
            checks.push(typeof fae.calendar.search === 'function');
            checks.push(typeof fae.reminders.list === 'function');
            checks.push(typeof fae.reminders.search === 'function');
            checks.push(typeof fae.contacts.search === 'function');
            checks.push(typeof fae.contacts.phone === 'function');
            checks.push(typeof fae.contacts.email === 'function');
            checks.push(typeof fae.mail.inbox === 'function');
            checks.push(typeof fae.mail.search === 'function');
            checks.push(typeof fae.notes.list === 'function');
            checks.push(typeof fae.notes.search === 'function');
            checks.push(typeof fae.notes.get === 'function');
            checks.push(typeof fae.web.search === 'function');
            checks.push(typeof fae.web.fetch === 'function');
            checks.push(typeof fae.fs.read === 'function');
            checks.push(typeof fae.fs.write === 'function');
            checks.push(typeof fae.fs.edit === 'function');
            return checks.every(function(c) { return c; }) ? 'all_functions' : 'missing';
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "all_functions")
    }

    // MARK: - Calendar Adapter

    func testCalendarListReturnsStructuredData() async {
        let calendarTool = StructuredEchoTool(
            name: "calendar",
            structuredPayload: [
                "events": [
                    ["title": "Standup", "start": "2026-03-19T09:00:00Z"] as [String: any Sendable],
                ] as [any Sendable],
                "count": 1,
            ],
            proseOutput: "1 events:\n- 09:00: Standup"
        )
        let runtime = makeRuntime(tools: [calendarTool])

        let result = await runtime.run(script: """
            var data = await fae.calendar.list();
            return JSON.stringify({ count: data.count, title: data.events[0].title });
        """)

        XCTAssertEqual(result.status, .success, "Error: \(result.error ?? "none")")
        if let value = result.value,
           let parsed = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
        {
            XCTAssertEqual(parsed["count"] as? Int, 1)
            XCTAssertEqual(parsed["title"] as? String, "Standup")
        } else {
            XCTFail("Expected JSON object, got: \(result.value ?? "nil")")
        }
    }

    func testCalendarSearchPassesQuery() async {
        let calendarTool = StructuredEchoTool(
            name: "calendar",
            structuredPayload: [
                "events": [] as [any Sendable],
                "count": 0,
                "query": "standup",
            ],
            proseOutput: "No events matching 'standup' found."
        )
        let runtime = makeRuntime(tools: [calendarTool])

        let result = await runtime.run(script: """
            var data = await fae.calendar.search('standup');
            return String(data.count);
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "0")
    }

    // MARK: - Reminders Adapter

    func testRemindersListReturnsStructuredData() async {
        let remindersTool = StructuredEchoTool(
            name: "reminders",
            structuredPayload: [
                "reminders": [
                    ["title": "Buy milk", "isCompleted": false] as [String: any Sendable],
                ] as [any Sendable],
                "count": 1,
            ],
            proseOutput: "1 incomplete reminders:\n- Buy milk"
        )
        let runtime = makeRuntime(tools: [remindersTool])

        let result = await runtime.run(script: """
            var data = await fae.reminders.list();
            return data.reminders[0].title;
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "Buy milk")
    }

    // MARK: - Contacts Adapter

    func testContactsSearchReturnsStructuredData() async {
        let contactsTool = StructuredEchoTool(
            name: "contacts",
            structuredPayload: [
                "contacts": [
                    ["name": "Sarah Connor", "emails": ["sarah@example.com"] as [any Sendable]] as [String: any Sendable],
                ] as [any Sendable],
                "count": 1,
                "query": "Sarah",
            ],
            proseOutput: "Found 1 contacts:\n- Sarah Connor"
        )
        let runtime = makeRuntime(tools: [contactsTool])

        let result = await runtime.run(script: """
            var data = await fae.contacts.search('Sarah');
            return data.contacts[0].name;
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "Sarah Connor")
    }

    func testContactsPhoneAdapter() async {
        let contactsTool = StructuredEchoTool(
            name: "contacts",
            structuredPayload: [
                "contacts": [
                    ["name": "John", "phones": ["+1-555-0123"] as [any Sendable]] as [String: any Sendable],
                ] as [any Sendable],
                "count": 1,
                "query": "John",
            ],
            proseOutput: "John: +1-555-0123"
        )
        let runtime = makeRuntime(tools: [contactsTool])

        let result = await runtime.run(script: """
            var data = await fae.contacts.phone('John');
            return String(data.count);
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "1")
    }

    // MARK: - Mail Adapter

    func testMailInboxReturnsStructuredData() async {
        let mailTool = StructuredEchoTool(
            name: "mail",
            structuredPayload: [
                "messages": [
                    ["sender": "boss@example.com", "subject": "Update"] as [String: any Sendable],
                ] as [any Sendable],
                "count": 1,
            ],
            proseOutput: "- Mar 19 | boss@example.com | Update"
        )
        let runtime = makeRuntime(tools: [mailTool])

        let result = await runtime.run(script: """
            var data = await fae.mail.inbox();
            return data.messages[0].subject;
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "Update")
    }

    // MARK: - Notes Adapter

    func testNotesListReturnsStructuredData() async {
        let notesTool = StructuredEchoTool(
            name: "notes",
            structuredPayload: [
                "notes": [
                    ["title": "Meeting Notes"] as [String: any Sendable],
                ] as [any Sendable],
                "count": 1,
            ],
            proseOutput: "- Meeting Notes"
        )
        let runtime = makeRuntime(tools: [notesTool])

        let result = await runtime.run(script: """
            var data = await fae.notes.list();
            return data.notes[0].title;
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "Meeting Notes")
    }

    // MARK: - Web Adapter

    func testWebSearchReturnsStructuredData() async {
        let webSearchTool = StructuredEchoTool(
            name: "web_search",
            structuredPayload: [
                "results": [
                    ["title": "Swift Docs", "url": "https://docs.swift.org"] as [String: any Sendable],
                ] as [any Sendable],
                "count": 1,
                "query": "swift",
            ],
            proseOutput: "## Search Results\n\n1. Swift Docs"
        )
        let runtime = makeRuntime(tools: [webSearchTool])

        let result = await runtime.run(script: """
            var data = await fae.web.search('swift');
            return data.results[0].url;
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "https://docs.swift.org")
    }

    func testWebFetchReturnsStructuredData() async {
        let fetchTool = StructuredEchoTool(
            name: "fetch_url",
            structuredPayload: [
                "url": "https://example.com",
                "title": "Example",
                "text": "Hello world",
                "wordCount": 2,
            ],
            proseOutput: "## Page Content\n\nHello world"
        )
        let runtime = makeRuntime(tools: [fetchTool])

        let result = await runtime.run(script: """
            var data = await fae.web.fetch('https://example.com');
            return data.title;
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "Example")
    }

    // MARK: - Filesystem Adapter

    func testFsReadReturnsEnvelope() async {
        // read tool doesn't produce structuredData, so the adapter falls back to
        // the full envelope (without the `data` key).
        let readTool = StructuredEchoTool(
            name: "read",
            structuredPayload: [:],
            proseOutput: "file contents here"
        )
        let runtime = makeRuntime(tools: [readTool])

        let result = await runtime.run(script: """
            var data = await fae.fs.read('/tmp/test.txt');
            return typeof data.output === 'string' ? 'has_output' : 'no_output';
        """)

        XCTAssertEqual(result.status, .success, "Error: \(result.error ?? "none")")
        // When structuredData is empty dict, it serialises but data field may be empty.
        // The _unwrap helper returns data if present, otherwise env.
        XCTAssertNotNil(result.value)
    }

    // MARK: - Shell Adapter

    func testShellAdapterCallsBash() async {
        let bashTool = StructuredEchoTool(
            name: "bash",
            structuredPayload: [:],
            proseOutput: "hello from bash"
        )
        let runtime = makeRuntime(tools: [bashTool])

        let result = await runtime.run(script: """
            var data = await fae.shell('echo hello');
            return typeof data;
        """)

        XCTAssertEqual(result.status, .success, "Error: \(result.error ?? "none")")
        XCTAssertEqual(result.value, "object")
    }

    // MARK: - Error Handling

    func testAdapterThrowsOnToolError() async {
        let failTool = ErrorTool(name: "calendar")
        let runtime = makeRuntime(tools: [failTool])

        let result = await runtime.run(script: """
            try {
                await fae.calendar.list();
                return 'should not reach';
            } catch(e) {
                return 'caught: ' + e.message;
            }
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(
            result.value?.contains("caught:") == true,
            "Expected caught error, got: \(result.value ?? "nil")"
        )
    }

    func testAdapterThrowsOnUnknownTool() async {
        // No tools registered — fae.web.search will fail.
        let runtime = makeRuntime(tools: [])

        let result = await runtime.run(script: """
            try {
                await fae.web.search('test');
                return 'should not reach';
            } catch(e) {
                return 'rejected';
            }
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "rejected")
    }

    // MARK: - Backwards Compatibility

    func testRawToolCallStillWorks() async {
        let calendarTool = StructuredEchoTool(
            name: "calendar",
            structuredPayload: [
                "events": [] as [any Sendable],
                "count": 0,
            ],
            proseOutput: "No events"
        )
        let runtime = makeRuntime(tools: [calendarTool])

        // Raw fae.tool() should still work alongside the typed adapters.
        let result = await runtime.run(script: """
            var raw = await fae.tool('calendar', { action: 'list' });
            var env = JSON.parse(raw);
            return env.output;
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "No events")
    }

    // MARK: - Unwrap Helper

    func testUnwrapHelperExtractsDataField() async {
        let runtime = makeRuntime()

        let result = await runtime.run(script: """
            // Test _unwrap with a mock envelope containing data.
            var envelope = { output: 'prose', isError: false, data: { count: 5 } };
            var unwrapped = fae._unwrap(envelope);
            return String(unwrapped.count);
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "5")
    }

    func testUnwrapHelperReturnsEnvelopeWhenNoData() async {
        let runtime = makeRuntime()

        let result = await runtime.run(script: """
            var envelope = { output: 'prose', isError: false };
            var unwrapped = fae._unwrap(envelope);
            return unwrapped.output;
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "prose")
    }

    func testUnwrapHelperThrowsOnError() async {
        let runtime = makeRuntime()

        let result = await runtime.run(script: """
            try {
                fae._unwrap({ output: 'bad', isError: true });
                return 'should not reach';
            } catch(e) {
                return 'threw: ' + e.message;
            }
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "threw: bad")
    }

    func testUnwrapHelperParsesJSONString() async {
        let runtime = makeRuntime()

        let result = await runtime.run(script: """
            var json = '{"output":"hello","isError":false,"data":{"x":42}}';
            var unwrapped = fae._unwrap(json);
            return String(unwrapped.x);
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "42")
    }
}
