import Testing
import ArtifactCore
import ArtifactRenderer
@testable import ArtifactNativeRenderer

@Suite("MarkdownRenderer.refine")
struct MarkdownRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("m"),
            type: .markdown,
            payload: payload,
            isComplete: isComplete
        )
    }

    @Test func completePayloadIsReturnedVerbatim() {
        let result = MarkdownRenderer.refine(artifact(payload: "# Hello", isComplete: true))
        #expect(result == .renderable("# Hello"))
    }

    @Test func streamingWithoutNewlineIsPreRenderable() {
        let result = MarkdownRenderer.refine(artifact(payload: "# Hello", isComplete: false))
        guard case let .preRenderable(progress) = result else {
            Issue.record("Expected .preRenderable")
            return
        }
        #expect(progress.receivedCharacters == 7)
    }

    @Test func streamingTrimsAtLastNewline() {
        let result = MarkdownRenderer.refine(
            artifact(payload: "# Title\n\nFirst paragraph.\n## Subtitl", isComplete: false)
        )
        #expect(result == .renderable("# Title\n\nFirst paragraph."))
    }

    @Test func streamingWithOnlyTrailingNewlineIsPreRenderable() {
        let result = MarkdownRenderer.refine(artifact(payload: "\n", isComplete: false))
        if case .preRenderable = result {
            // OK — nothing before the first newline.
        } else {
            Issue.record("Expected .preRenderable when only the newline has arrived")
        }
    }

    @Test func imageParagraphIsRenderedAsImageBlock() throws {
        let blocks = MarkdownImageBlockParser.parse(
            "# Apple\n\n![Hero](https://example.com/hero.png)\n\nSummary"
        )

        #expect(blocks.count == 3)
        guard case let .image(url, alt) = blocks[1] else {
            Issue.record("Expected a parsed image block")
            return
        }
        #expect(url.absoluteString == "https://example.com/hero.png")
        #expect(alt == "Hero")
    }

    @Test func markdownWithoutImagesRemainsARegularBlock() {
        let source = "# Heading\n\nA paragraph."
        #expect(MarkdownImageBlockParser.parse(source) == [.markdown(source: source)])
    }
}
