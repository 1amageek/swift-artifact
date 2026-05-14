import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders `application/ld+json` artifacts as a force-directed diagram.
///
/// JSON-LD must be a complete JSON document before the toRdf algorithm can
/// run, so streaming is gated on `isComplete`. Setting an `attributes["base"]`
/// supplies the base IRI used to resolve relative IRIs inside the document;
/// the parser throws `ParserError.noBaseIRI` if a relative IRI appears with
/// no base in scope.
public struct JSONLDRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .jsonLD
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

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
