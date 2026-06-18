import XCTest
@testable import Fae

final class DependencyInstallerStaticTests: XCTestCase {
    func testUVDependencyMetadataIsStable() throws {
        let dependency = DependencyInstaller.Dependency.uv

        XCTAssertEqual(dependency.rawValue, "uv")
        XCTAssertEqual(dependency.displayName, "uv (Python package manager)")
        XCTAssertTrue(dependency.description.contains("voice synthesis"))
        XCTAssertTrue(dependency.description.contains("Python-based skills"))
        XCTAssertEqual(dependency.installCommand, "curl -LsSf https://astral.sh/uv/install.sh | sh")
        XCTAssertEqual(dependency.verifyCommand, "~/.local/bin/uv --version")
        XCTAssertEqual(try XCTUnwrap(dependency.installURL).absoluteString, "https://docs.astral.sh/uv/")
    }

    func testDependencyCatalogContainsOnlyUVForNow() {
        XCTAssertEqual(DependencyInstaller.Dependency.allCases, [.uv])
    }

    func testInstallResultFailedCarriesMessage() {
        let result = DependencyInstaller.InstallResult.failed("network unavailable")

        switch result {
        case .failed(let message):
            XCTAssertEqual(message, "network unavailable")
        default:
            XCTFail("expected failed result")
        }
    }

    func testInstallErrorDescriptionPrefixesFailureMessage() {
        let error = DependencyInstaller.InstallError.failed("curl exited 7")

        XCTAssertEqual(error.errorDescription, "Installation failed: curl exited 7")
    }
}
