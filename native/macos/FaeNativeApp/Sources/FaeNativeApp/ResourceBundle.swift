import Foundation

/// Custom resource bundle resolver that works both in SPM development builds
/// and when the executable is packaged inside a macOS `.app` bundle.
///
/// SPM's auto-generated `Bundle.module` only checks `Bundle.main.bundleURL`
/// (the `.app` root) and the build-time absolute path. It does NOT check
/// `Bundle.main.resourceURL` (`Contents/Resources/`), which is the standard
/// location for resources inside a macOS `.app` bundle.
///
/// This extension provides `Bundle.faeResources` as a drop-in replacement.
private class _FaeBundleFinder {}

extension Bundle {
    static let faeResources: Bundle = {
        let bundleName = "FaeNativeApp_FaeNativeApp"

        let candidates: [URL?] = [
            // 1. Standard .app bundle location: Contents/Resources/
            Bundle.main.resourceURL,
            // 2. SPM executable development: next to the binary
            Bundle.main.bundleURL,
            // 3. Framework / library context
            Bundle(for: _FaeBundleFinder.self).resourceURL,
        ]

        for candidate in candidates {
            guard let url = candidate?.appendingPathComponent("\(bundleName).bundle") else {
                continue
            }
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        // Graceful fallback — return main bundle so url(forResource:) still
        // has a chance to find loose resources in Contents/Resources/.
        NSLog("FaeNativeApp: WARNING — could not find resource bundle '%@', falling back to main bundle", bundleName)
        return Bundle.main
    }()
}
