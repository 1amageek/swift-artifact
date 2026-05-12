import Testing
import Foundation
@testable import ArtifactCore

@Suite("ArtifactStreamParser")
struct ArtifactStreamParserTests {

    @Test func feedingFullSourceOneShot() async throws {
        let parser = ArtifactStreamParser()
        let source = #"prefix <artifact identifier="a" type="text/markdown" title="t">body</artifact> tail"#
        _ = await parser.feed(source)
        let msg = try await parser.finalize()
        #expect(msg.artifacts.count == 1)
        #expect(msg.artifacts[0].payload == "body")
        #expect(msg.artifacts[0].isComplete)
        #expect(msg.plainText.contains("prefix"))
        #expect(msg.plainText.contains("tail"))
    }

    @Test func snapshotShowsPartialArtifact() async throws {
        let parser = ArtifactStreamParser()
        _ = await parser.feed(#"<artifact identifier="a" type="text/markdown">part"#)
        let snap = await parser.snapshot()
        #expect(snap.artifacts.count == 1)
        #expect(snap.artifacts[0].payload == "part")
        #expect(!snap.artifacts[0].isComplete)
    }

    @Test func openMarkerSplitAcrossChunks() async throws {
        let parser = ArtifactStreamParser()
        _ = await parser.feed("hello <arti")
        _ = await parser.feed(#"fact identifier="a" type="text/html">"#)
        _ = await parser.feed("body</artifact>")
        let msg = try await parser.finalize()
        #expect(msg.artifacts.count == 1)
        #expect(msg.artifacts[0].payload == "body")
        #expect(msg.plainText == "hello ")
    }

    @Test func closeMarkerSplitAcrossChunks() async throws {
        let parser = ArtifactStreamParser()
        _ = await parser.feed(#"<artifact identifier="a" type="text/html">body</art"#)
        let mid = await parser.snapshot()
        #expect(!(mid.artifacts.first?.isComplete ?? true))
        // The trailing `</art` is held back, so payload should still be "body".
        #expect(mid.artifacts.first?.payload == "body")

        _ = await parser.feed("ifact>")
        let msg = try await parser.finalize()
        #expect(msg.artifacts.count == 1)
        #expect(msg.artifacts[0].payload == "body")
        #expect(msg.artifacts[0].isComplete)
    }

    @Test func eventsOrderingForFullStream() async throws {
        let parser = ArtifactStreamParser()
        var events: [ArtifactStreamEvent] = []
        events += await parser.feedEvents("hi ")
        events += await parser.feedEvents(#"<artifact identifier="a" type="text/html">"#)
        events += await parser.feedEvents("bo")
        events += await parser.feedEvents("dy</artifact>")
        _ = try await parser.finalize()

        // Expect at least: text, opened, delta+, closed.
        #expect(events.contains { if case .text("hi ") = $0 { return true }; return false })
        let openedIdx = events.firstIndex { if case .opened = $0 { return true }; return false }
        let closedIdx = events.firstIndex { if case .closed = $0 { return true }; return false }
        let opened = try #require(openedIdx)
        let closed = try #require(closedIdx)
        #expect(opened < closed)

        // All deltas should sit strictly between opened and closed.
        for (i, event) in events.enumerated() {
            if case .delta = event {
                #expect(i > opened && i < closed)
            }
        }

        // Concatenated delta chunks should reproduce the payload.
        let payload = events.compactMap { event -> String? in
            if case .delta(_, let chunk) = event { return chunk }
            return nil
        }.joined()
        #expect(payload == "body")
    }

    @Test func chunkBoundaryInsidePayloadDoesNotSplitMarker() async throws {
        let parser = ArtifactStreamParser()
        // Feed character-by-character to stress the partial-match buffer.
        let source = #"<artifact identifier="a" type="text/html">abc</artifact>"#
        for ch in source {
            _ = await parser.feedEvents(String(ch))
        }
        let msg = try await parser.finalize()
        #expect(msg.artifacts.count == 1)
        #expect(msg.artifacts[0].payload == "abc")
        #expect(msg.artifacts[0].isComplete)
    }

    @Test func resetClearsState() async throws {
        let parser = ArtifactStreamParser()
        _ = await parser.feed(#"<artifact identifier="a" type="text/html">x"#)
        await parser.reset()
        let snap = await parser.snapshot()
        #expect(snap.segments.isEmpty)
    }

    @Test func finalizeWithUnterminatedThrows() async throws {
        let parser = ArtifactStreamParser()
        _ = await parser.feed(#"<artifact identifier="oops" type="text/html">payload"#)
        await #expect(throws: ArtifactError.unterminatedArtifact(ArtifactIdentifier("oops"))) {
            try await parser.finalize()
        }
    }

    @Test func longestPartialMatchPicksMaximum() {
        #expect(longestPartialMatch(suffixOf: "abc<art", prefixOf: "<artifact") == 4)
        #expect(longestPartialMatch(suffixOf: "abc<", prefixOf: "<artifact") == 1)
        #expect(longestPartialMatch(suffixOf: "abcdef", prefixOf: "<artifact") == 0)
        #expect(longestPartialMatch(suffixOf: "", prefixOf: "<artifact") == 0)
    }
}
