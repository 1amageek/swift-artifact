import SwiftUI
import ArtifactCore

/// Type-erased `ArtifactRenderable`. Used by the environment-driven renderer
/// registry that powers the plain `ArtifactView(_:)` API: callers register
/// concrete renderers higher in the view hierarchy, and the view looks them
/// up by `ArtifactType` at body time.
public struct AnyArtifactRenderer: Sendable {
    public let artifactType: ArtifactType
    public let renderingState: @Sendable (AnyArtifact) -> ArtifactRenderingState
    public let body: @MainActor @Sendable (AnyArtifact) -> AnyView

    public init<R: ArtifactRenderable & Sendable>(_ renderer: R) {
        self.artifactType = R.artifactType
        self.renderingState = { R.renderingState(for: $0) }
        self.body = { artifact in AnyView(renderer.body(artifact: artifact)) }
    }
}
