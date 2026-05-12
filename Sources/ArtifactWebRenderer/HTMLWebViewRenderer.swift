import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders an HTML document by handing the payload directly to `WKWebView`.
public struct HTMLWebViewRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .html

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        // Browsers tolerate partial HTML — feed everything once any byte has
        // arrived.
        if artifact.payload.isEmpty {
            return .preRenderable(PreRenderableProgress(receivedCharacters: 0))
        }
        return .renderable(artifact.payload)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        ArtifactWebView(html: WebRendererShells.html(payload: payload))
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

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("h2"),
        type: .html,
        title: "Landing snippet",
        fullPayload: """
        <!doctype html>
        <html>
          <body style="font-family:-apple-system;padding:24px;">
            <h1>Streaming HTML</h1>
            <p>Bytes arrive every 0.3 seconds. The browser tolerates partial
            markup, so the refiner forwards every chunk as soon as it lands.</p>
            <ul>
              <li>First item</li>
              <li>Second item</li>
              <li>Third item</li>
            </ul>
          </body>
        </html>
        """,
        chunkSize: 8,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(HTMLWebViewRenderer())
    .padding()
    .frame(width: 480, height: 500)
}
