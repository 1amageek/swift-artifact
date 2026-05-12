import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

#if canImport(AppKit)
import AppKit
#endif

/// Renders SVG payloads.
///
/// On macOS, `NSImage(data:)` natively rasterizes SVG so the artifact appears
/// as a normal image. On iOS / iPadOS / visionOS, the system has no public
/// SVG decoder, so the source falls back to a monospaced display. Applications
/// that need true SVG on iOS should substitute a renderer backed by
/// `SVGView` / `SwiftDraw`.
public struct SVGNativeRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .svg

    public init() {}

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        return artifact.isComplete ? .complete : .partial
    }

    public func body(artifact: AnyArtifact) -> some View {
        SVGBody(payload: artifact.payload)
    }
}

private struct SVGBody: View {
    let payload: String

    var body: some View {
        #if canImport(AppKit)
        if let data = payload.data(using: .utf8),
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 360)
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("SVG source — install an SVG renderer to rasterize.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(payload)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 240)
        }
    }
}

#Preview("Card — Circle SVG") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("svg1"),
            type: .svg,
            title: "Logo",
            payload: """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120">
              <circle cx="60" cy="60" r="48" fill="#5B8FF9"/>
              <text x="60" y="68" text-anchor="middle" fill="white" \
                    font-family="-apple-system" font-size="28">Bob</text>
            </svg>
            """,
            isComplete: true
        ),
        renderer: SVGNativeRenderer()
    )
    .padding()
    .frame(width: 360)
}
