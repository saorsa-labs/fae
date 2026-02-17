import Foundation
import FaeHandoffKit

@MainActor
final class HandoffSessionModel: ObservableObject {
    @Published private(set) var targetText: String = "No handoff yet"
    @Published private(set) var commandText: String = ""
    @Published private(set) var receivedAt: Date?

    func handle(userInfo: [AnyHashable: Any]?) {
        do {
            let payload = try FaeHandoffContract.payload(from: userInfo)
            targetText = payload.target.rawValue
            commandText = payload.command
            receivedAt = Date(timeIntervalSince1970: TimeInterval(payload.issuedAtEpochMs) / 1000.0)
        } catch {
            targetText = "Invalid handoff payload"
            commandText = String(describing: error)
            receivedAt = Date()
        }
    }
}
