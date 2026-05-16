import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView
import KnowledgeGraph

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
        if KnowledgeGraphFormat.turtle.hasRenderablePartial(
            artifact.payload,
            baseIRI: artifact.attributes["base"]
        ) {
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
    .frame(width: 420, height: 360)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("t3"),
        type: .turtle,
        title: "Streaming people",
        fullPayload: """
        @prefix ex: <http://example.org/> .
        @prefix foaf: <http://xmlns.com/foaf/0.1/> .
        ex:alice foaf:name "Alice" ; foaf:knows ex:bob .
        ex:bob foaf:name "Bob" ; foaf:knows ex:carol .
        ex:carol foaf:name "Carol" ; foaf:knows ex:dave .
        ex:dave foaf:name "Dave" .
        """,
        chunkSize: 8,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(TurtleRenderer())
    .frame(width: 520, height: 460)
}

// MARK: - Group previews
//
// Turtle is a triples-only format — no named-graph syntax — so neither
// `.namedGraphs` nor `.byType` / `.byNamespace` derive groups from the parsed
// payload. The only way to apply groups to a Turtle graph is the caller-driven
// `.explicit` strategy, where the caller supplies member node IDs directly.
// Nested groups are expressed via subset membership: parent's members are a
// superset of children's.

#Preview("Nested groups — .explicit (company ⊇ team ⊇ core)") {
    let alice = NodeIdentifier.iri("http://example.org/alice")
    let bob = NodeIdentifier.iri("http://example.org/bob")
    let carol = NodeIdentifier.iri("http://example.org/carol")
    let dave = NodeIdentifier.iri("http://example.org/dave")
    let eve = NodeIdentifier.iri("http://example.org/eve")
    return KnowledgeGraphView(
        graph: turtlePreviewGraph(
            """
            @prefix ex: <http://example.org/> .
            @prefix foaf: <http://xmlns.com/foaf/0.1/> .
            ex:alice foaf:knows ex:bob .
            ex:bob foaf:knows ex:carol .
            ex:carol foaf:knows ex:dave .
            ex:dave foaf:knows ex:eve .
            ex:eve foaf:knows ex:alice .
            """,
            scope: "turtle-nested-explicit"
        ),
        groupingStrategy: .explicit(groups: [
            GroupingStrategy.ExplicitGroup(
                id: "company",
                label: "Company",
                memberNodeIDs: [alice, bob, carol, dave, eve]
            ),
            GroupingStrategy.ExplicitGroup(
                id: "engineering",
                label: "Engineering",
                memberNodeIDs: [alice, bob, carol]
            ),
            GroupingStrategy.ExplicitGroup(
                id: "core",
                label: "Core",
                memberNodeIDs: [alice, bob]
            )
        ])
    )
    .frame(width: 640, height: 480)
}

private func turtlePreviewGraph(
    _ payload: String,
    scope: String
) -> KnowledgeGraph {
    do {
        return try KnowledgeGraphFormat.turtle.parse(payload, scope: scope, baseIRI: nil)
    } catch {
        fatalError("Turtle preview parse failure (\(scope)): \(error)")
    }
}
