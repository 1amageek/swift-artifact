import SwiftUI
import ArtifactCore

/// Type-erased `ArtifactRenderable`. Used by the environment-driven renderer
/// registry that powers the plain `ArtifactView(_:)` API: callers register
/// concrete renderers higher in the view hierarchy, and the view looks them
/// up by `ArtifactType` at body time.
///
/// The env-based path does not surface `preRenderableBody` — a renderer's
/// type-specific waiting UI is only accessible via the typed `_ArtifactView<R>`
/// path. Env-resolved pre-renderable artifacts fall back to
/// `ArtifactProgressView` uniformly.
public struct AnyArtifactRenderer: Sendable {
    public let artifactType: ArtifactType
    public let preferredContentInsets: EdgeInsets?
    public let refine: @Sendable (AnyArtifact) -> RefinedPayload
    public let body: @MainActor @Sendable (AnyArtifact, String) -> AnyView

    public init<R: ArtifactRenderable & Sendable>(_ renderer: R) {
        self.artifactType = R.artifactType
        self.preferredContentInsets = R.preferredContentInsets
        self.refine = { R.refine($0) }
        self.body = { artifact, payload in
            AnyView(renderer.body(artifact: artifact, payload: payload))
        }
    }
}
