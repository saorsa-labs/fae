import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("FaeOrbKit_FaeOrbKit.bundle").path
        let buildPath = "/Users/davidirvine/Desktop/Devel/projects/fae/native/apple/FaeOrbKit/.build/arm64-apple-macosx/debug/FaeOrbKit_FaeOrbKit.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}