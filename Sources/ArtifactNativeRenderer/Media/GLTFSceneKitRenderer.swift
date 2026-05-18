import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders glTF / GLB payloads.
///
/// The MVP build avoids platform-specific 3D viewers (`Model3D` is unavailable
/// on macOS at the time of writing, `SceneView` is deprecated, and there is no
/// public native glTF loader on Apple platforms). Instead the renderer shows a
/// summary card with the model URL and platform-appropriate hooks for opening
/// the asset in the system viewer. Applications that need an embedded viewer
/// should provide their own `ArtifactRenderable` for these types.
public struct GLTFSceneKitRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .gltf

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        // The payload is a URL string. Until the artifact closes we cannot
        // know whether the URL is complete (no scheme-aware mid-stream cut
        // is reliable), so wait for `isComplete`.
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for complete URL"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        ModelPlaceholderView(payload: payload, systemImage: "cube.transparent")
    }
}

struct ModelPlaceholderView: View {
    let payload: String
    let systemImage: String

    var body: some View {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: trimmed)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(url?.lastPathComponent ?? "3D model")
                        .font(.callout.weight(.semibold))
                    Text(trimmed)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            if let url {
                Link(destination: url) {
                    Label("Open in system viewer", systemImage: "arrow.up.right.square")
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

#Preview("Card — glTF URL") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("gl1"),
            type: .gltf,
            title: "Duck",
            payload: "https://example.com/assets/duck.gltf",
            isComplete: true
        ),
        renderer: GLTFSceneKitRenderer()
    )
    .frame(width: 460)
}
