import Testing
import SwiftUI
import ArtifactCore
@testable import ArtifactRenderer

@Suite("ArtifactRenderingState")
struct RenderingStateTests {

    struct DefaultRenderer: ArtifactRenderable {
        static let artifactType: ArtifactType = .markdown
        func body(artifact: AnyArtifact) -> some View { EmptyView() }
    }

    @Test func defaultProtocolBehavior() {
        let empty = AnyArtifact(id: .init("a"), type: .markdown)
        #expect(DefaultRenderer.renderingState(for: empty) == .empty)

        let streaming = AnyArtifact(id: .init("a"), type: .markdown, payload: "hi", isComplete: false)
        #expect(DefaultRenderer.renderingState(for: streaming) == .streaming)

        let complete = AnyArtifact(id: .init("a"), type: .markdown, payload: "hi", isComplete: true)
        #expect(DefaultRenderer.renderingState(for: complete) == .complete)
    }

    struct PartialAwareRenderer: ArtifactRenderable {
        static let artifactType: ArtifactType = .markdown
        func body(artifact: AnyArtifact) -> some View { EmptyView() }

        static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
            if artifact.payload.isEmpty { return .empty }
            return artifact.isComplete ? .complete : .partial
        }
    }

    @Test func customRendererCanOverrideToPartial() {
        let streaming = AnyArtifact(id: .init("a"), type: .markdown, payload: "x", isComplete: false)
        #expect(PartialAwareRenderer.renderingState(for: streaming) == .partial)
    }
}
