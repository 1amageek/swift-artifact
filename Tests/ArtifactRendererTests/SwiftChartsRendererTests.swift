import ArtifactCore
import ArtifactRenderer
import Testing

@testable import ArtifactNativeRenderer

@Suite("Swift Charts renderer")
struct SwiftChartsRendererTests {
    @Test func waitsForCompletePayload() {
        let artifact = AnyArtifact(
            id: ArtifactIdentifier("chart-partial"),
            type: .swiftCharts,
            payload: "{\"version\":1",
            isComplete: false
        )
        #expect(
            SwiftChartsRenderer.refine(artifact)
                == .preRenderable(
                    PreRenderableProgress(
                        receivedCharacters: artifact.payload.count,
                        hint: "waiting for complete chart JSON"
                    )
                )
        )
    }

    @Test func completePayloadIsPassedToRenderer() {
        let payload = """
            {"version":1,"dimension":"2d","mark":{"type":"line"},"data":[{"x":1,"y":2}],"encoding":{"x":{"field":"x","type":"quantitative"},"y":{"field":"y","type":"quantitative"}}}
            """
        let artifact = AnyArtifact(
            id: ArtifactIdentifier("chart-complete"),
            type: .swiftCharts,
            payload: payload,
            isComplete: true
        )
        #expect(SwiftChartsRenderer.refine(artifact) == .renderable(payload))
    }

    @Test func typeErasureKeepsChartArtifactType() {
        let renderer = AnyArtifactRenderer(SwiftChartsRenderer())
        #expect(renderer.artifactType == .swiftCharts)
    }
}
