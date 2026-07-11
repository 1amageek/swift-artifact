import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

public struct BMPRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .bmp
    public static let fileInput: ArtifactFileInput = .localFileURL
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        RasterImageRefiner.refine(artifact)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        RasterImageRendererBody(payload: payload, title: artifact.title, formatName: "BMP image")
    }
}

#if DEBUG
#Preview("Card — BMP data URL") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("bmp1"),
            type: .bmp,
            title: "Preview.bmp",
            payload: MediaRendererDebugPreviewSamples.bmpDataURL,
            isComplete: true
        ),
        renderer: BMPRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — BMP data URL") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("bmp2"),
            type: .bmp,
            title: "Preview.bmp",
            payload: MediaRendererDebugPreviewSamples.bmpDataURL,
            isComplete: true
        )
    )
    .artifactRenderer(BMPRenderer())
    .frame(width: 360)
}

#Preview("Card — pending BMP payload") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("bmp3"),
            type: .bmp,
            title: "Receiving BMP",
            payload: String(MediaRendererDebugPreviewSamples.bmpDataURL.prefix(24)),
            isComplete: false
        ),
        renderer: BMPRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — invalid BMP payload") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("bmp4"),
            type: .bmp,
            title: "Invalid BMP payload",
            payload: MediaRendererDebugPreviewSamples.invalidPayload,
            isComplete: true
        )
    )
    .artifactRenderer(BMPRenderer())
    .frame(width: 360)
}

#endif
