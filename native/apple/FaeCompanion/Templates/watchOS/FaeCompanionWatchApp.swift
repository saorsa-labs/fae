import SwiftUI
import FaeHandoffKit

@main
struct FaeCompanionWatchApp: App {
    @StateObject private var handoff = HandoffSessionModel()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("Fae Watch")
                    .font(.headline)
                Text(handoff.targetText)
                    .font(.caption)
                Text(handoff.commandText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
            .onContinueUserActivity(FaeHandoffContract.activityType) { activity in
                handoff.handle(userInfo: activity.userInfo)
            }
        }
    }
}
