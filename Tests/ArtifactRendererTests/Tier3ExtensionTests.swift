import Testing
import SwiftUI
import ArtifactCore
import ArtifactRenderer

/// Tier 3: third parties define their own MIME type, `Artifactable`
/// conformance, and renderer without touching the library. This suite
/// exercises that path end-to-end.
@Suite("Tier 3 extension")
struct Tier3ExtensionTests {

    // MARK: Custom type

    struct StickyNote: Artifactable, Equatable {
        static let artifactType: ArtifactType = "application/vnd.example.sticky"

        let id: ArtifactIdentifier
        let title: String
        let body: String
        let color: String

        init(id: ArtifactIdentifier, title: String, body: String, color: String) {
            self.id = id
            self.title = title
            self.body = body
            self.color = color
        }

        init(from raw: RawArtifact) throws {
            guard raw.type == Self.artifactType else {
                throw ArtifactError.typeMismatch(expected: Self.artifactType, actual: raw.type)
            }
            self.id = raw.identifier
            self.title = raw.title
            self.body = raw.payload
            self.color = raw.attributes["color"] ?? "yellow"
        }

        var rawArtifact: RawArtifact {
            RawArtifact(
                identifier: id,
                type: Self.artifactType,
                title: title,
                payload: body,
                attributes: ["color": color]
            )
        }
    }

    // MARK: Custom renderer

    struct StickyNoteRenderer: ArtifactRenderable {
        static let artifactType: ArtifactType = StickyNote.artifactType

        func body(artifact: AnyArtifact, payload: String) -> some View {
            Text(payload)
        }

        static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
            if artifact.payload.isEmpty {
                return .preRenderable(PreRenderableProgress(receivedCharacters: 0))
            }
            return .renderable(artifact.payload)
        }
    }

    // MARK: Tests

    @Test func customTypeRoundTripsThroughRawArtifact() throws {
        let original = StickyNote(
            id: ArtifactIdentifier("n1"),
            title: "Reminder",
            body: "Buy milk",
            color: "pink"
        )
        let raw = original.rawArtifact
        let restored = try StickyNote(from: raw)
        #expect(restored == original)
    }

    @Test func customTypeParsesFromArtifactTag() throws {
        let source = #"""
        <artifact identifier="n1" type="application/vnd.example.sticky" title="Reminder" color="pink">Buy milk</artifact>
        """#
        let any = try ArtifactParser.parseOne(source)
        let note = try StickyNote(from: any.raw)
        #expect(note.title == "Reminder")
        #expect(note.color == "pink")
        #expect(note.body == "Buy milk")
    }

    @Test func customRendererPartialState() {
        let streaming = AnyArtifact(
            id: ArtifactIdentifier("n1"),
            type: StickyNote.artifactType,
            payload: "in flight",
            isComplete: false
        )
        #expect(StickyNoteRenderer.refine(streaming) == .renderable("in flight"))
    }

    @Test func wrongTypeThrows() {
        let raw = RawArtifact(
            identifier: ArtifactIdentifier("n1"),
            type: .markdown,
            payload: "x"
        )
        #expect(throws: ArtifactError.typeMismatch(expected: StickyNote.artifactType, actual: .markdown)) {
            _ = try StickyNote(from: raw)
        }
    }
}
