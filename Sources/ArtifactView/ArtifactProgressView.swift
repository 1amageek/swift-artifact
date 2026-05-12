import SwiftUI
import ArtifactCore

/// Placeholder shown by `ArtifactView` while a renderer's `refine(_:)` returns
/// `.preRenderable` and the renderer has not opted into a type-specific
/// `preRenderableBody`.
public struct ArtifactProgressView: View {
    public let artifact: AnyArtifact

    public init(artifact: AnyArtifact) {
        self.artifact = artifact
    }

    public var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.callout.weight(.medium))
                Text(artifact.type.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
        )
    }

    private var displayTitle: String {
        artifact.title.isEmpty ? "Streaming…" : artifact.title
    }
}

#Preview("With title") {
    ArtifactProgressView(
        artifact: AnyArtifact(
            id: ArtifactIdentifier("p"),
            type: .react,
            title: "Counter Component",
            payload: "",
            isComplete: false
        )
    )
    .padding()
    .frame(width: 360)
}

#Preview("Untitled") {
    ArtifactProgressView(
        artifact: AnyArtifact(
            id: ArtifactIdentifier("p"),
            type: .mermaid
        )
    )
    .padding()
    .frame(width: 360)
}
