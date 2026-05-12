import Testing
import Foundation
import ArtifactCore
import ArtifactRenderer
import ArtifactNativeRenderer

@Suite("GeoJSONMapKitRenderer.refine")
struct GeoJSONRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("g"),
            type: .geoJSON,
            payload: payload,
            isComplete: isComplete
        )
    }

    @Test func incompletePayloadWithoutAnyFeatureIsPreRenderable() {
        let result = GeoJSONMapKitRenderer.refine(
            artifact(payload: #"{"type":"FeatureCollection","feat"#, isComplete: false)
        )
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable before the first feature is complete")
        }
    }

    @Test func featureCollectionWithOneCompleteFeatureIsRenderable() throws {
        let payload = """
        {"type":"FeatureCollection","features":[\
        {"type":"Feature","geometry":{"type":"Point","coordinates":[139.7671,35.6812]}},\
        {"type":"Fea
        """
        let result = GeoJSONMapKitRenderer.refine(artifact(payload: payload, isComplete: false))
        guard case let .renderable(prefix) = result else {
            Issue.record("Expected .renderable once at least one Feature is complete")
            return
        }
        // The renderable prefix must be valid JSON, and contain exactly the
        // first (completed) Feature.
        let parsed = try JSONSerialization.jsonObject(with: Data(prefix.utf8)) as? [String: Any]
        let features = parsed?["features"] as? [[String: Any]]
        #expect(features?.count == 1)
        let geometry = features?.first?["geometry"] as? [String: Any]
        #expect(geometry?["type"] as? String == "Point")
    }

    @Test func singleFeatureWithIncompleteCoordinatesIsPreRenderable() {
        let payload = #"{"type":"Feature","geometry":{"type":"Point","coordinates":[139.7"#
        let result = GeoJSONMapKitRenderer.refine(artifact(payload: payload, isComplete: false))
        if case .preRenderable = result {
            // OK — a Point with only one coordinate is not a valid geometry,
            // so the parser yields zero features and we stay pre-renderable.
        } else {
            Issue.record("Expected .preRenderable while coordinates are still streaming")
        }
    }

    @Test func completePayloadIsReturnedRaw() {
        let payload = #"{"type":"Feature","geometry":{"type":"Point","coordinates":[139.7671,35.6812]}}"#
        let result = GeoJSONMapKitRenderer.refine(artifact(payload: payload, isComplete: true))
        #expect(result == .renderable(payload))
    }
}
