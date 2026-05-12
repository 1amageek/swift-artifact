import Testing
import ArtifactCore
import ArtifactRenderer
import ArtifactWebRenderer

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

    @Test func payloadWithoutValidHeaderIsPreRenderable() {
        let result = MermaidWebViewRenderer.refine(
            artifact(payload: "flow", isComplete: false)
        )
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable before a valid header")
        }
    }

    @Test func dropsTrailingIncompleteLine() {
        let payload = """
        flowchart LR
            A --> B
            B --> C
            C --> "
        """
        let result = MermaidWebViewRenderer.refine(artifact(payload: payload, isComplete: false))
        guard case let .renderable(prefix) = result else {
            Issue.record("Expected .renderable once at least one line follows the header")
            return
        }
        // The trailing dangling-quote line must have been dropped.
        #expect(prefix.contains("C --> \"") == false)
        #expect(prefix.hasPrefix("flowchart LR"))
    }

    @Test func completePayloadIsReturnedRaw() {
        let payload = """
        flowchart LR
            A --> B
        """
        let result = MermaidWebViewRenderer.refine(
            artifact(payload: payload, isComplete: true)
        )
        #expect(result == .renderable(payload))
    }
}
