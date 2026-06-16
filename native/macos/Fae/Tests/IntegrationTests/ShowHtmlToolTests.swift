import XCTest
@testable import Fae

/// Verifies the show_html tool's pure, side-effect-bounded pieces: the render
/// file is written under the cache with the exact HTML, and the open command is
/// constructed for the host platform. We deliberately never call
/// `openInBrowser`/`execute` so no browser launches during tests.
final class ShowHtmlToolTests: XCTestCase {

    // MARK: - slug

    func testSlugIsFilesystemSafe() {
        XCTAssertEqual(ShowHtmlTool.slug("Weekly Report!"), "weekly-report")
        XCTAssertEqual(ShowHtmlTool.slug("  spaced  out  "), "spaced-out")
        XCTAssertEqual(ShowHtmlTool.slug("***"), "render")
        XCTAssertEqual(ShowHtmlTool.slug(nil), "render")
        XCTAssertEqual(ShowHtmlTool.slug(""), "render")
        // No path separators or shell-significant characters survive.
        let slug = ShowHtmlTool.slug("a/b\\c:d e.f")
        XCTAssertFalse(slug.contains("/"))
        XCTAssertFalse(slug.contains("\\"))
        XCTAssertFalse(slug.contains(":"))
    }

    // MARK: - openCommand (constructed, never run)

    func testOpenCommandUsesPlatformOpener() {
        let url = URL(fileURLWithPath: "/tmp/example render.html")
        let command = ShowHtmlTool.openCommand(for: url)
        #if os(macOS)
        XCTAssertEqual(command.launchPath, "/usr/bin/open")
        XCTAssertEqual(command.arguments, ["/tmp/example render.html"])
        #else
        // Linux / other: portable opener via env xdg-open.
        XCTAssertEqual(command.launchPath, "/usr/bin/env")
        XCTAssertEqual(command.arguments, ["xdg-open", "/tmp/example render.html"])
        #endif
        // The launch path is an absolute executable, the argument is the file path.
        XCTAssertTrue(command.launchPath.hasPrefix("/"))
        XCTAssertTrue(command.arguments.contains(url.path))
    }

    // MARK: - writeRenderFile (writes, does not open)

    func testWriteRenderFileWritesExactHtmlUnderRenderCache() throws {
        let html = "<!doctype html><html><body><h1>Hi &amp; bye</h1></body></html>"
        let url = try ShowHtmlTool.writeRenderFile(html: html, title: "Sales Q3")
        defer { try? FileManager.default.removeItem(at: url) }

        // Lives under <cache>/render/ and is an .html file named from the slug.
        let renderDir = FaeDirectories.cache.appendingPathComponent("render", isDirectory: true)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, renderDir.standardizedFileURL)
        XCTAssertEqual(url.pathExtension, "html")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("sales-q3-"))

        // The file exists and contains exactly the HTML we passed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, html)
    }

    func testWriteRenderFileTitlesAreUnique() throws {
        let a = try ShowHtmlTool.writeRenderFile(html: "<p>a</p>", title: "dup")
        let b = try ShowHtmlTool.writeRenderFile(html: "<p>b</p>", title: "dup")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        XCTAssertNotEqual(a.lastPathComponent, b.lastPathComponent)
    }
}
