import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

public struct JPEGRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .jpeg
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        RasterImageRefiner.refine(artifact)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        RasterImageRendererBody(payload: payload, title: artifact.title, formatName: "JPEG image")
    }
}

#if DEBUG
#Preview("Card — JPEG data URL") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("jpeg1"),
            type: .jpeg,
            title: "Preview.jpg",
            payload: MediaRendererDebugPreviewSamples.jpegDataURL,
            isComplete: true
        ),
        renderer: JPEGRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — JPEG data URL") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("jpeg2"),
            type: .jpeg,
            title: "Preview.jpg",
            payload: MediaRendererDebugPreviewSamples.jpegDataURL,
            isComplete: true
        )
    )
    .artifactRenderer(JPEGRenderer())
    .frame(width: 360)
}

#Preview("Card — pending JPEG payload") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("jpeg3"),
            type: .jpeg,
            title: "Receiving JPEG",
            payload: String(MediaRendererDebugPreviewSamples.jpegDataURL.prefix(24)),
            isComplete: false
        ),
        renderer: JPEGRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — invalid JPEG payload") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("jpeg4"),
            type: .jpeg,
            title: "Invalid JPEG payload",
            payload: MediaRendererDebugPreviewSamples.invalidPayload,
            isComplete: true
        )
    )
    .artifactRenderer(JPEGRenderer())
    .frame(width: 360)
}

#endif
