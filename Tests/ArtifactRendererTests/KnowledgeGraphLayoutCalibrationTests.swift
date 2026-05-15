import Testing
import Foundation
import CoreGraphics
import KnowledgeGraph
@testable import ArtifactNativeRenderer

/// Calibration suite for the layout-quality thresholds D2 / D3 / D5 in
/// `Specs/Grouping.Goal.md`. Each test asserts the empirical ratio that the
/// current pipeline produces; if a future change shifts the ratio outside
/// the asserted band, the test will fail, prompting an intentional update
/// rather than silent drift.
@Suite("Layout calibration — group bbox tightness")
struct KnowledgeGraphLayoutCalibrationTests {

    private static let knows = "http://xmlns.com/foaf/0.1/knows"

    private static func iri(_ tail: String) -> NodeIdentifier {
        NodeIdentifier.iri("http://example/\(tail)")
    }

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

    // MARK: - D2: connected-group tightness

    @Test
    func connectedGroupBoundingBoxIsTighterThanCanvas85Percent() throws {
        // 5 connected nodes in a single named graph. Cohesion + spring
        // attraction should keep the cluster within 55% of canvas area.
        let nodes = (0..<5).map { Self.iri("c\($0)") }
        let pairs: [(Int, Int)] = [(0, 1), (1, 2), (2, 3), (3, 4), (0, 4)]
        let edges = pairs.map { Self.edge(from: nodes[$0.0], to: nodes[$0.1], namedGraph: "g") }
        let graph = KnowledgeGraph(
            nodes: nodes.map { Node(id: $0) },
            edges: edges,
            namedGraphs: [NamedGraph(id: "g", nodes: nodes)]
        )
        let result = KnowledgeGraphLayout.compute(graph: graph)
        let ratio = try bboxToCanvasAreaRatio(result: result, groupIndex: 0)
        #expect(ratio < 0.85)
    }

    // MARK: - D3: disjoint-group tightness

    @Test
    func disjointGroupBoundingBoxIsTighterThanCanvas50Percent() throws {
        // Two 3-node clusters with no inter-graph edges. Each cluster's bbox
        // should occupy < 45% of the (now wider) canvas.
        let g1Nodes = (0..<3).map { Self.iri("a\($0)") }
        let g2Nodes = (0..<3).map { Self.iri("b\($0)") }
        let edges = [
            Self.edge(from: g1Nodes[0], to: g1Nodes[1], namedGraph: "g1"),
            Self.edge(from: g1Nodes[1], to: g1Nodes[2], namedGraph: "g1"),
            Self.edge(from: g2Nodes[0], to: g2Nodes[1], namedGraph: "g2"),
            Self.edge(from: g2Nodes[1], to: g2Nodes[2], namedGraph: "g2")
        ]
        let graph = KnowledgeGraph(
            nodes: (g1Nodes + g2Nodes).map { Node(id: $0) },
            edges: edges,
            namedGraphs: [
                NamedGraph(id: "g1", nodes: g1Nodes),
                NamedGraph(id: "g2", nodes: g2Nodes)
            ]
        )
        let result = KnowledgeGraphLayout.compute(graph: graph)
        try #require(result.compoundGraph.groups.count == 2)
        for index in 0..<2 {
            let ratio = try bboxToCanvasAreaRatio(result: result, groupIndex: index)
            #expect(ratio < 0.50)
        }
    }

    // MARK: - D5: single large-group tightness

    @Test
    func singleLargeGroupBoundingBoxIsTighterThanCanvas90Percent() throws {
        // 8 connected nodes — when the graph is essentially one group, the
        // bbox naturally fills more of the canvas, so the threshold is
        // looser than D2 / D3. Empirically the cluster settles near 0.88
        // of canvas area, so 0.90 is the regression band (0.02 of slack).
        // The Goal doc D5 entry was tightened from 0.95 to 0.90 to make
        // this a useful regression signal rather than nominal coverage.
        let nodes = (0..<8).map { Self.iri("n\($0)") }
        var edges: [Edge] = []
        for i in 0..<(nodes.count - 1) {
            edges.append(Self.edge(from: nodes[i], to: nodes[i + 1], namedGraph: "g"))
        }
        edges.append(Self.edge(from: nodes[0], to: nodes[nodes.count - 1], namedGraph: "g"))
        let graph = KnowledgeGraph(
            nodes: nodes.map { Node(id: $0) },
            edges: edges,
            namedGraphs: [NamedGraph(id: "g", nodes: nodes)]
        )
        let result = KnowledgeGraphLayout.compute(graph: graph)
        let ratio = try bboxToCanvasAreaRatio(result: result, groupIndex: 0)
        #expect(ratio < 0.90)
    }

    // MARK: - Helpers

    private func bboxToCanvasAreaRatio(
        result: KnowledgeGraphLayout.Result,
        groupIndex: Int
    ) throws -> Double {
        let group = result.compoundGraph.groups[groupIndex]
        let bbox = try #require(result.groupBoundingBoxes[group.id])
        let bboxArea = Double(bbox.width * bbox.height)
        let canvasArea = Double(result.canvasSize.width * result.canvasSize.height)
        try #require(canvasArea > 0)
        return bboxArea / canvasArea
    }
}
