import Testing
import ArtifactCore
import ArtifactRenderer
import ArtifactNativeRenderer

@Suite("MermaidRenderer.refine")
struct MermaidRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("md"),
            type: .mermaid,
            payload: payload,
            isComplete: isComplete
        )
    }

    @Test func incompletePayloadIsPreRenderable() {
        let result = MermaidRenderer.refine(
            artifact(payload: "flowchart LR\n    A --> B", isComplete: false)
        )
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable while streaming")
        }
    }

    @Test func incompleteEmptyPayloadIsPreRenderable() {
        let result = MermaidRenderer.refine(
            artifact(payload: "", isComplete: false)
        )
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable for empty incomplete payload")
        }
    }

    @Test func completePayloadIsReturnedRaw() {
        let payload = """
        flowchart LR
            A --> B
        """
        let result = MermaidRenderer.refine(
            artifact(payload: payload, isComplete: true)
        )
        #expect(result == .renderable(payload))
    }

    @Test func completeEmptyPayloadIsReturnedRaw() {
        // refine is intentionally simple: even an empty `isComplete` artifact
        // flows through. The view layer surfaces the "empty diagram" state.
        let result = MermaidRenderer.refine(
            artifact(payload: "", isComplete: true)
        )
        #expect(result == .renderable(""))
    }
}
