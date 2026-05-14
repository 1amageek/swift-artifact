import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders `application/ld+json` artifacts as a force-directed diagram.
///
/// Streaming behaviour: while the artifact is incomplete, a tolerant
/// partial-JSON pass extracts whatever triples are derivable from the
/// currently-arrived prefix (`PartialJSONLDProcessor`). Once a single triple
/// is available, the renderer flips to `.renderable` so the diagram appears
/// progressively rather than waiting for the closing `}`. The complete
/// payload runs through the full W3C JSON-LD parser as the final pass.
///
/// Setting `attributes["base"]` supplies the base IRI used to resolve
/// relative IRIs inside the document; for the complete-payload parse the
/// underlying parser throws `ParserError.noBaseIRI` if a relative IRI
/// appears with no base in scope.
public struct JSONLDRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .jsonLD
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        if KnowledgeGraphFormat.jsonLD.hasRenderablePartial(
            artifact.payload,
            baseIRI: artifact.attributes["base"]
        ) {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first resolvable node"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        KnowledgeGraphRendererBody(artifact: artifact, payload: payload, format: .jsonLD)
    }
}

#Preview("Card — small JSON-LD graph") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("jl1"),
            type: .jsonLD,
            title: "JSON-LD",
            attributes: ["base": "http://example.org/"],
            payload: #"""
            {
              "@context": {
                "name": "http://schema.org/name",
                "knows": {
                  "@id": "http://schema.org/knows",
                  "@type": "@id"
                }
              },
              "@graph": [
                {"@id": "http://example.org/alice", "name": "Alice", "knows": "http://example.org/bob"},
                {"@id": "http://example.org/bob",   "name": "Bob",   "knows": "http://example.org/carol"},
                {"@id": "http://example.org/carol", "name": "Carol"}
              ]
            }
            """#,
            isComplete: true
        ),
        renderer: JSONLDRenderer()
    )
    .padding()
    .frame(width: 520, height: 420)
}

#Preview("Bare — malformed JSON-LD → error") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("jl2"),
            type: .jsonLD,
            attributes: ["base": "http://example.org/"],
            payload: #"""
            {
              "@context": { "name": "http://schema.org/name" },
              "@id": "http://example.org/alice",
              "name": "Alice
            """#,
            isComplete: true
        )
    )
    .artifactRenderer(JSONLDRenderer())
    .padding()
    .frame(width: 420, height: 360)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("jl3"),
        type: .jsonLD,
        title: "Streaming JSON-LD",
        attributes: ["base": "http://example.org/"],
        fullPayload: #"""
        {
          "@context": {
            "name": "http://schema.org/name",
            "knows": { "@id": "http://schema.org/knows", "@type": "@id" }
          },
          "@graph": [
            {"@id": "http://example.org/alice", "name": "Alice", "knows": "http://example.org/bob"},
            {"@id": "http://example.org/bob",   "name": "Bob",   "knows": "http://example.org/carol"},
            {"@id": "http://example.org/carol", "name": "Carol", "knows": "http://example.org/dave"},
            {"@id": "http://example.org/dave",  "name": "Dave"}
          ]
        }
        """#,
        chunkSize: 8,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(JSONLDRenderer())
    .padding()
    .frame(width: 520, height: 460)
}
