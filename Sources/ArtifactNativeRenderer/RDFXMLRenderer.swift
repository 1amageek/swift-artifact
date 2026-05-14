import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders `application/rdf+xml` artifacts as a force-directed diagram.
///
/// Streaming behaviour: while the artifact is incomplete, a framing pass
/// (`PartialRDFXMLProcessor`) extracts every fully-closed top-level element
/// under `<rdf:RDF>` and synthesises a well-formed document fed to the
/// standard `RDFXMLParser`. Once at least one node is derivable, the
/// renderer flips to `.renderable` so the diagram appears progressively
/// rather than waiting for the closing `</rdf:RDF>`.
public struct RDFXMLRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .rdfXML
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        if KnowledgeGraphFormat.rdfXML.hasRenderablePartial(
            artifact.payload,
            baseIRI: artifact.attributes["base"]
        ) {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first closed element"
            )
        )
    }

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

#Preview("Bare — malformed RDF/XML → error") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("rx2"),
            type: .rdfXML,
            payload: """
            <?xml version="1.0" encoding="UTF-8"?>
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about="http://example.org/x"
            </rdf:RDF>
            """,
            isComplete: true
        )
    )
    .artifactRenderer(RDFXMLRenderer())
    .padding()
    .frame(width: 420, height: 360)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("rx3"),
        type: .rdfXML,
        title: "Streaming RDF/XML",
        fullPayload: """
        <?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
          <rdf:Description rdf:about="http://example.org/alice">
            <ex:name>Alice</ex:name>
            <ex:knows rdf:resource="http://example.org/bob"/>
          </rdf:Description>
          <rdf:Description rdf:about="http://example.org/bob">
            <ex:name>Bob</ex:name>
            <ex:knows rdf:resource="http://example.org/carol"/>
          </rdf:Description>
          <rdf:Description rdf:about="http://example.org/carol">
            <ex:name>Carol</ex:name>
          </rdf:Description>
        </rdf:RDF>
        """,
        chunkSize: 12,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(RDFXMLRenderer())
    .padding()
    .frame(width: 520, height: 460)
}
