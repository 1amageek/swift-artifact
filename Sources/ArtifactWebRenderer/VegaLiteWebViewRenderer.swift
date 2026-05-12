import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders a Vega-Lite v5 specification by handing the JSON to vega-embed inside
/// a WKWebView.
public struct VegaLiteWebViewRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .vegaLite

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for complete Vega-Lite spec"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        ArtifactWebView(html: WebRendererShells.vegaLite(payload: payload))
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
