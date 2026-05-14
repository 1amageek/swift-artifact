import SwiftUI
import ArtifactCore

/// Any type that can render an `AnyArtifact` into a SwiftUI view.
///
/// Conformance is the entire contract for becoming an artifact renderer.
///
/// The protocol enforces a two-stage rendering model:
///
/// 1. ``refine(_:)`` reduces the raw payload to a ``RefinedPayload`` — either
///    a pre-renderable progress signal or a valid subset string. This is the
///    only place where streaming-state logic lives.
/// 2. ``body(artifact:payload:)`` receives the renderer-validated payload and
///    draws it. Because the input is already a valid subset, the body does not
///    need to inspect `artifact.isComplete` or guard against truncated
///    structures — it can assume well-formed input.
///
/// Renderers that want a type-specific waiting UI (e.g. JSX source highlight
/// for React) opt into ``preRenderableBody(artifact:progress:)`` by overriding
/// the associated type away from `EmptyView`.
public protocol ArtifactRenderable {
    associatedtype Body: View
    associatedtype PreRenderableBody: View = EmptyView

    /// The artifact type this renderer is designed for. Used by host code to
    /// route artifacts to the correct renderer.
    static var artifactType: ArtifactType { get }

    /// Optional preferred content insets for hosting cards. When no explicit
    /// `.artifactCardContentInsets(_:)` is set in the environment, the card
    /// uses this value. Renderers whose body fills their frame edge-to-edge
    /// (Map, WebView surfaces) typically return `EdgeInsets()`. Returning
    /// `nil` (the default) leaves the package-level fallback in place, which
    /// is sized for textual bodies.
    static var preferredContentInsets: EdgeInsets? { get }

    /// Reduce `artifact.payload` to a renderer-valid subset, or report that
    /// nothing is renderable yet.
    static func refine(_ artifact: AnyArtifact) -> RefinedPayload

    /// Produce the view for `payload` — guaranteed to be the renderer's own
    /// `.renderable` output from ``refine(_:)``. The body should treat
    /// `payload` (not `artifact.payload`) as the source of truth.
    @MainActor @ViewBuilder
    func body(artifact: AnyArtifact, payload: String) -> Body

    /// Optional type-specific waiting UI. Defaults to `EmptyView`, in which
    /// case the view layer falls back to `ArtifactProgressView`.
    @MainActor @ViewBuilder
    func preRenderableBody(artifact: AnyArtifact, progress: PreRenderableProgress) -> PreRenderableBody
}

extension ArtifactRenderable {
    /// Default refiner: wait until the artifact is complete before declaring
    /// anything renderable. Renderers with incremental support override this.
    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(receivedCharacters: artifact.payload.count)
        )
    }

    /// Default: no preference, host card falls back to its package-level
    /// content insets.
    public static var preferredContentInsets: EdgeInsets? { nil }
}

extension ArtifactRenderable where PreRenderableBody == EmptyView {
    /// Default empty implementation. The view layer detects this via the
    /// associated type and substitutes `ArtifactProgressView`.
    @MainActor @ViewBuilder
    public func preRenderableBody(artifact: AnyArtifact, progress: PreRenderableProgress) -> EmptyView {
        EmptyView()
    }
}
