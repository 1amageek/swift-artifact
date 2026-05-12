import SwiftUI
import ArtifactCore
import ArtifactRenderer

/// Renders one `ArtifactMessage` — alternating prose and embedded artifacts —
/// inside a chat bubble.
///
/// Generic over the view returned by `renderArtifact`, so the closure can
/// return `some View` without any `AnyView` erasure at the call site.
public struct ArtifactCanvas<ArtifactBody: View>: View {
    public let message: ArtifactMessage
    private let renderArtifact: @MainActor (AnyArtifact) -> ArtifactBody

    public init(
        _ message: ArtifactMessage,
        @ViewBuilder renderArtifact: @escaping @MainActor (AnyArtifact) -> ArtifactBody
    ) {
        self.message = message
        self.renderArtifact = renderArtifact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.segments) { segment in
                switch segment {
                case .text(let text):
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .artifact(let artifact):
                    renderArtifact(artifact)
                }
            }
        }
    }
}

extension ArtifactCanvas where ArtifactBody == ArtifactCard<ArtifactView, EmptyView> {
    /// Default canvas that wraps every artifact in `ArtifactCard` and resolves
    /// the renderer from the environment registry. Register concrete
    /// renderers with `.artifactRenderer(_:)` somewhere above this view; any
    /// unmapped artifact falls back to `DefaultArtifactView`.
    public init(_ message: ArtifactMessage) {
        self.init(message) { artifact in
            ArtifactCard(artifact)
        }
    }
}

private struct _PreviewMarkdownRenderer: ArtifactRenderable, Sendable {
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

#Preview("Prose + artifact (integration)") {
    let artifact = AnyArtifact(
        id: ArtifactIdentifier("k1"),
        type: .markdown,
        title: "Quarterly summary",
        payload: """
        ## Highlights
        - Revenue up 12%
        - 4 new product launches
        - 87 NPS
        """,
        isComplete: true
    )
    let message = ArtifactMessage(segments: [
        .text("Here's a quick read on the quarter:"),
        .artifact(artifact),
        .text("Let me know if you want me to dig deeper on any of these."),
    ])
    return ScrollView {
        ArtifactCanvas(message)
            .padding()
    }
    .artifactRenderer(_PreviewMarkdownRenderer())
    .frame(width: 460, height: 480)
}

#Preview("Text only") {
    ArtifactCanvas(
        ArtifactMessage(segments: [
            .text("No artifacts in this message — just prose."),
        ])
    )
    .padding()
    .frame(width: 460)
}
