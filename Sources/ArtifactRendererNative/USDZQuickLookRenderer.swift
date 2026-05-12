import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders USDZ payloads. See the note on `GLTFSceneKitRenderer` for why the
/// MVP shows a placeholder card rather than an embedded 3D viewer.
public struct USDZQuickLookRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .usdz

    public init() {}

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        let url = artifact.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return .empty }
        return artifact.isComplete ? .complete : .streaming
    }

    public func body(artifact: AnyArtifact) -> some View {
        ModelPlaceholderView(payload: artifact.payload, systemImage: "rotate.3d.fill")
    }
}

#Preview("Card — USDZ URL") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("usdz1"),
            type: .usdz,
            title: "Robot",
            payload: "https://example.com/assets/robot.usdz",
            isComplete: true
        ),
        renderer: USDZQuickLookRenderer()
    )
    .padding()
    .frame(width: 460)
}
