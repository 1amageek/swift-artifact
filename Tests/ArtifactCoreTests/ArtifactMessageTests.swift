import Testing
import Foundation
@testable import ArtifactCore

@Suite("ArtifactMessage & RawArtifact")
struct ArtifactMessageTests {

    @Test func emptyIsZeroSegments() {
        #expect(ArtifactMessage.empty.segments.isEmpty)
        #expect(ArtifactMessage.empty.artifacts.isEmpty)
        #expect(ArtifactMessage.empty.plainText.isEmpty)
    }

    @Test func plainTextConcatenatesTextSegmentsOnly() {
        let artifact = AnyArtifact(
            id: ArtifactIdentifier("a"),
            type: .markdown,
            payload: "ignored"
        )
        let msg = ArtifactMessage(segments: [
            .text("before "),
            .artifact(artifact),
            .text("after"),
        ])
        #expect(msg.plainText == "before after")
        #expect(msg.artifacts.count == 1)
    }

    @Test func segmentIdsAreStable() {
        let a = ArtifactMessage.Segment.text("hello")
        let b = ArtifactMessage.Segment.text("hello")
        #expect(a.id == b.id)

        let artifact = AnyArtifact(id: ArtifactIdentifier("x"), type: .html)
        #expect(ArtifactMessage.Segment.artifact(artifact).id == "artifact:x")
    }

    @Test func rawArtifactRoundTrip() {
        let raw = RawArtifact(
            identifier: ArtifactIdentifier("r1"),
            type: .code,
            title: "Sample",
            payload: "let x = 1",
            attributes: ["language": "swift"]
        )
        let any = AnyArtifact(raw: raw)
        #expect(any.isComplete)
        #expect(any.id == raw.identifier)
        #expect(any.attributes["language"] == "swift")

        let back = any.raw
        #expect(back == raw)
    }

    @Test func anyArtifactPreservesStreamingFlag() {
        let raw = RawArtifact(
            identifier: ArtifactIdentifier("s"),
            type: .markdown,
            payload: "x"
        )
        let streaming = AnyArtifact(raw: raw, isComplete: false)
        #expect(!streaming.isComplete)
    }
}
