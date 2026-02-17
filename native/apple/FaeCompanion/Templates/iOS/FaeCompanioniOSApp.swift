import SwiftUI
import FaeHandoffKit

@main
struct FaeCompanioniOSApp: App {
    @StateObject private var handoff = HandoffSessionModel()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("Fae Companion iPhone")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Target: \(handoff.targetText)")
                Text("Command: \(handoff.commandText)")
                    .foregroundStyle(.secondary)
                if let receivedAt = handoff.receivedAt {
                    Text("Received: \(receivedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .onContinueUserActivity(FaeHandoffContract.activityType) { activity in
                handoff.handle(userInfo: activity.userInfo)
            }
        }
    }
}
