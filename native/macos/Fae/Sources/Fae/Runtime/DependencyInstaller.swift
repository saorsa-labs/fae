import AppKit
import Foundation

/// Manages automatic installation of required system dependencies.
///
/// When Fae needs a tool that isn't installed (like uv for Python),
/// this installer handles the approval flow and installation process.
///
/// Fae takes care of her users - no command line typing required.
public actor DependencyInstaller {
    
    public static let shared = DependencyInstaller()
    
    // MARK: - Types
    
    public enum Dependency: String, CaseIterable, Sendable {
        case uv = "uv"
        
        var displayName: String {
            switch self {
            case .uv: return "uv (Python package manager)"
            }
        }
        
        var description: String {
            switch self {
            case .uv: 
                return "uv is needed for voice synthesis and Python-based skills. It's a fast, safe package manager from Astral."
            }
        }
        
        var installCommand: String {
            switch self {
            case .uv:
                return "curl -LsSf https://astral.sh/uv/install.sh | sh"
            }
        }
        
        var verifyCommand: String {
            switch self {
            case .uv:
                return "~/.local/bin/uv --version"
            }
        }
        
        var installURL: URL? {
            switch self {
            case .uv:
                return URL(string: "https://docs.astral.sh/uv/")
            }
        }
    }
    
    public enum InstallResult: Sendable {
        case success
        case userDeclined
        case failed(String)
    }
    
    // MARK: - State
    
    /// Track which dependencies we've already asked about this session
    /// to avoid repeatedly prompting.
    private var declinedThisSession: Set<Dependency> = []
    private var installingNow: Set<Dependency> = []
    
    // MARK: - Public API
    
    /// Check if a dependency is installed.
    public func isInstalled(_ dependency: Dependency) async -> Bool {
        switch dependency {
        case .uv:
            return await UVRuntime.shared.isAvailable()
        }
    }
    
    /// Ensure a dependency is installed, prompting the user if needed.
    ///
    /// Returns `.success` if the dependency is available (was already installed
    /// or was just installed). Returns `.userDeclined` if the user chose not to
    /// install. Returns `.failed` if installation was attempted but failed.
    ///
    /// This method is safe to call multiple times - it won't re-prompt if the
    /// user already declined this session.
    public func ensureInstalled(_ dependency: Dependency) async -> InstallResult {
        // Already installed?
        if await isInstalled(dependency) {
            return .success
        }
        
        // User already declined this session?
        if declinedThisSession.contains(dependency) {
            return .userDeclined
        }
        
        // Already installing?
        if installingNow.contains(dependency) {
            // Wait for the other installation to complete
            while installingNow.contains(dependency) {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            return await isInstalled(dependency) ? .success : .failed("Installation in progress failed")
        }
        
        // Ask user for permission
        let approved = await requestApproval(for: dependency)
        
        if !approved {
            declinedThisSession.insert(dependency)
            return .userDeclined
        }
        
        // Install
        installingNow.insert(dependency)
        defer { installingNow.remove(dependency) }
        
        do {
            try await install(dependency)
            
            // Verify installation
            if await isInstalled(dependency) {
                NSLog("DependencyInstaller: Successfully installed %@", dependency.rawValue)
                return .success
            } else {
                return .failed("Installation completed but verification failed")
            }
        } catch {
            NSLog("DependencyInstaller: Failed to install %@: %@", dependency.rawValue, error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }
    
    /// Reset the declined state (e.g., when user goes to settings).
    public func resetDeclined() {
        declinedThisSession.removeAll()
    }
    
    // MARK: - Private
    
    @MainActor
    private func requestApproval(for dependency: Dependency) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install \(dependency.displayName)?"
        alert.informativeText = """
        \(dependency.description)
        
        Fae will download and install it automatically. This is a one-time setup.
        """
        alert.alertStyle = .informational
        
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        
        if dependency.installURL != nil {
            alert.addButton(withTitle: "Learn More")
        }
        
        // Add Fae's icon if available
        if let icon = NSImage(named: "AppIcon") {
            alert.icon = icon
        }
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn:
            return true
        case .alertThirdButtonReturn:
            // Learn More - open URL and re-prompt
            if let url = dependency.installURL {
                NSWorkspace.shared.open(url)
            }
            return await requestApproval(for: dependency)
        default:
            return false
        }
    }
    
    private func install(_ dependency: Dependency) async throws {
        NSLog("DependencyInstaller: Installing %@...", dependency.rawValue)
        
        switch dependency {
        case .uv:
            try await installUV()
        }
    }
    
    private func installUV() async throws {
        // Use the official uv installer
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"]
        
        // Capture output for debugging
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        // Set HOME so uv installs to the right place
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = env
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
            throw InstallError.failed(stderrStr)
        }
        
        // Clear UVRuntime cache so it finds the new installation
        await UVRuntime.shared.clearCache()
        
        NSLog("DependencyInstaller: uv installation completed")
    }
    
    enum InstallError: LocalizedError {
        case failed(String)
        
        var errorDescription: String? {
            switch self {
            case .failed(let msg):
                return "Installation failed: \(msg)"
            }
        }
    }
}
