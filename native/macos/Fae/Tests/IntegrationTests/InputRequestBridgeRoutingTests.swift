import XCTest
@testable import Fae

/// UX W1: InputRequestBridge must PREFER the pill (`request_input` in the
/// conversation surface) when the orb host is connected and acks, and fall back
/// to the SwiftUI overlay card otherwise (host absent / disconnected / no ack).
/// These tests pin that routing decision — the safety-critical part of W1's
/// bridge wiring — without a running orb host.
final class InputRequestBridgeRoutingTests: XCTestCase {

    /// Records pill requests and lets a test drive the ack/response.
    @MainActor
    private final class MockPillRouter: PillInputRouting {
        var isOrbHostConnected: Bool
        private(set) var didRequest = false
        private(set) var lastRequestId: String?
        private(set) var didCancel = false
        var onRequest: ((String) -> Void)?

        init(connected: Bool) { isOrbHostConnected = connected }

        func requestPillInput(
            requestId: String,
            prompt: String,
            secure: Bool,
            multiline: Bool,
            placeholder: String
        ) {
            didRequest = true
            lastRequestId = requestId
            onRequest?(requestId)
        }

        func cancelPillInput() {
            didCancel = true
        }
    }

    override func tearDown() {
        let expectation = expectation(description: "clear router")
        Task { @MainActor in
            PillInputRouter.shared = nil
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        super.tearDown()
    }

    func test_request_prefersPill_whenConnectedAndAcked() async {
        // The overlay must NOT be used when the pill acks.
        let overlayUsed = expectation(forNotification: .faeInputRequired, object: nil)
        overlayUsed.isInverted = true

        let mock = await MainActor.run { MockPillRouter(connected: true) }
        await MainActor.run {
            PillInputRouter.shared = mock
            // When the pill receives the request: ack (commit to the pill path),
            // then answer — exactly what the orb host does over stdout.
            mock.onRequest = { requestId in
                NotificationCenter.default.post(
                    name: .faePillInputAck,
                    object: nil,
                    userInfo: ["request_id": requestId]
                )
                NotificationCenter.default.post(
                    name: .faeInputResponse,
                    object: nil,
                    userInfo: ["request_id": requestId, "text": "blue"]
                )
            }
        }

        let result = await InputRequestBridge.shared.request(prompt: "favourite colour?")

        await fulfillment(of: [overlayUsed], timeout: 0.4)
        XCTAssertEqual(result, "blue")
        let didRequest = await MainActor.run { mock.didRequest }
        XCTAssertTrue(didRequest, "connected host must receive the pill request")
    }

    func test_request_fallsBackToOverlay_whenNoRouter() async {
        await MainActor.run { PillInputRouter.shared = nil }

        // No orb host → the overlay must be asked; answer it so the call returns.
        let observer = await MainActor.run {
            NotificationCenter.default.addObserver(
                forName: .faeInputRequired,
                object: nil,
                queue: .main
            ) { note in
                let requestId = note.userInfo?["request_id"] as? String ?? ""
                NotificationCenter.default.post(
                    name: .faeInputResponse,
                    object: nil,
                    userInfo: ["request_id": requestId, "text": "overlay-answer"]
                )
            }
        }

        let result = await InputRequestBridge.shared.request(prompt: "city?")
        await MainActor.run { NotificationCenter.default.removeObserver(observer) }
        XCTAssertEqual(result, "overlay-answer")
    }

    func test_request_fallsBackToOverlay_whenHostDisconnected() async {
        let mock = await MainActor.run { MockPillRouter(connected: false) }
        let observer = await MainActor.run { () -> NSObjectProtocol in
            PillInputRouter.shared = mock
            return NotificationCenter.default.addObserver(
                forName: .faeInputRequired,
                object: nil,
                queue: .main
            ) { note in
                let requestId = note.userInfo?["request_id"] as? String ?? ""
                NotificationCenter.default.post(
                    name: .faeInputResponse,
                    object: nil,
                    userInfo: ["request_id": requestId, "text": "overlay"]
                )
            }
        }

        let result = await InputRequestBridge.shared.request(prompt: "city?")
        let didRequest = await MainActor.run { () -> Bool in
            NotificationCenter.default.removeObserver(observer)
            return mock.didRequest
        }
        XCTAssertEqual(result, "overlay")
        XCTAssertFalse(didRequest, "a disconnected host must not receive the pill request")
    }

    /// UX auto-cancel: when a new turn supersedes an abandoned pill prompt,
    /// `cancelPending()` must resolve the outstanding request as cancelled (nil)
    /// AND tell the pill to leave request-input mode — otherwise the expanded
    /// pill keeps capturing left-clicks over the orb and wedges the UI.
    func test_cancelPending_cancelsOutstandingPillRequest_andDismissesPill() async {
        let mock = await MainActor.run { MockPillRouter(connected: true) }
        await MainActor.run {
            PillInputRouter.shared = mock
            // The pill acks (commits to the pill path) but the user never answers.
            mock.onRequest = { requestId in
                NotificationCenter.default.post(
                    name: .faePillInputAck,
                    object: nil,
                    userInfo: ["request_id": requestId]
                )
            }
        }

        // Start the request; it suspends waiting for an answer that never comes.
        async let pending = InputRequestBridge.shared.request(prompt: "api key?")

        // Wait until the pill has actually received the request, so it is
        // genuinely outstanding when we cancel.
        var delivered = false
        for _ in 0..<100 {
            if await MainActor.run(body: { mock.didRequest }) { delivered = true; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(delivered, "the pill must receive the request before cancel")

        // A new turn supersedes it → auto-cancel.
        let cancelled = await InputRequestBridge.shared.cancelPending()
        XCTAssertTrue(cancelled, "cancelPending reports it cancelled a pending request")

        let result = await pending
        XCTAssertNil(result, "an auto-cancelled request resolves as nil")

        // The cancel dispatches the pill dismissal on the main actor; let it run.
        var toldPill = false
        for _ in 0..<100 {
            if await MainActor.run(body: { mock.didCancel }) { toldPill = true; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(toldPill, "the pill must be told to leave request-input mode")

        // Idempotent: a second cancel with nothing pending is a no-op.
        let again = await InputRequestBridge.shared.cancelPending()
        XCTAssertFalse(again, "cancelPending is a no-op when nothing is pending")
    }
}
