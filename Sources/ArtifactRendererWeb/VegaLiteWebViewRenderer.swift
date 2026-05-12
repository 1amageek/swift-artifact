import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders a Vega-Lite v5 specification by handing the JSON to vega-embed inside
/// a WKWebView.
public struct VegaLiteWebViewRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .vegaLite

    public init() {}

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        return artifact.isComplete ? .complete : .streaming
    }

    public func body(artifact: AnyArtifact) -> some View {
        ArtifactWebView(html: WebRendererShells.vegaLite(payload: artifact.payload))
            .frame(minHeight: 320)
    }
}

#Preview("Card — bar chart") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("vl1"),
            type: .vegaLite,
            title: "Sales by region",
            payload: """
            {
              "$schema": "https://vega.github.io/schema/vega-lite/v5.json",
              "data": {
                "values": [
                  {"region": "North", "sales": 162},
                  {"region": "South", "sales": 140},
                  {"region": "East",  "sales":  99},
                  {"region": "West",  "sales": 185}
                ]
              },
              "mark": "bar",
              "encoding": {
                "x": {"field": "region", "type": "nominal"},
                "y": {"field": "sales",  "type": "quantitative"}
              }
            }
            """,
            isComplete: true
        ),
        renderer: VegaLiteWebViewRenderer()
    )
    .padding()
    .frame(width: 520, height: 460)
}
