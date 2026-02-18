import AppKit
import SwiftUI

@MainActor
final class OrbStateController: ObservableObject {
    @Published var mode: OrbMode = .idle
    @Published var palette: OrbPalette = .modeDefault
    @Published var feeling: OrbFeeling = .neutral
}

@main
struct FaeNativeApp: App {
    @StateObject private var handoff = DeviceHandoffController()
    @StateObject private var orbState = OrbStateController()

    init() {
        if let iconURL = Bundle.module.url(
            forResource: "AppIconFace",
            withExtension: "jpg",
            subdirectory: "App"
        ), let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup("Fae") {
            ContentView()
                .environmentObject(handoff)
                .environmentObject(orbState)
                .preferredColorScheme(.dark)
                .frame(minWidth: 400, minHeight: 500)
        }
        .defaultSize(width: 600, height: 700)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(orbState)
                .environmentObject(handoff)
        }
    }
}
