import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

public struct GIFRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .gif
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        RasterImageRefiner.refine(artifact)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        RasterImageRendererBody(payload: payload, title: artifact.title, formatName: "GIF image")
    }
}

#if DEBUG
#Preview("Card — GIF data URL") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("gif1"),
            type: .gif,
            title: "Preview.gif",
            payload: MediaRendererDebugPreviewSamples.gifDataURL,
            isComplete: true
        ),
        renderer: GIFRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — GIF data URL") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("gif2"),
            type: .gif,
            title: "Preview.gif",
            payload: MediaRendererDebugPreviewSamples.gifDataURL,
            isComplete: true
        )
    )
    .artifactRenderer(GIFRenderer())
    .frame(width: 360)
}

#Preview("Card — pending GIF payload") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("gif3"),
            type: .gif,
            title: "Receiving GIF",
            payload: String(MediaRendererDebugPreviewSamples.gifDataURL.prefix(24)),
            isComplete: false
        ),
        renderer: GIFRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — invalid GIF payload") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("gif4"),
            type: .gif,
            title: "Invalid GIF payload",
            payload: MediaRendererDebugPreviewSamples.invalidPayload,
            isComplete: true
        )
    )
    .artifactRenderer(GIFRenderer())
    .frame(width: 360)
}

#endif
