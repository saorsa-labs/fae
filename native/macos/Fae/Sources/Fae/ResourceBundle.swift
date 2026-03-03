import Foundation

/// Resource bundle resolver that works in SwiftPM tests/dev and packaged macOS apps.
private class _FaeBundleFinder {}

extension Bundle {
    static let faeResources: Bundle = {
        let nestedBundleName = "Fae_Fae.bundle"
        // Check for Skills directory or default.metallib — either confirms the Fae resource bundle.
        let markers = [("Skills", nil as String?), ("default", "metallib"), ("SOUL", "md")]
        let candidates: [Bundle] = [
            .module,
            .main,
            Bundle(for: _FaeBundleFinder.self),
        ]

        for bundle in candidates {
            if hasAnyMarker(bundle, markers) {
                return bundle
            }

            let roots = [bundle.resourceURL, bundle.bundleURL]
            for root in roots.compactMap({ $0 }) {
                let nestedURL = root.appendingPathComponent(nestedBundleName)
                if let nestedBundle = Bundle(url: nestedURL),
                   hasAnyMarker(nestedBundle, markers)
                {
                    return nestedBundle
                }
            }
        }

        NSLog("Fae: WARNING — could not resolve resource bundle containing 'Skills'; falling back to main bundle")
        return Bundle.main
    }()

    private static func hasAnyMarker(
        _ bundle: Bundle,
        _ markers: [(String, String?)]
    ) -> Bool {
        for (name, ext) in markers {
            if bundle.url(forResource: name, withExtension: ext) != nil {
                return true
            }
        }
        return false
    }
}
