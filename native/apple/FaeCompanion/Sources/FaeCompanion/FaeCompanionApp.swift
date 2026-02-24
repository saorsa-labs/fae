import SwiftUI
import FaeHandoffKit
import FaeOrbKit
import FaeRelayKit

@main
struct FaeCompanionApp: App {
    @StateObject private var relay = FaeRelayClient()
    @StateObject private var orbAnimation = OrbAnimationState()
    @StateObject private var conversationStore = ConversationStore()

    var body: some Scene {
        WindowGroup {
            CompanionContentView(
                relay: relay,
                orbAnimation: orbAnimation,
                conversationStore: conversationStore
            )
            .onAppear {
                setupRelayBindings()
                relay.startSearching()
            }
            .onContinueUserActivity(FaeHandoffContract.activityType) { activity in
                handleHandoff(activity)
            }
        }
    }

    // MARK: - Relay → Orb Bindings

    private func setupRelayBindings() {
        // When relay receives orb state updates, drive the animation.
        relay.$orbMode
            .combineLatest(relay.$orbPalette, relay.$orbFeeling)
            .receive(on: DispatchQueue.main)
            .sink { [weak orbAnimation] mode, palette, feeling in
                orbAnimation?.setTarget(mode: mode, palette: palette, feeling: feeling)
            }
            .store(in: &conversationStore.cancellables)

        // Forward conversation turns to the store.
        relay.onConversationTurn = { [weak conversationStore] role, content, isFinal in
            conversationStore?.addTurn(role: role, content: content, isFinal: isFinal)
        }
    }

    // MARK: - Handoff

    private func handleHandoff(_ activity: NSUserActivity) {
        guard let userInfo = activity.userInfo else { return }

        // Parse handoff payload.
        if let payload = try? FaeHandoffContract.payload(from: userInfo) {
            // Restore conversation from snapshot if present.
            if let snapshotData = userInfo["conversationSnapshot"] as? Data,
               let snapshot = try? JSONDecoder().decode(ConversationSnapshot.self, from: snapshotData) {
                conversationStore.restore(from: snapshot)

                // Set initial orb state from snapshot.
                if let mode = OrbMode(rawValue: snapshot.orbMode),
                   let feeling = OrbFeeling(rawValue: snapshot.orbFeeling) {
                    orbAnimation.setTarget(mode: mode, palette: .modeDefault, feeling: feeling)
                }
            }
        }
    }
}
