import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView
import KnowledgeGraph

/// Renders `application/n-quads` artifacts as a force-directed diagram.
///
/// N-Quads is strictly line-delimited (`subject predicate object [graph] .`),
/// so a per-line streaming attempt — try parsing each accumulated prefix —
/// surfaces parseable subsets as soon as a complete line arrives.
public struct NQuadsRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .nQuads
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        if KnowledgeGraphFormat.nQuads.hasRenderablePartial(
            artifact.payload,
            baseIRI: artifact.attributes["base"]
        ) {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first complete quad"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        KnowledgeGraphRendererBody(artifact: artifact, payload: payload, format: .nQuads)
    }
}

#Preview("Card — small N-Quads graph") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("nq1"),
            type: .nQuads,
            title: "Quads",
            payload: """
            <http://example.org/alice> <http://example.org/knows> <http://example.org/bob> <http://example.org/g1> .
            <http://example.org/bob> <http://example.org/knows> <http://example.org/carol> <http://example.org/g1> .
            <http://example.org/carol> <http://example.org/name> "Carol" .

            """,
            isComplete: true
        ),
        renderer: NQuadsRenderer()
    )
    .frame(width: 520, height: 420)
}

#Preview("Bare — malformed N-Quads → error") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("nq2"),
            type: .nQuads,
            payload: """
            <http://example.org/alice> <http://example.org/knows>
            """,
            isComplete: true
        )
    )
    .artifactRenderer(NQuadsRenderer())
    .frame(width: 420, height: 360)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("nq3"),
        type: .nQuads,
        title: "Streaming quads",
        fullPayload: """
        <http://example.org/alice> <http://example.org/knows> <http://example.org/bob> <http://example.org/g1> .
        <http://example.org/bob> <http://example.org/knows> <http://example.org/carol> <http://example.org/g1> .
        <http://example.org/carol> <http://example.org/knows> <http://example.org/dave> <http://example.org/g1> .
        <http://example.org/alice> <http://example.org/name> "Alice" .
        <http://example.org/bob> <http://example.org/name> "Bob" .
        <http://example.org/carol> <http://example.org/name> "Carol" .

        """,
        chunkSize: 12,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(NQuadsRenderer())
    .frame(width: 520, height: 460)
}

// MARK: - Group previews
//
// N-Quads is the only RDF line-format that natively carries graph attribution
// on every quad (the optional 4th token). `.namedGraphs` reads that token to
// build group membership; default triples (no 4th token) live in the default
// graph and produce no group.

#Preview("Group — namedGraphs (3 graphs from quad attribution)") {
    KnowledgeGraphView(
        graph: nQuadsPreviewGraph(
            """
            <http://example.org/alice> <http://example.org/knows> <http://example.org/bob> <http://example.org/engineering> .
            <http://example.org/bob> <http://example.org/knows> <http://example.org/carol> <http://example.org/engineering> .
            <http://example.org/alice> <http://example.org/knows> <http://example.org/carol> <http://example.org/engineering> .
            <http://example.org/dave> <http://example.org/knows> <http://example.org/eve> <http://example.org/sales> .
            <http://example.org/eve> <http://example.org/knows> <http://example.org/frank> <http://example.org/sales> .
            <http://example.org/grace> <http://example.org/knows> <http://example.org/henry> <http://example.org/management> .
            <http://example.org/henry> <http://example.org/knows> <http://example.org/ivy> <http://example.org/management> .

            """,
            scope: "nquads-group-namedGraphs-three"
        ),
        groupingStrategy: .namedGraphs()
    )
    .frame(width: 640, height: 480)
}

#Preview("Group — namedGraphs (bridged by cross-graph edge)") {
    KnowledgeGraphView(
        graph: nQuadsPreviewGraph(
            """
            <http://example.org/alice> <http://example.org/knows> <http://example.org/bob> <http://example.org/team_a> .
            <http://example.org/bob> <http://example.org/knows> <http://example.org/carol> <http://example.org/team_a> .
            <http://example.org/dave> <http://example.org/knows> <http://example.org/eve> <http://example.org/team_b> .
            <http://example.org/eve> <http://example.org/knows> <http://example.org/frank> <http://example.org/team_b> .
            <http://example.org/carol> <http://example.org/partnerOf> <http://example.org/dave> <http://example.org/bridge> .

            """,
            scope: "nquads-group-namedGraphs-bridged"
        ),
        groupingStrategy: .namedGraphs()
    )
    .frame(width: 640, height: 480)
}

#Preview("Nested groups — .explicit (company ⊇ team ⊇ core)") {
    // Three-level pseudo-hierarchy. Parent bbox is the AABB of all
    // 5 members; child / grandchild bboxes are AABBs of their subsets.
    let alice = NodeIdentifier.iri("http://example.org/alice")
    let bob = NodeIdentifier.iri("http://example.org/bob")
    let carol = NodeIdentifier.iri("http://example.org/carol")
    let dave = NodeIdentifier.iri("http://example.org/dave")
    let eve = NodeIdentifier.iri("http://example.org/eve")
    return KnowledgeGraphView(
        graph: nQuadsPreviewGraph(
            """
            <http://example.org/alice> <http://example.org/knows> <http://example.org/bob> .
            <http://example.org/bob> <http://example.org/knows> <http://example.org/carol> .
            <http://example.org/carol> <http://example.org/knows> <http://example.org/dave> .
            <http://example.org/dave> <http://example.org/knows> <http://example.org/eve> .
            <http://example.org/eve> <http://example.org/knows> <http://example.org/alice> .

            """,
            scope: "nquads-nested-explicit"
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

private func nQuadsPreviewGraph(
    _ payload: String,
    scope: String
) -> KnowledgeGraph {
    do {
        return try KnowledgeGraphFormat.nQuads.parse(payload, scope: scope, baseIRI: nil)
    } catch {
        fatalError("N-Quads preview parse failure (\(scope)): \(error)")
    }
}
