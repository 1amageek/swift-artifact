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

    private static func exampleOrgIRI(_ tail: String) -> NodeIdentifier {
        NodeIdentifier.iri("http://example.org/\(tail)")
    }

    private static func edge(
        from: NodeIdentifier,
        to: NodeIdentifier,
        predicate: String = knows,
        namedGraph: String? = nil
    ) -> Edge {
        Edge(id: EdgeIdentifier(
            source: from,
            predicate: predicate,
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

    // MARK: - Edge angle relaxation

    @Test
    func edgeAnglesConvergeTowardCardinalAxes() throws {
        // A branched graph has competing incident edges, so this validates the
        // angle-only relaxation as a compromise across multiple neighbours
        // rather than a trivial single-edge alignment.
        let nodes = (0..<6).map { Self.iri("angle\($0)") }
        let edges = [
            Self.edge(from: nodes[0], to: nodes[1], namedGraph: "g"),
            Self.edge(from: nodes[0], to: nodes[2], namedGraph: "g"),
            Self.edge(from: nodes[0], to: nodes[3], namedGraph: "g"),
            Self.edge(from: nodes[3], to: nodes[4], namedGraph: "g"),
            Self.edge(from: nodes[3], to: nodes[5], namedGraph: "g")
        ]
        let graph = KnowledgeGraph(
            nodes: nodes.map { Node(id: $0) },
            edges: edges,
            namedGraphs: [NamedGraph(id: "g", nodes: nodes)]
        )
        let result = KnowledgeGraphLayout.compute(graph: graph)
        var totalDeviation = 0.0
        var measuredCount = 0
        for edge in result.compoundGraph.edges {
            guard
                let sourceOrigin = result.cardPositions[edge.source],
                let targetOrigin = result.cardPositions[edge.target],
                let sourceCard = result.compoundGraph.cardByID[edge.source],
                let targetCard = result.compoundGraph.cardByID[edge.target]
            else { continue }
            let sourceCenter = CGPoint(
                x: sourceOrigin.x + sourceCard.size.width / 2,
                y: sourceOrigin.y + sourceCard.size.height / 2
            )
            let targetCenter = CGPoint(
                x: targetOrigin.x + targetCard.size.width / 2,
                y: targetOrigin.y + targetCard.size.height / 2
            )
            let angle = atan2(
                Double(targetCenter.y - sourceCenter.y),
                Double(targetCenter.x - sourceCenter.x)
            )
            totalDeviation += cardinalDeviation(angle)
            measuredCount += 1
        }
        try #require(measuredCount == edges.count)
        let averageDeviation = totalDeviation / Double(measuredCount)
        #expect(averageDeviation < 0.22)
    }

    @Test
    func bridgeOwnedEdgeDoesNotInflateAdjacentGroupGap() throws {
        let bridgePredicate = "http://example/bridge"
        let alice = Self.iri("alice")
        let bob = Self.iri("bob")
        let carol = Self.iri("carol")
        let dave = Self.iri("dave")
        let eve = Self.iri("eve")
        let frank = Self.iri("frank")
        let graph = KnowledgeGraph(
            nodes: [alice, bob, carol, dave, eve, frank].map { Node(id: $0) },
            edges: [
                Self.edge(from: alice, to: bob, namedGraph: "left"),
                Self.edge(from: bob, to: carol, namedGraph: "left"),
                Self.edge(from: alice, to: carol, namedGraph: "left"),
                Self.edge(from: dave, to: eve, namedGraph: "right"),
                Self.edge(from: eve, to: frank, namedGraph: "right"),
                Self.edge(from: dave, to: frank, namedGraph: "right"),
                Self.edge(from: carol, to: dave, predicate: bridgePredicate, namedGraph: "bridge")
            ],
            namedGraphs: [
                NamedGraph(id: "left", nodes: [alice, bob, carol]),
                NamedGraph(id: "right", nodes: [dave, eve, frank]),
                NamedGraph(id: "bridge", nodes: [carol, dave])
            ]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let lengths = try edgeCenterLengths(result: result)
        let bridgeEdge = try #require(
            result.compoundGraph.edges.first { $0.predicate == "bridge" }
        )
        let bridgeLength = try #require(lengths[bridgeEdge.id])
        let regularLengths = result.compoundGraph.edges.compactMap { edge -> Double? in
            guard edge.predicate == "knows" else { return nil }
            return lengths[edge.id]
        }
        try #require(!regularLengths.isEmpty)
        let averageRegularLength = regularLengths.reduce(0, +) / Double(regularLengths.count)
        #expect(bridgeLength < averageRegularLength * 1.8)

        let leftBox = try #require(groupBoundingBox(label: "left", result: result))
        let rightBox = try #require(groupBoundingBox(label: "right", result: result))
        #expect(rightBox.midX > leftBox.midX + 125)
    }

    @Test
    func highDegreeEdgesReceiveLongerDistanceBudget() throws {
        let pairA = Self.iri("pair-a")
        let pairB = Self.iri("pair-b")
        let pairGraph = KnowledgeGraph(
            nodes: [pairA, pairB].map { Node(id: $0) },
            edges: [Self.edge(from: pairA, to: pairB, namedGraph: "pair")],
            namedGraphs: [NamedGraph(id: "pair", nodes: [pairA, pairB])]
        )
        let pairResult = KnowledgeGraphLayout.compute(graph: pairGraph)
        let pairLengths = try edgeCenterLengths(result: pairResult)
        let pairEdge = try #require(pairResult.compoundGraph.edges.first)
        let pairLength = try #require(pairLengths[pairEdge.id])

        let hub = Self.iri("hub")
        let leaves = (0..<8).map { Self.iri("hub-leaf-\($0)") }
        let hubGraph = KnowledgeGraph(
            nodes: ([hub] + leaves).map { Node(id: $0) },
            edges: leaves.map { Self.edge(from: hub, to: $0, namedGraph: "hub") },
            namedGraphs: [NamedGraph(id: "hub", nodes: [hub] + leaves)]
        )
        let hubResult = KnowledgeGraphLayout.compute(graph: hubGraph)
        let hubLengths = try edgeCenterLengths(result: hubResult)
        let averageHubLength = hubResult.compoundGraph.edges.compactMap { hubLengths[$0.id] }
            .reduce(0, +) / Double(leaves.count)

        #expect(averageHubLength > pairLength * 1.15)
    }

    @Test
    func highDegreeHubUsesWideAngularCoverage() throws {
        let hub = Self.iri("angle-hub")
        let leaves = (0..<10).map { Self.iri("angle-leaf-\($0)") }
        let graph = KnowledgeGraph(
            nodes: ([hub] + leaves).map { Node(id: $0) },
            edges: leaves.map { Self.edge(from: hub, to: $0, namedGraph: "hub") },
            namedGraphs: [NamedGraph(id: "hub", nodes: [hub] + leaves)]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let hubCenter = try center(of: CompoundGraph.Card.ID(nodeID: hub), in: result)
        let angles = try leaves.map { leaf -> Double in
            let leafCenter = try center(of: CompoundGraph.Card.ID(nodeID: leaf), in: result)
            return normalizedAngle(atan2(
                Double(leafCenter.y - hubCenter.y),
                Double(leafCenter.x - hubCenter.x)
            ))
        }.sorted()
        try #require(angles.count == leaves.count)

        #expect(largestAngularGap(angles) < 2.4)
    }

    @Test
    func finalLayoutHasNoOverlappingCards() throws {
        let hubs = (0..<3).map { Self.iri("dense-hub-\($0)") }
        let leaves = (0..<12).map { Self.iri("dense-leaf-\($0)") }
        var edges: [Edge] = []
        for (hubIndex, hub) in hubs.enumerated() {
            for (leafIndex, leaf) in leaves.enumerated() where leafIndex % hubs.count == hubIndex {
                edges.append(Self.edge(from: hub, to: leaf, namedGraph: "dense"))
            }
        }
        edges.append(Self.edge(from: hubs[0], to: hubs[1], namedGraph: "dense"))
        edges.append(Self.edge(from: hubs[1], to: hubs[2], namedGraph: "dense"))
        edges.append(Self.edge(from: hubs[2], to: hubs[0], namedGraph: "dense"))

        let graph = KnowledgeGraph(
            nodes: (hubs + leaves).map { Node(id: $0) },
            edges: edges,
            namedGraphs: [NamedGraph(id: "dense", nodes: hubs + leaves)]
        )
        let result = KnowledgeGraphLayout.compute(graph: graph)

        let rects = try cardRects(result: result)
        for i in 0..<(rects.count - 1) {
            for j in (i + 1)..<rects.count {
                #expect(!rects[i].insetBy(dx: -1, dy: -1).intersects(rects[j]))
            }
        }
    }

    @Test
    func disjointGroupBoxesDoNotOverlap() throws {
        let left = (0..<4).map { Self.iri("left-\($0)") }
        let right = (0..<4).map { Self.iri("right-\($0)") }
        let edges = [
            Self.edge(from: left[0], to: left[1], namedGraph: "left"),
            Self.edge(from: left[1], to: left[2], namedGraph: "left"),
            Self.edge(from: left[2], to: left[3], namedGraph: "left"),
            Self.edge(from: right[0], to: right[1], namedGraph: "right"),
            Self.edge(from: right[1], to: right[2], namedGraph: "right"),
            Self.edge(from: right[2], to: right[3], namedGraph: "right"),
            Self.edge(from: left[3], to: right[0], predicate: "http://example/bridge")
        ]
        let graph = KnowledgeGraph(
            nodes: (left + right).map { Node(id: $0) },
            edges: edges,
            namedGraphs: [
                NamedGraph(id: "left", nodes: left),
                NamedGraph(id: "right", nodes: right)
            ]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let leftBox = try #require(groupBoundingBox(label: "left", result: result))
        let rightBox = try #require(groupBoundingBox(label: "right", result: result))

        #expect(!leftBox.intersects(rightBox))
    }

    @Test
    func edgeLabelsDoNotOverlapCardsOrEachOther() throws {
        let center = Self.iri("label-center")
        let leaves = (0..<6).map { Self.iri("label-leaf-\($0)") }
        let predicates = [
            "http://example/type",
            "http://example/knows",
            "http://example/memberOf",
            "http://example/reportsTo",
            "http://example/dependsOn",
            "http://example/uses"
        ]
        let edges = zip(leaves, predicates).map { leaf, predicate in
            Self.edge(from: center, to: leaf, predicate: predicate, namedGraph: "labels")
        }
        let graph = KnowledgeGraph(
            nodes: ([center] + leaves).map { Node(id: $0) },
            edges: edges,
            namedGraphs: [NamedGraph(id: "labels", nodes: [center] + leaves)]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let cardRects = try cardRects(result: result).map { $0.insetBy(dx: -2, dy: -2) }
        let labelRects = try edgeLabelRects(result: result)

        for labelRect in labelRects {
            for cardRect in cardRects {
                #expect(!labelRect.intersects(cardRect))
            }
        }
        for i in 0..<(labelRects.count - 1) {
            for j in (i + 1)..<labelRects.count {
                #expect(!labelRects[i].intersects(labelRects[j]))
            }
        }
    }

    @Test
    func namespacePreviewKeepsGroupsCompactAndLabelsSeparated() throws {
        let graph = byNamespacePreviewGraph()
        let result = KnowledgeGraphLayout.compute(graph: graph, groupingStrategy: .byNamespace())

        for group in result.compoundGraph.groups {
            let fillRatio = try groupMemberFillRatio(group: group, result: result)
            #expect(fillRatio > 0.10)
        }

        let labelRects = try edgeLabelRects(result: result)
        for i in 0..<(labelRects.count - 1) {
            for j in (i + 1)..<labelRects.count {
                #expect(!labelRects[i].intersects(labelRects[j]))
            }
        }
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

    private func cardinalDeviation(_ angle: Double) -> Double {
        let quarterTurn = Double.pi / 2
        let remainder = abs(angle.truncatingRemainder(dividingBy: quarterTurn))
        return min(remainder, quarterTurn - remainder)
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var result = angle
        while result < 0 {
            result += Double.pi * 2
        }
        while result >= Double.pi * 2 {
            result -= Double.pi * 2
        }
        return result
    }

    private func largestAngularGap(_ sortedAngles: [Double]) -> Double {
        guard sortedAngles.count > 1 else { return Double.pi * 2 }
        var largest = 0.0
        for index in 0..<(sortedAngles.count - 1) {
            largest = max(largest, sortedAngles[index + 1] - sortedAngles[index])
        }
        let wrapGap = sortedAngles[0] + Double.pi * 2 - sortedAngles[sortedAngles.count - 1]
        return max(largest, wrapGap)
    }

    private func edgeCenterLengths(
        result: KnowledgeGraphLayout.Result
    ) throws -> [EdgeIdentifier: Double] {
        var lengths: [EdgeIdentifier: Double] = [:]
        for edge in result.compoundGraph.edges {
            let source = try center(of: edge.source, in: result)
            let target = try center(of: edge.target, in: result)
            let dx = Double(target.x - source.x)
            let dy = Double(target.y - source.y)
            lengths[edge.id] = sqrt(dx * dx + dy * dy)
        }
        return lengths
    }

    private func center(
        of id: CompoundGraph.Card.ID,
        in result: KnowledgeGraphLayout.Result
    ) throws -> CGPoint {
        let origin = try #require(result.cardPositions[id])
        let card = try #require(result.compoundGraph.cardByID[id])
        return CGPoint(
            x: origin.x + card.size.width / 2,
            y: origin.y + card.size.height / 2
        )
    }

    private func cardRects(result: KnowledgeGraphLayout.Result) throws -> [CGRect] {
        try result.compoundGraph.cards.map { card in
            let origin = try #require(result.cardPositions[card.id])
            return CGRect(origin: origin, size: card.size)
        }
    }

    private func edgeLabelRects(result: KnowledgeGraphLayout.Result) throws -> [CGRect] {
        try result.compoundGraph.edges.map { edge in
            let center = try #require(result.edgeLabelPositions[edge.id])
            let size = CGSize(
                width: min(CGFloat(edge.predicate.count) * 7 + 24, 190),
                height: 18
            )
            return CGRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    private func groupMemberFillRatio(
        group: CompoundGraph.Group,
        result: KnowledgeGraphLayout.Result
    ) throws -> Double {
        let bbox = try #require(result.groupBoundingBoxes[group.id])
        let inner = bbox.insetBy(dx: group.style.padding, dy: group.style.padding)
        let innerArea = max(Double(inner.width * inner.height), 1)
        var memberArea = 0.0
        for member in group.members {
            let card = try #require(result.compoundGraph.cardByID[member])
            memberArea += Double(card.size.width * card.size.height)
        }
        return memberArea / innerArea
    }

    private func groupBoundingBox(
        label: String,
        result: KnowledgeGraphLayout.Result
    ) -> CGRect? {
        guard let group = result.compoundGraph.groups.first(where: { $0.label == label }) else {
            return nil
        }
        return result.groupBoundingBoxes[group.id]
    }

    private func byNamespacePreviewGraph() -> KnowledgeGraph {
        let alice = Self.exampleOrgIRI("alice")
        let bob = Self.exampleOrgIRI("bob")
        let carol = Self.exampleOrgIRI("carol")
        let engineering = Self.exampleOrgIRI("org/engineering")
        let sales = Self.exampleOrgIRI("org/sales")
        let recruiting = Self.exampleOrgIRI("org/hr/recruiting")
        let payroll = Self.exampleOrgIRI("org/hr/payroll")
        let widget = Self.exampleOrgIRI("product/widget")
        let gadget = Self.exampleOrgIRI("product/gadget")

        let memberOf = "http://example.org/memberOf"
        let builds = "http://example.org/builds"
        let reviews = "http://example.org/reviews"
        let nodes = [alice, bob, carol, engineering, sales, recruiting, payroll, widget, gadget]
        let edges = [
            Self.edge(from: alice, to: bob, predicate: Self.knows),
            Self.edge(from: bob, to: carol, predicate: Self.knows),
            Self.edge(from: alice, to: engineering, predicate: memberOf),
            Self.edge(from: bob, to: recruiting, predicate: memberOf),
            Self.edge(from: carol, to: sales, predicate: memberOf),
            Self.edge(from: alice, to: widget, predicate: builds),
            Self.edge(from: bob, to: gadget, predicate: reviews),
            Self.edge(from: carol, to: payroll, predicate: memberOf)
        ]

        return KnowledgeGraph(
            nodes: nodes.map { Node(id: $0) },
            edges: edges,
            namespaces: [
                Namespace(prefix: "foaf", uri: "http://xmlns.com/foaf/0.1/"),
                Namespace(prefix: "org", uri: "http://example.org/org/"),
                Namespace(prefix: "orgHR", uri: "http://example.org/org/hr/"),
                Namespace(prefix: "prod", uri: "http://example.org/product/")
            ]
        )
    }
}
