import AppKit
import SwiftUI

@main
struct FaeNativeApp: App {
    @StateObject private var handoff = DeviceHandoffController()

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
                .preferredColorScheme(.dark)
                .frame(minWidth: 920, minHeight: 760)
        }
        .defaultSize(width: 980, height: 780)
        .windowResizability(.contentMinSize)
    }
}
