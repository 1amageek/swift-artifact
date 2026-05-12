import SwiftUI
import ArtifactCore
import ArtifactRenderer

/// Plain "show this artifact" view. Resolves the renderer dynamically from
/// the environment-registered registry — register renderers higher in the
/// hierarchy with `View.artifactRenderer(_:)`. Falls back to
/// `DefaultArtifactView` when no renderer is registered for the artifact's
/// type.
///
/// Use this in chat balloons, document outlines, and anywhere callers should
/// not have to know which concrete renderer applies. For an explicit typed
/// path, use `_ArtifactView` (implementation-detail) or pass `renderer:` to
/// `ArtifactCard`.
public struct ArtifactView: View {
    public let artifact: AnyArtifact

    @Environment(\.artifactRenderers) private var renderers

    public init(_ artifact: AnyArtifact) {
        self.artifact = artifact
    }

    public var body: some View {
        if let renderer = renderers[artifact.type] {
            switch renderer.renderingState(artifact) {
            case .empty:
                EmptyView()
            case .streaming:
                ArtifactProgressView(artifact: artifact)
            case .partial, .complete:
                renderer.body(artifact)
            }
        } else {
            DefaultArtifactView(artifact)
        }
    }
}

/// Typed counterpart to `ArtifactView` used internally by `ArtifactCard`'s
/// renderer-based init. Public for generic-constraint reasons only — host
/// code should prefer `ArtifactView(_:)` plus `.artifactRenderer(_:)`.
public struct _ArtifactView<R: ArtifactRenderable>: View {
    public let artifact: AnyArtifact
    public let renderer: R

    public init(_ artifact: AnyArtifact, renderer: R) {
        self.artifact = artifact
        self.renderer = renderer
    }

    public var body: some View {
        switch R.renderingState(for: artifact) {
        case .empty:
            EmptyView()
        case .streaming:
            ArtifactProgressView(artifact: artifact)
        case .partial, .complete:
            renderer.body(artifact: artifact)
        }
    }
}

private struct _PreviewRenderer: ArtifactRenderable, Sendable {
    static let artifactType: ArtifactType = .markdown
    func body(artifact: AnyArtifact) -> some View {
        Text(artifact.payload)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        return artifact.isComplete ? .complete : .partial
    }
}

#Preview("Resolved via environment") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("v1"),
            type: .markdown,
            title: "Note",
            payload: "Hello from the renderer.",
            isComplete: true
        )
    )
    .artifactRenderer(_PreviewRenderer())
    .padding()
    .frame(width: 420)
}

#Preview("No renderer registered → DefaultArtifactView") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("v2"),
            type: "application/vnd.unknown",
            title: "Mystery payload",
            payload: "{ \"unknown\": true }",
            isComplete: true
        )
    )
    .padding()
    .frame(width: 420)
}

#Preview("Streaming via environment") {
    struct _StreamingOnly: ArtifactRenderable, Sendable {
        static let artifactType: ArtifactType = .react
        func body(artifact: AnyArtifact) -> some View { EmptyView() }
        static func renderingState(for _: AnyArtifact) -> ArtifactRenderingState { .streaming }
    }
    return ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("v3"),
            type: .react,
            title: "Counter.jsx",
            payload: "in flight",
            isComplete: false
        )
    )
    .artifactRenderer(_StreamingOnly())
    .padding()
    .frame(width: 420)
}
