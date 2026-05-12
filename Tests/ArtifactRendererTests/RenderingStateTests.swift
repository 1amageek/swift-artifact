import Testing
import SwiftUI
import ArtifactCore
@testable import ArtifactRenderer

@Suite("RefinedPayload")
struct RenderingStateTests {

    struct DefaultRenderer: ArtifactRenderable {
        static let artifactType: ArtifactType = .markdown
        func body(artifact: AnyArtifact, payload: String) -> some View { EmptyView() }
    }

    @Test func defaultProtocolBehavior() {
        let empty = AnyArtifact(id: .init("a"), type: .markdown)
        if case let .preRenderable(progress) = DefaultRenderer.refine(empty) {
            #expect(progress.receivedCharacters == 0)
        } else {
            Issue.record("Expected .preRenderable for empty artifact")
        }

        let streaming = AnyArtifact(id: .init("a"), type: .markdown, payload: "hi", isComplete: false)
        if case let .preRenderable(progress) = DefaultRenderer.refine(streaming) {
            #expect(progress.receivedCharacters == 2)
        } else {
            Issue.record("Expected .preRenderable for streaming artifact (default refiner)")
        }

        let complete = AnyArtifact(id: .init("a"), type: .markdown, payload: "hi", isComplete: true)
        #expect(DefaultRenderer.refine(complete) == .renderable("hi"))
    }

    struct PartialAwareRenderer: ArtifactRenderable {
        static let artifactType: ArtifactType = .markdown
        func body(artifact: AnyArtifact, payload: String) -> some View { EmptyView() }

        static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
            if artifact.payload.isEmpty {
                return .preRenderable(PreRenderableProgress(receivedCharacters: 0))
            }
            return .renderable(artifact.payload)
        }
    }

    @Test func customRendererCanOverrideToRenderable() {
        let streaming = AnyArtifact(id: .init("a"), type: .markdown, payload: "x", isComplete: false)
        #expect(PartialAwareRenderer.refine(streaming) == .renderable("x"))
    }
}
