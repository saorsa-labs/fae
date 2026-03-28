import Foundation

/// Shared executable resolution for plugin subsystem (MCP servers, hook scripts).
///
/// Searches common binary paths, falls back to `which` for non-standard locations.
/// Used by both `MCPBridge` and `PluginHookRunner`.
enum PluginExecutableResolver {

    /// Common search paths for plugin executables.
    private static let searchPaths = [
        "/usr/bin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/opt/zerobrew/bin",
    ]

    /// Resolve an executable name to a full path.
    ///
    /// 1. Checks common binary directories.
    /// 2. Falls back to `/usr/bin/which` for non-standard locations.
    static func resolve(_ name: String) -> URL? {
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        // Fallback: `which` for executables in non-standard paths.
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = [name]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        } catch {
            NSLog("PluginExecutableResolver: 'which %@' failed: %@", name, error.localizedDescription)
        }

        return nil
    }

    /// Substitute plugin root variables in a string.
    ///
    /// Replaces `${CLAUDE_PLUGIN_ROOT}` and `${FAE_PLUGIN_ROOT}` with the actual path.
    static func substitutePluginRoot(_ value: String, pluginPath: String) -> String {
        value
            .replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: pluginPath)
            .replacingOccurrences(of: "${FAE_PLUGIN_ROOT}", with: pluginPath)
    }
}
