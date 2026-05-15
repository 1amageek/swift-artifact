import Testing
import Foundation
import CoreGraphics
import KnowledgeGraph
@testable import ArtifactNativeRenderer

@Suite("KnowledgeGraphLayout — group geometry")
struct KnowledgeGraphLayoutGroupTests {

    private static let alice = NodeIdentifier.iri("http://example/alice")
    private static let bob = NodeIdentifier.iri("http://example/bob")
    private static let carol = NodeIdentifier.iri("http://example/carol")
    private static let dave = NodeIdentifier.iri("http://example/dave")
    private static let knows = "http://xmlns.com/foaf/0.1/knows"

    private static func edge(
        from: NodeIdentifier,
        to: NodeIdentifier,
        namedGraph: String? = nil
    ) -> Edge {
        Edge(id: EdgeIdentifier(
            source: from,
            predicate: knows,
            target: to,
            namedGraph: namedGraph
        ))
    }

    // MARK: - D1.groupBoundingBoxContainsAllMemberCards

    @Test
    func groupBoundingBoxContainsAllMemberCards() throws {
        let graph = KnowledgeGraph(
            nodes: [Node(id: Self.alice), Node(id: Self.bob), Node(id: Self.carol)],
            edges: [Self.edge(from: Self.alice, to: Self.bob, namedGraph: "g1")],
            namedGraphs: [NamedGraph(id: "g1", nodes: [Self.alice, Self.bob])]
        )
        let result = KnowledgeGraphLayout.compute(graph: graph)
        let group = try #require(result.compoundGraph.groups.first)
        let bbox = try #require(result.groupBoundingBoxes[group.id])
        for member in group.members {
            let origin = try #require(result.cardPositions[member])
            let card = try #require(result.compoundGraph.cardByID[member])
            let rect = CGRect(origin: origin, size: card.size)
            #expect(bbox.contains(rect))
        }
    }

    // MARK: - D4.disjointNamedGraphsProduceDisjointBoundingBoxes

    @Test
    func disjointNamedGraphsProduceDisjointBoundingBoxes() throws {
        // Two named graphs with no shared nodes and no cross-graph edges
        // should settle with non-overlapping bounding boxes. The cohesion
        // pull keeps each pair tight while the FR repulsion pushes the two
        // clusters apart.
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice),
                Node(id: Self.bob),
                Node(id: Self.carol),
                Node(id: Self.dave)
            ],
            edges: [
                Self.edge(from: Self.alice, to: Self.bob, namedGraph: "g1"),
                Self.edge(from: Self.carol, to: Self.dave, namedGraph: "g2")
            ],
            namedGraphs: [
                NamedGraph(id: "g1", nodes: [Self.alice, Self.bob]),
                NamedGraph(id: "g2", nodes: [Self.carol, Self.dave])
            ]
        )
        let result = KnowledgeGraphLayout.compute(graph: graph)
        try #require(result.compoundGraph.groups.count == 2)
        let a = try #require(result.groupBoundingBoxes[result.compoundGraph.groups[0].id])
        let b = try #require(result.groupBoundingBoxes[result.compoundGraph.groups[1].id])
        let intersection = a.intersection(b)
        #expect(intersection.isNull || intersection.isEmpty)
    }

    // MARK: - D7.cohesionForceDoesNotProduceNaN

    @Test
    func cohesionForceDoesNotProduceNaN() {
        // Aggressive cohesion strength on a non-trivial graph — every card
        // position must remain finite.
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice),
                Node(id: Self.bob),
                Node(id: Self.carol),
                Node(id: Self.dave)
            ],
            edges: [
                Self.edge(from: Self.alice, to: Self.bob, namedGraph: "g1"),
                Self.edge(from: Self.carol, to: Self.dave, namedGraph: "g2")
            ],
            namedGraphs: [
                NamedGraph(id: "g1", nodes: [Self.alice, Self.bob]),
                NamedGraph(id: "g2", nodes: [Self.carol, Self.dave])
            ]
        )
        let result = KnowledgeGraphLayout.compute(
            graph: graph,
            groupingStrategy: .namedGraphs(cohesionStrength: 0.4)
        )
        for (_, point) in result.cardPositions {
            #expect(point.x.isFinite)
            #expect(point.y.isFinite)
        }
    }

    // MARK: - D6.groupBoundingBoxesAreFiniteAcrossStrategies

    @Test
    func groupBoundingBoxesAreFiniteAcrossStrategies() {
        // Whatever strategy is in play, every computed bounding box must have
        // finite minX / minY / width / height. A NaN or Inf here would crash
        // the renderer's affine transforms downstream.
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice, types: ["http://example/Person"]),
                Node(id: Self.bob, types: ["http://example/Person"]),
                Node(id: Self.carol, types: ["http://example/Employee"]),
                Node(id: Self.dave)
            ],
            edges: [
                Self.edge(from: Self.alice, to: Self.bob, namedGraph: "g1"),
                Self.edge(from: Self.carol, to: Self.dave, namedGraph: "g2")
            ],
            namespaces: [
                Namespace(prefix: "ex", uri: "http://example/")
            ],
            namedGraphs: [
                NamedGraph(id: "g1", nodes: [Self.alice, Self.bob]),
                NamedGraph(id: "g2", nodes: [Self.carol, Self.dave])
            ]
        )
        let strategies: [GroupingStrategy] = [
            .namedGraphs(),
            .byType(),
            .byNamespace(),
            .combined(strategies: [.namedGraphs(), .byType(), .byNamespace()])
        ]
        for strategy in strategies {
            let result = KnowledgeGraphLayout.compute(graph: graph, groupingStrategy: strategy)
            for (_, bbox) in result.groupBoundingBoxes {
                #expect(bbox.minX.isFinite)
                #expect(bbox.minY.isFinite)
                #expect(bbox.width.isFinite)
                #expect(bbox.height.isFinite)
                #expect(bbox.width >= 0)
                #expect(bbox.height >= 0)
            }
        }
    }

    // MARK: - D7.boundingBoxIsFiniteForSingleMemberGroup

    @Test
    func boundingBoxIsFiniteForSingleMemberGroup() throws {
        // A group with one member is allowed — cohesion is skipped (single
        // members have a degenerate centroid) but the bbox is still drawn.
        let graph = KnowledgeGraph(
            nodes: [Node(id: Self.alice)],
            namedGraphs: [NamedGraph(id: "g1", nodes: [Self.alice])]
        )
        let result = KnowledgeGraphLayout.compute(graph: graph)
        let group = try #require(result.compoundGraph.groups.first)
        let bbox = try #require(result.groupBoundingBoxes[group.id])
        #expect(bbox.minX.isFinite)
        #expect(bbox.minY.isFinite)
        #expect(bbox.width.isFinite)
        #expect(bbox.height.isFinite)
    }
}
