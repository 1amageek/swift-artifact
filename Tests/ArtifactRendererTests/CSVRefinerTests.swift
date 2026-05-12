import Testing
import ArtifactCore
import ArtifactRenderer
import ArtifactNativeRenderer

@Suite("CSVRenderer.refine")
struct CSVRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("c"),
            type: .csv,
            payload: payload,
            isComplete: isComplete
        )
    }

    @Test func streamingWithoutNewlineIsPreRenderable() {
        let result = CSVRenderer.refine(artifact(payload: "Region,Q1,Q2", isComplete: false))
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable before the first newline")
        }
    }

    @Test func streamingTrimsAtLastNewline() {
        let result = CSVRenderer.refine(
            artifact(payload: "Region,Q1\nNorth,120\nSout", isComplete: false)
        )
        #expect(result == .renderable("Region,Q1\nNorth,120"))
    }

    @Test func completePayloadIsReturned() {
        let result = CSVRenderer.refine(
            artifact(payload: "Region,Q1\nNorth,120", isComplete: true)
        )
        #expect(result == .renderable("Region,Q1\nNorth,120"))
    }
}
