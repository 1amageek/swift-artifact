import Testing
import Foundation
import ArtifactCore
import ArtifactRenderer
import ArtifactNativeRenderer

@Suite("JSONRenderer.refine + PartialJSONScanner")
struct JSONRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("j"),
            type: .json,
            payload: payload,
            isComplete: isComplete
        )
    }

    // MARK: - PartialJSONScanner

    @Test func fullyValidObjectIsReturnedAsIs() {
        let valid = PartialJSONScanner.longestValidPrefix(#"{"a":1,"b":2}"#)
        #expect(valid == #"{"a":1,"b":2}"#)
    }

    @Test func truncatedValueIsCutAtLastCompletePair() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"{"name":"Bob","ver"#)
        )
        let parsed = try JSONSerialization.jsonObject(
            with: Data(valid.utf8),
            options: []
        ) as? [String: Any]
        #expect(parsed?["name"] as? String == "Bob")
        // The truncated `ver` key must have been dropped.
        #expect(parsed?.count == 1)
    }

    @Test func arrayWithIncompleteTailIsTruncated() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"[1,2,3,4,"hal"#)
        )
        let parsed = try JSONSerialization.jsonObject(
            with: Data(valid.utf8),
            options: []
        ) as? [Any]
        let numbers = parsed?.compactMap { $0 as? Int } ?? []
        #expect(numbers == [1, 2, 3, 4])
    }

    @Test func sourceWithoutAnyCompletePairReturnsNil() {
        #expect(PartialJSONScanner.longestValidPrefix(#"{"par"#) == nil)
    }

    // MARK: - JSONRenderer.refine

    @Test func refineFallsBackToPreRenderableWhenNothingComplete() {
        let result = JSONRenderer.refine(artifact(payload: #"{"par"#, isComplete: false))
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable for incomplete leading key")
        }
    }

    @Test func refineSurfacesValidPrefix() {
        let result = JSONRenderer.refine(artifact(payload: #"{"a":1,"b":2,"c":"par"#, isComplete: false))
        guard case let .renderable(prefix) = result else {
            Issue.record("Expected .renderable")
            return
        }
        let parsed = try? JSONSerialization.jsonObject(with: Data(prefix.utf8)) as? [String: Any]
        #expect(parsed?["a"] as? Int == 1)
        #expect(parsed?["b"] as? Int == 2)
        #expect(parsed?.keys.contains("c") == false)
    }

    @Test func completePayloadReturnsRaw() {
        let result = JSONRenderer.refine(artifact(payload: #"{"a":1}"#, isComplete: true))
        #expect(result == .renderable(#"{"a":1}"#))
    }
}
