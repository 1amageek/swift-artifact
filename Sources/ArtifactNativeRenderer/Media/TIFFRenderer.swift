import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

public struct TIFFRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .tiff
    public static let fileInput: ArtifactFileInput = .localFileURL
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        RasterImageRefiner.refine(artifact)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        RasterImageRendererBody(payload: payload, title: artifact.title, formatName: "TIFF image")
    }
}

#if DEBUG
#Preview("Card — TIFF data URL") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("tiff1"),
            type: .tiff,
            title: "Preview.tiff",
            payload: MediaRendererDebugPreviewSamples.tiffDataURL,
            isComplete: true
        ),
        renderer: TIFFRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — TIFF data URL") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("tiff2"),
            type: .tiff,
            title: "Preview.tiff",
            payload: MediaRendererDebugPreviewSamples.tiffDataURL,
            isComplete: true
        )
    )
    .artifactRenderer(TIFFRenderer())
    .frame(width: 360)
}

#Preview("Card — pending TIFF payload") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("tiff3"),
            type: .tiff,
            title: "Receiving TIFF",
            payload: String(MediaRendererDebugPreviewSamples.tiffDataURL.prefix(24)),
            isComplete: false
        ),
        renderer: TIFFRenderer()
    )
    .frame(width: 360)
}

#Preview("Bare — invalid TIFF payload") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("tiff4"),
            type: .tiff,
            title: "Invalid TIFF payload",
            payload: MediaRendererDebugPreviewSamples.invalidPayload,
            isComplete: true
        )
    )
    .artifactRenderer(TIFFRenderer())
    .frame(width: 360)
}

#endif
