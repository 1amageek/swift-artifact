import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders `text/turtle` artifacts as a force-directed knowledge-graph diagram.
///
/// Streaming behaviour: Turtle is line-/triple-terminated by `.`, so the
/// partial-payload strategy is to attempt a parse on every chunk and render
/// the result if it parses. A failing parse during streaming is the normal
/// "no complete triple yet" condition — not an error — so it lowers the
/// renderer to `.preRenderable`. The complete payload always reaches
/// `body(...)`, so a final parse failure surfaces via the in-view error UI
/// rather than being hidden.
public struct TurtleRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .turtle
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        if parseSucceeds(artifact.payload, baseIRI: artifact.attributes["base"]) {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first complete triple"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        KnowledgeGraphRendererBody(artifact: artifact, payload: payload, format: .turtle)
    }

    private static func parseSucceeds(_ source: String, baseIRI: String?) -> Bool {
        do {
            _ = try KnowledgeGraphFormat.turtle.parse(source, scope: "preview", baseIRI: baseIRI)
            return true
        } catch {
            return false
        }
    }
}

#Preview("Card — small Turtle graph") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("t1"),
            type: .turtle,
            title: "People",
            payload: """
            @prefix ex: <http://example.org/> .
            @prefix foaf: <http://xmlns.com/foaf/0.1/> .
            ex:alice foaf:name "Alice" ; foaf:knows ex:bob .
            ex:bob foaf:name "Bob" ; foaf:knows ex:carol .
            ex:carol foaf:name "Carol" .
            """,
            isComplete: true
        ),
        renderer: TurtleRenderer()
    )
    .padding()
    .frame(width: 520, height: 420)
}

#Preview("Bare — malformed Turtle → error") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("t2"),
            type: .turtle,
            payload: """
            @prefix ex: <http://example.org/> .
            ex:s ex:p
            """,
            isComplete: true
        )
    )
    .artifactRenderer(TurtleRenderer())
    .padding()
    .frame(width: 420, height: 360)
}
