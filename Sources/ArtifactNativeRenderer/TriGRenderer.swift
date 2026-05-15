import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView
import KnowledgeGraph

/// Renders `application/trig` artifacts as a force-directed diagram.
///
/// TriG is Turtle plus named-graph blocks. The view layer treats every quad
/// as a triple for visualisation; named-graph membership is not currently
/// drawn as a distinct visual region.
public struct TriGRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .trig
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        if KnowledgeGraphFormat.trig.hasRenderablePartial(
            artifact.payload,
            baseIRI: artifact.attributes["base"]
        ) {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first complete block"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        KnowledgeGraphRendererBody(artifact: artifact, payload: payload, format: .trig)
    }
}

#Preview("Card — small TriG graph") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("tg1"),
            type: .trig,
            title: "Named graphs",
            payload: """
            @prefix ex: <http://example.org/> .
            ex:g1 {
                ex:alice ex:knows ex:bob .
                ex:bob ex:knows ex:carol .
            }
            ex:g2 {
                ex:x ex:y ex:z .
            }
            """,
            isComplete: true
        ),
        renderer: TriGRenderer()
    )
    .padding()
    .frame(width: 520, height: 420)
}

#Preview("Bare — malformed TriG → error") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("tg2"),
            type: .trig,
            payload: """
            @prefix ex: <http://example.org/> .
            ex:g1 { ex:s ex:p
            """,
            isComplete: true
        )
    )
    .artifactRenderer(TriGRenderer())
    .padding()
    .frame(width: 420, height: 360)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("tg3"),
        type: .trig,
        title: "Streaming named graphs",
        fullPayload: """
        @prefix ex: <http://example.org/> .
        ex:friends {
            ex:alice ex:knows ex:bob .
            ex:bob ex:knows ex:carol .
            ex:carol ex:knows ex:dave .
        }
        ex:facts {
            ex:alice ex:name "Alice" .
            ex:bob ex:name "Bob" .
        }
        """,
        chunkSize: 8,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(TriGRenderer())
    .padding()
    .frame(width: 520, height: 460)
}

// MARK: - Group previews
//
// TriG carries graph attribution in the `GRAPH { ... }` block syntax, so the
// `.namedGraphs` grouping strategy can derive group membership directly from
// the parsed payload — the only TriG-content-driven grouping the layout
// supports today.

#Preview("Group — namedGraphs (3 disjoint graphs)") {
    KnowledgeGraphView(
        graph: triGPreviewGraph(
            """
            @prefix ex: <http://example.org/> .
            ex:engineering {
                ex:alice ex:knows ex:bob .
                ex:bob ex:knows ex:carol .
                ex:alice ex:knows ex:carol .
            }
            ex:sales {
                ex:dave ex:knows ex:eve .
                ex:eve ex:knows ex:frank .
            }
            ex:management {
                ex:grace ex:knows ex:henry .
                ex:henry ex:knows ex:ivy .
                ex:grace ex:knows ex:ivy .
            }
            """,
            scope: "trig-group-namedGraphs-disjoint"
        ),
        groupingStrategy: .namedGraphs()
    )
    .frame(width: 640, height: 480)
}

#Preview("Group — namedGraphs (bridged by cross-graph edge)") {
    KnowledgeGraphView(
        graph: triGPreviewGraph(
            """
            @prefix ex: <http://example.org/> .
            ex:team_a {
                ex:alice ex:knows ex:bob .
                ex:bob ex:knows ex:carol .
            }
            ex:team_b {
                ex:dave ex:knows ex:eve .
                ex:eve ex:knows ex:frank .
            }
            ex:bridge {
                ex:carol ex:partnerOf ex:dave .
            }
            """,
            scope: "trig-group-namedGraphs-bridged"
        ),
        groupingStrategy: .namedGraphs()
    )
    .frame(width: 640, height: 480)
}

#Preview("Nested groups — .explicit (company ⊇ team ⊇ core)") {
    // Three-level pseudo-hierarchy via subset membership. The outer bbox
    // contains all five cards; the middle group is a 3-card subset; the
    // innermost is a 2-card subset. Rendered in array order so the parent
    // tint sits beneath child tints — the overlap darkens to convey depth.
    let alice = NodeIdentifier.iri("http://example.org/alice")
    let bob = NodeIdentifier.iri("http://example.org/bob")
    let carol = NodeIdentifier.iri("http://example.org/carol")
    let dave = NodeIdentifier.iri("http://example.org/dave")
    let eve = NodeIdentifier.iri("http://example.org/eve")
    return KnowledgeGraphView(
        graph: triGPreviewGraph(
            """
            @prefix ex: <http://example.org/> .
            ex:default {
                ex:alice ex:knows ex:bob .
                ex:bob ex:knows ex:carol .
                ex:carol ex:knows ex:dave .
                ex:dave ex:knows ex:eve .
                ex:eve ex:knows ex:alice .
            }
            """,
            scope: "trig-nested-explicit"
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

private func triGPreviewGraph(
    _ payload: String,
    scope: String
) -> KnowledgeGraph {
    do {
        return try KnowledgeGraphFormat.trig.parse(payload, scope: scope, baseIRI: nil)
    } catch {
        fatalError("TriG preview parse failure (\(scope)): \(error)")
    }
}
