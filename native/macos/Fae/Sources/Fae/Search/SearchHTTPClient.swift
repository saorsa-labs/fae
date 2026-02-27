import Foundation

/// HTTP utilities for search engines — User-Agent rotation and request building.
enum SearchHTTPClient {
    /// Realistic browser User-Agent strings for rotation.
    static let userAgents = [
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:121.0) Gecko/20100101 Firefox/121.0",
    ]

    /// Pick a random User-Agent or use a custom one.
    static func userAgent(custom: String? = nil) -> String {
        if let custom { return custom }
        return userAgents.randomElement() ?? userAgents[0]
    }

    /// Build a URLSession configuration with appropriate timeout and headers.
    static func sessionConfiguration(config: SearchConfig) -> URLSessionConfiguration {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = config.timeoutSeconds
        sessionConfig.timeoutIntervalForResource = config.timeoutSeconds + 5
        sessionConfig.httpCookieAcceptPolicy = .always
        sessionConfig.httpShouldSetCookies = true
        return sessionConfig
    }

    /// Create a GET request with appropriate headers.
    static func getRequest(url: URL, config: SearchConfig) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent(custom: config.userAgent), forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    /// Create a POST request with form-encoded body.
    static func postRequest(url: URL, body: String, config: SearchConfig) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(userAgent(custom: config.userAgent), forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.httpBody = body.data(using: .utf8)
        return request
    }
}
