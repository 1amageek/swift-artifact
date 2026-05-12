import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders an HTML document by handing the payload directly to `WKWebView`.
public struct HTMLWebViewRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .html

    public init() {}

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        // Browsers tolerate partial HTML, so render whatever arrived.
        return artifact.isComplete ? .complete : .partial
    }

    public func body(artifact: AnyArtifact) -> some View {
        ArtifactWebView(html: WebRendererShells.html(payload: artifact.payload))
            .frame(minHeight: 280)
    }
}

#Preview("Card — inline HTML") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("h1"),
            type: .html,
            title: "Landing snippet",
            payload: """
            <!doctype html>
            <html>
              <body style="font-family:-apple-system;padding:24px;">
                <h1>Hello from artifact</h1>
                <p>This document is rendered inside a pooled <code>WKWebView</code>.</p>
                <ul>
                  <li>Streaming-friendly</li>
                  <li>Cross-platform</li>
                </ul>
              </body>
            </html>
            """,
            isComplete: true
        ),
        renderer: HTMLWebViewRenderer()
    )
    .padding()
    .frame(width: 480, height: 420)
}
