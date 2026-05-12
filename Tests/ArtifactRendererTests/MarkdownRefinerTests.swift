import Testing
import ArtifactCore
import ArtifactRenderer
import ArtifactNativeRenderer

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
}
