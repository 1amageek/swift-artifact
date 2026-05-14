import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders `application/rdf+xml` artifacts as a force-directed diagram.
///
/// RDF/XML requires a closing `</rdf:RDF>` element to parse cleanly, so the
/// streaming heuristic that works for line-oriented formats does not apply
/// here. The renderer waits for `isComplete` before attempting a parse —
/// partial XML is unlikely to round-trip through the parser anyway.
public struct RDFXMLRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .rdfXML
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        KnowledgeGraphRendererBody(artifact: artifact, payload: payload, format: .rdfXML)
    }
}

#Preview("Card — small RDF/XML graph") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("rx1"),
            type: .rdfXML,
            title: "RDF/XML",
            payload: """
            <?xml version="1.0" encoding="UTF-8"?>
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                     xmlns:ex="http://example.org/">
              <rdf:Description rdf:about="http://example.org/alice">
                <ex:name>Alice</ex:name>
                <ex:knows rdf:resource="http://example.org/bob"/>
              </rdf:Description>
              <rdf:Description rdf:about="http://example.org/bob">
                <ex:name>Bob</ex:name>
              </rdf:Description>
            </rdf:RDF>
            """,
            isComplete: true
        ),
        renderer: RDFXMLRenderer()
    )
    .padding()
    .frame(width: 520, height: 420)
}
