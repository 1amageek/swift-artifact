import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

public struct PNGRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .png
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        RasterImageRefiner.refine(artifact)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        RasterImageRendererBody(payload: payload, title: artifact.title, formatName: "PNG image")
    }
}

#if DEBUG
#Preview("Card — PNG data URL") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("png1"),
            type: .png,
            title: "Preview.png",
            payload: MediaRendererDebugPreviewSamples.pngDataURL,
            isComplete: true
        ),
        renderer: PNGRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — PNG data URL") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("png2"),
            type: .png,
            title: "Preview.png",
            payload: MediaRendererDebugPreviewSamples.pngDataURL,
            isComplete: true
        )
    )
    .artifactRenderer(PNGRenderer())
    .frame(width: 360)
}

#Preview("Card — pending PNG payload") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("png3"),
            type: .png,
            title: "Receiving PNG",
            payload: String(MediaRendererDebugPreviewSamples.pngDataURL.prefix(24)),
            isComplete: false
        ),
        renderer: PNGRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — invalid PNG payload") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("png4"),
            type: .png,
            title: "Invalid PNG payload",
            payload: MediaRendererDebugPreviewSamples.invalidPayload,
            isComplete: true
        )
    )
    .artifactRenderer(PNGRenderer())
    .frame(width: 360)
}

#endif
