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
        // Trim any half-typed tag / raw-text block off the tail before
        // handing the snapshot to `WKWebView`. A bisected `<script>` would
        // otherwise put the parser into raw-text mode and swallow every
        // subsequent token in the document.
        if let prefix = PartialHTMLScanner.longestValidPrefix(artifact.payload) {
            return .renderable(prefix)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first complete tag"
            )
        )
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
    // The refiner trims half-typed tags off the tail and withholds
    // `<script>` / `<style>` blocks until their close tag arrives. The
    // `<style>` block in this preview is dropped entirely while it is
    // mid-stream, then appears whole as soon as `</style>` lands —
    // demonstrating the raw-text guard.
    StreamingPreviewHarness(
        id: ArtifactIdentifier("h2"),
        type: .html,
        title: "Landing snippet",
        fullPayload: """
        <!doctype html>
        <html>
          <head>
            <style>
              :root { color-scheme: light dark; }
              body { font-family: -apple-system; padding: 24px; }
              h1 { color: light-dark(#1a73e8, #8ab4f8); }
              .pill { background: light-dark(#eef, #224); border-radius: 999px; padding: 2px 10px; }
            </style>
          </head>
          <body>
            <h1>Streaming HTML</h1>
            <p>Bytes arrive every 0.3 seconds. The refiner trims any half-typed
            tag off the tail and holds back <span class="pill">script</span>
            and <span class="pill">style</span> blocks until they finish, so the
            WebView never enters raw-text mode mid-stream.</p>
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
    .frame(width: 480, height: 560)
}
