import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

public struct HEICRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .heic
    public static let fileInput: ArtifactFileInput = .localFileURL
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        RasterImageRefiner.refine(artifact)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        RasterImageRendererBody(payload: payload, title: artifact.title, formatName: "HEIC image")
    }
}

#if DEBUG
#Preview("Card — HEIC data URL") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("heic1"),
            type: .heic,
            title: "Preview.heic",
            payload: MediaRendererDebugPreviewSamples.heicDataURL,
            isComplete: true
        ),
        renderer: HEICRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — HEIC data URL") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("heic2"),
            type: .heic,
            title: "Preview.heic",
            payload: MediaRendererDebugPreviewSamples.heicDataURL,
            isComplete: true
        )
    )
    .artifactRenderer(HEICRenderer())
    .frame(width: 360)
}

#Preview("Card — pending HEIC payload") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("heic3"),
            type: .heic,
            title: "Receiving HEIC",
            payload: String(MediaRendererDebugPreviewSamples.heicDataURL.prefix(24)),
            isComplete: false
        ),
        renderer: HEICRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — invalid HEIC payload") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("heic4"),
            type: .heic,
            title: "Invalid HEIC payload",
            payload: MediaRendererDebugPreviewSamples.invalidPayload,
            isComplete: true
        )
    )
    .artifactRenderer(HEICRenderer())
    .frame(width: 360)
}

#endif
