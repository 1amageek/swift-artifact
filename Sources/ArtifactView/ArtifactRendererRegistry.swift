import SwiftUI
import ArtifactCore
import ArtifactRenderer

extension EnvironmentValues {
    /// The set of renderers visible to plain `ArtifactView(_:)` calls below
    /// this point in the hierarchy. Keyed by `ArtifactType`. Use
    /// `View.artifactRenderer(_:)` to register entries.
    @Entry public var artifactRenderers: [ArtifactType: AnyArtifactRenderer] = [:]
}

extension View {
    /// Register a renderer so any `ArtifactView` underneath this point can
    /// render artifacts of the matching `ArtifactType`. Stacks additively —
    /// each call adds (or replaces) one entry without clearing the others.
    public func artifactRenderer<R: ArtifactRenderable & Sendable>(_ renderer: R) -> some View {
        transformEnvironment(\.artifactRenderers) { registry in
            registry[R.artifactType] = AnyArtifactRenderer(renderer)
        }
    }

    /// Register a pre-erased renderer. Convenient when host code keeps its
    /// own list of renderers.
    public func artifactRenderer(_ renderer: AnyArtifactRenderer) -> some View {
        transformEnvironment(\.artifactRenderers) { registry in
            registry[renderer.artifactType] = renderer
        }
    }
}
