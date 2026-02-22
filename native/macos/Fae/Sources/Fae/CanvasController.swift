import Foundation

/// Observable store for canvas content displayed in the native canvas window.
///
/// `PipelineAuxBridgeController` pushes content and visibility updates here.
/// `CanvasWindowView` observes the published properties to render content.
@MainActor
final class CanvasController: ObservableObject {
    /// The current HTML content to display in the canvas window.
    @Published var htmlContent: String = ""

    /// Whether the canvas window should be visible.
    @Published var isVisible: Bool = false

    /// Replace the canvas content entirely.
    func setContent(_ html: String) {
        htmlContent = html
    }

    /// Append HTML to the existing canvas content.
    func appendContent(_ html: String) {
        htmlContent += html
    }

    /// Clear all canvas content and hide.
    func clear() {
        htmlContent = ""
        isVisible = false
    }
}
