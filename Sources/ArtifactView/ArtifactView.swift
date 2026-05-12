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
        Group {
            if let renderer = renderers[artifact.type] {
                switch renderer.refine(artifact) {
                case .preRenderable:
                    ArtifactProgressView(artifact: artifact)
                case let .renderable(payload):
                    renderer.body(artifact, payload)
                }
            } else {
                DefaultArtifactView(artifact)
            }
        }
        // Make rendered content selectable by default. Renderers that need
        // different behavior (e.g. WebView surfaces with their own selection
        // model, or interactive widgets) can override with
        // `.textSelection(.disabled)`.
        .textSelection(.enabled)
    }
}

/// Typed counterpart to `ArtifactView` used internally by `ArtifactCard`'s
/// renderer-based init. Public for generic-constraint reasons only — host
/// code should prefer `ArtifactView(_:)` plus `.artifactRenderer(_:)`.
///
/// Unlike the env-based `ArtifactView`, this path honours the renderer's
/// opt-in `preRenderableBody` (via the associated type) when provided.
public struct _ArtifactView<R: ArtifactRenderable>: View {
    public let artifact: AnyArtifact
    public let renderer: R

    public init(_ artifact: AnyArtifact, renderer: R) {
        self.artifact = artifact
        self.renderer = renderer
    }

    public var body: some View {
        Group {
            switch R.refine(artifact) {
            case let .preRenderable(progress):
                if R.PreRenderableBody.self == EmptyView.self {
                    ArtifactProgressView(artifact: artifact)
                } else {
                    renderer.preRenderableBody(artifact: artifact, progress: progress)
                }
            case let .renderable(payload):
                renderer.body(artifact: artifact, payload: payload)
            }
        }
        .textSelection(.enabled)
    }
}

private struct _PreviewRenderer: ArtifactRenderable, Sendable {
    static let artifactType: ArtifactType = .markdown
    func body(artifact: AnyArtifact, payload: String) -> some View {
        Text(payload)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.payload.isEmpty {
            return .preRenderable(PreRenderableProgress(receivedCharacters: 0))
        }
        return .renderable(artifact.payload)
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

#Preview("Pre-renderable via environment") {
    struct _CompleteOnly: ArtifactRenderable, Sendable {
        static let artifactType: ArtifactType = .react
        func body(artifact: AnyArtifact, payload: String) -> some View { EmptyView() }
        static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
            .preRenderable(PreRenderableProgress(receivedCharacters: artifact.payload.count))
        }
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
    .artifactRenderer(_CompleteOnly())
    .padding()
    .frame(width: 420)
}
