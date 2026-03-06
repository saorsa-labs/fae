import XCTest
@testable import Fae

final class FaeOpenAICompatTests: XCTestCase {
    func testChatRequestUsesMetadataForVisibleAndInjectedPrompts() throws {
        let body = """
        {
          "model": "fae-agent-local",
          "messages": [
            {"role": "user", "content": "plain prompt"}
          ],
          "metadata": {
            "user_visible_prompt": "visible prompt",
            "injected_prompt": "local contextual prompt"
          }
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(FaeOpenAICompatChatRequest.self, from: body)
        XCTAssertEqual(request.visiblePrompt, "visible prompt")
        XCTAssertEqual(request.injectedPrompt, "local contextual prompt")
        XCTAssertEqual(request.lastUserText, "plain prompt")
    }

    func testChatRequestFlattensMultipartContent() throws {
        let body = """
        {
          "model": "fae-agent-local",
          "messages": [
            {
              "role": "user",
              "content": [
                {"type": "text", "text": "Look at this repo"},
                {"type": "image_url", "image_url": {"url": "file:///tmp/screenshot.png"}}
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(FaeOpenAICompatChatRequest.self, from: body)
        XCTAssertEqual(request.lastUserText, "Look at this repo\n[image: file:///tmp/screenshot.png]")
        XCTAssertEqual(request.visiblePrompt, "Look at this repo\n[image: file:///tmp/screenshot.png]")
        XCTAssertEqual(request.injectedPrompt, "Look at this repo\n[image: file:///tmp/screenshot.png]")
    }
}
