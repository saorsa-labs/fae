import Foundation

/// Network target guardrails for local tool execution.
///
/// Blocks local/private/metadata targets by default to reduce SSRF-like abuse
/// and accidental access to sensitive host-local services.
enum NetworkTargetPolicy {

    /// Blocked hostnames regardless of DNS resolution.
    private static let blockedHostnames: Set<String> = [
        "localhost",
        "metadata.google.internal",
        "169.254.169.254",
    ]

    /// Evaluate whether a URL is blocked for outbound access.
    ///
    /// - Returns: Reason string when blocked, otherwise `nil`.
    static func blockedReason(urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let hostRaw = url.host?.lowercased(),
              !hostRaw.isEmpty
        else {
            return "Invalid URL"
        }

        // Block direct known-sensitive hosts.
        if blockedHostnames.contains(hostRaw) {
            return "Access to \(hostRaw) is blocked for security"
        }

        // Block mDNS-style local domains.
        if hostRaw.hasSuffix(".local") {
            return "Access to local network host \(hostRaw) is blocked"
        }

        // Block literal loopback/private/link-local IPs.
        if isBlockedIPAddress(hostRaw) {
            return "Access to local/private IP target \(hostRaw) is blocked"
        }

        return nil
    }

    private static func isBlockedIPAddress(_ host: String) -> Bool {
        if host.contains(":") {
            // IPv6 (literal)
            let h = host.lowercased()
            if h == "::1" { return true }                     // loopback
            if h.hasPrefix("fe80:") { return true }           // link-local
            if h.hasPrefix("fc") || h.hasPrefix("fd") { return true } // unique-local
            return false
        }

        // IPv4
        let parts = host.split(separator: ".")
        guard parts.count == 4,
              let a = Int(parts[0]), let b = Int(parts[1]),
              let c = Int(parts[2]), let d = Int(parts[3]),
              [a, b, c, d].allSatisfy({ 0...255 ~= $0 })
        else {
            return false
        }

        // 127.0.0.0/8 loopback
        if a == 127 { return true }

        // 10.0.0.0/8 private
        if a == 10 { return true }

        // 172.16.0.0/12 private
        if a == 172 && (16...31).contains(b) { return true }

        // 192.168.0.0/16 private
        if a == 192 && b == 168 { return true }

        // 169.254.0.0/16 link-local
        if a == 169 && b == 254 { return true }

        // 0.0.0.0/8 and broadcast-ish edge ranges are not useful targets.
        if a == 0 { return true }

        return false
    }
}
