import Testing
import ArtifactCore
import ArtifactRenderer
import ArtifactNativeRenderer

@Suite("SVGRenderer.refine + PartialSVGScanner")
struct SVGRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("s"),
            type: .svg,
            payload: payload,
            isComplete: isComplete
        )
    }

    @Test func payloadWithoutSvgTagIsPreRenderable() {
        let result = SVGRenderer.refine(artifact(payload: "<svg", isComplete: false))
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable while <svg> open tag is still streaming")
        }
    }

    @Test func selfClosingChildIsIncluded() throws {
        let result = SVGRenderer.refine(artifact(
            payload: #"<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="3"/><rec"#,
            isComplete: false
        ))
        guard case let .renderable(prefix) = result else {
            Issue.record("Expected .renderable once a child element completed")
            return
        }
        #expect(prefix.contains("<circle"))
        #expect(prefix.hasSuffix("</svg>"))
        // The trailing `<rec` must have been dropped.
        #expect(prefix.contains("<rec") == false)
    }

    @Test func nestedContainerIsIncludedOnlyWhenFullyClosed() throws {
        let half = #"<svg><g><circle cx="1" cy="1" r="1"/>"#
        let result = SVGRenderer.refine(artifact(payload: half, isComplete: false))
        guard case let .renderable(prefix) = result else {
            Issue.record("Expected .renderable")
            return
        }
        // The unclosed <g> must not appear in the renderable output.
        #expect(prefix.contains("<g>") == false)
        #expect(prefix.hasSuffix("</svg>"))
    }

    @Test func completePayloadIsPassedThrough() {
        let payload = #"<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="3"/></svg>"#
        let result = SVGRenderer.refine(artifact(payload: payload, isComplete: true))
        #expect(result == .renderable(payload))
    }
}
