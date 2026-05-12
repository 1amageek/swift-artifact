import Testing
import ArtifactCore
import ArtifactRenderer
@testable import ArtifactWebRenderer

@Suite("LatexRefiner")
struct LatexRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("t"),
            type: .latex,
            payload: payload,
            isComplete: isComplete
        )
    }

    @Test func danglingBackslashCommandIsDropped() {
        let trimmed = LatexRefiner.trimTrailingIncomplete(#"a + b = c \fra"#)
        #expect(trimmed == #"a + b = c "#)
    }

    @Test func unbalancedBraceIsTrimmedBack() {
        let trimmed = LatexRefiner.trimTrailingIncomplete(#"\frac{1}{2"#)
        // The trailing `{2` (unclosed) is dropped, so the safe prefix ends at
        // the previous balance point.
        #expect(trimmed == #"\frac{1}"#)
    }

    @Test func balancedSourceIsUnchanged() {
        let trimmed = LatexRefiner.trimTrailingIncomplete(#"a^2 + b^2 = c^2"#)
        #expect(trimmed == #"a^2 + b^2 = c^2"#)
    }

    @Test func refinePassesCompletePayload() {
        let result = LaTeXWebViewRenderer.refine(
            artifact(payload: #"x^2"#, isComplete: true)
        )
        #expect(result == .renderable(#"x^2"#))
    }

    @Test func refinePreRenderableWhenTrimEmptiesSource() {
        let result = LaTeXWebViewRenderer.refine(
            artifact(payload: #"\fra"#, isComplete: false)
        )
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable when the only token is a dangling command")
        }
    }
}
