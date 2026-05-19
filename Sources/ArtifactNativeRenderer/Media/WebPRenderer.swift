import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

public struct WebPRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .webp
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        RasterImageRefiner.refine(artifact)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        RasterImageRendererBody(payload: payload, title: artifact.title, formatName: "WebP image")
    }
}

#if DEBUG
#Preview("Card — WebP data URL") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("webp1"),
            type: .webp,
            title: "Preview.webp",
            payload: MediaRendererDebugPreviewSamples.webpDataURL,
            isComplete: true
        ),
        renderer: WebPRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — WebP data URL") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("webp2"),
            type: .webp,
            title: "Preview.webp",
            payload: MediaRendererDebugPreviewSamples.webpDataURL,
            isComplete: true
        )
    )
    .artifactRenderer(WebPRenderer())
    .frame(width: 360)
}

#Preview("Card — pending WebP payload") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("webp3"),
            type: .webp,
            title: "Receiving WebP",
            payload: String(MediaRendererDebugPreviewSamples.webpDataURL.prefix(24)),
            isComplete: false
        ),
        renderer: WebPRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — invalid WebP payload") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("webp4"),
            type: .webp,
            title: "Invalid WebP payload",
            payload: MediaRendererDebugPreviewSamples.invalidPayload,
            isComplete: true
        )
    )
    .artifactRenderer(WebPRenderer())
    .frame(width: 360)
}

#endif
