import Foundation

/// Resource bundle resolver that works in SwiftPM tests/dev and packaged macOS apps.
private class _FaeBundleFinder {}

extension Bundle {
    static let faeResources: Bundle = {
        let nestedBundleName = "Fae_Fae.bundle"
        let candidates: [Bundle] = [
            .module,
            .main,
            Bundle(for: _FaeBundleFinder.self),
        ]

        for bundle in candidates {
            if bundle.url(forResource: "Skills", withExtension: nil) != nil {
                return bundle
            }

            let roots = [bundle.resourceURL, bundle.bundleURL]
            for root in roots.compactMap({ $0 }) {
                let nestedURL = root.appendingPathComponent(nestedBundleName)
                if let nestedBundle = Bundle(url: nestedURL),
                   nestedBundle.url(forResource: "Skills", withExtension: nil) != nil
                {
                    return nestedBundle
                }
            }
        }

        NSLog("Fae: WARNING — could not resolve resource bundle containing 'Skills'; falling back to main bundle")
        return Bundle.main
    }()
}
