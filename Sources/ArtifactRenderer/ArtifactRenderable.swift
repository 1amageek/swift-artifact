import SwiftUI
import ArtifactCore

/// Any type that can render an `AnyArtifact` into a SwiftUI view.
///
/// Conformance is the entire contract for becoming an artifact renderer. There
/// is no registry, no central switch — `ArtifactView<R>` is selected at the call
/// site by passing an instance of `R`.
public protocol ArtifactRenderable {
    associatedtype Body: View

    /// The artifact type this renderer is designed for. Used by host code to
    /// route artifacts to the correct renderer.
    static var artifactType: ArtifactType { get }

    /// Produce the view for `artifact`. Called only when
    /// `renderingState(for:)` is `.partial` or `.complete`.
    @MainActor @ViewBuilder
    func body(artifact: AnyArtifact) -> Body

    /// Decide how to draw `artifact` right now. Renderers that can show
    /// in-progress content override this to return `.partial` while bytes are
    /// still arriving.
    static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState
}

extension ArtifactRenderable {
    /// Default behavior: do not attempt partial rendering. `streaming` is
    /// returned for everything that has not yet seen the closing tag.
    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.isComplete { return .complete }
        if artifact.payload.isEmpty { return .empty }
        return .streaming
    }
}
