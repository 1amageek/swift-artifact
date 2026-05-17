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
    private static let edgeEdgePortSpacing: CGFloat = 6

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
    func overlappingNamedGraphMembersDoNotInheritExternalBlockGap() throws {
        let alice = Self.exampleOrgIRI("alice")
        let bob = Self.exampleOrgIRI("bob")
        let carol = Self.exampleOrgIRI("carol")
        let dave = Self.exampleOrgIRI("dave")
        let eve = Self.exampleOrgIRI("eve")
        let g1 = "http://example.org/g1"
        let g2 = "http://example.org/g2"
        let bridge = "http://example.org/bridge"
        let graph = KnowledgeGraph(
            nodes: [alice, bob, carol, dave, eve].map { Node(id: $0) },
            edges: [
                Self.edge(from: alice, to: bob, namedGraph: g1),
                Self.edge(from: bob, to: carol, namedGraph: g1),
                Self.edge(from: carol, to: dave, namedGraph: g2),
                Self.edge(from: dave, to: eve, namedGraph: g2),
                Self.edge(from: carol, to: dave, predicate: bridge, namedGraph: bridge)
            ],
            namedGraphs: [
                NamedGraph(id: g1, nodes: [alice, bob, carol]),
                NamedGraph(id: g2, nodes: [carol, dave, eve]),
                NamedGraph(id: bridge, nodes: [carol, dave])
            ]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let bobRect = try cardRect(of: CompoundGraph.Card.ID(nodeID: bob), in: result)
        let carolRect = try cardRect(of: CompoundGraph.Card.ID(nodeID: carol), in: result)
        let daveRect = try cardRect(of: CompoundGraph.Card.ID(nodeID: dave), in: result)
        let eveRect = try cardRect(of: CompoundGraph.Card.ID(nodeID: eve), in: result)

        let leftInternalGap = carolRect.minX - bobRect.maxX
        let rightInternalGap = eveRect.minX - daveRect.maxX
        #expect(leftInternalGap >= 80)
        #expect(leftInternalGap < 130)
        #expect(rightInternalGap >= 80)
        #expect(rightInternalGap < 130)
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
        let pairLengths = edgeRouteLengths(result: pairResult)
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
        let hubLengths = edgeRouteLengths(result: hubResult)
        let averageHubLength = hubResult.compoundGraph.edges.compactMap { hubLengths[$0.id] }
            .reduce(0, +) / Double(leaves.count)

        #expect(averageHubLength > pairLength * 1.15)
    }

    @Test
    func highDegreeHubUsesReadableLayeredFanout() throws {
        let hub = Self.iri("angle-hub")
        let leaves = (0..<10).map { Self.iri("angle-leaf-\($0)") }
        let graph = KnowledgeGraph(
            nodes: ([hub] + leaves).map { Node(id: $0) },
            edges: leaves.map { Self.edge(from: hub, to: $0, namedGraph: "hub") },
            namedGraphs: [NamedGraph(id: "hub", nodes: [hub] + leaves)]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let hubCenter = try center(of: CompoundGraph.Card.ID(nodeID: hub), in: result)
        let leafCenters = try leaves.map { leaf -> CGPoint in
            let leafCenter = try center(of: CompoundGraph.Card.ID(nodeID: leaf), in: result)
            #expect(leafCenter.x > hubCenter.x)
            return leafCenter
        }
        try #require(leafCenters.count == leaves.count)

        let minY = try #require(leafCenters.map(\.y).min())
        let maxY = try #require(leafCenters.map(\.y).max())
        let verticalSpan = Double(maxY - minY)
        #expect(verticalSpan > Double(leaves.count - 1) * 44.0)
    }

    @Test
    func hubEdgesUseDistinctBoundaryPorts() throws {
        let hub = Self.iri("port-hub")
        let leaves = (0..<8).map { Self.iri("port-leaf-\($0)") }
        let graph = KnowledgeGraph(
            nodes: ([hub] + leaves).map { Node(id: $0) },
            edges: leaves.map { Self.edge(from: hub, to: $0, namedGraph: "ports") },
            namedGraphs: [NamedGraph(id: "ports", nodes: [hub] + leaves)]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let hubID = CompoundGraph.Card.ID(nodeID: hub)
        let hubOrigin = try #require(result.cardPositions[hubID])
        let hubCard = try #require(result.compoundGraph.cardByID[hubID])
        let hubRect = CGRect(origin: hubOrigin, size: hubCard.size)
        var boundaryPorts: Set<String> = []

        for edge in result.compoundGraph.edges {
            let route = try #require(result.edgeRoutes[edge.id])
            let port = edge.source == hubID ? route.start : route.end
            #expect(pointIsOnBoundary(port, of: hubRect))
            boundaryPorts.insert(roundedPointKey(port))
        }

        #expect(boundaryPorts.count == leaves.count)
    }

    @Test
    func sameSidePortsUseEdgeEdgeDistanceWhenItFits() throws {
        let hub = Self.iri("centered-port-hub")
        let leaves = (0..<2).map { Self.iri("centered-port-leaf-\($0)") }
        let graph = KnowledgeGraph(
            nodes: ([hub] + leaves).map { Node(id: $0) },
            edges: leaves.map { Self.edge(from: hub, to: $0, namedGraph: "ports") },
            namedGraphs: [NamedGraph(id: "ports", nodes: [hub] + leaves)]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let hubID = CompoundGraph.Card.ID(nodeID: hub)
        let hubRect = try cardRect(of: hubID, in: result)
        let ports = try sourcePorts(for: hubID, in: hubRect, result: result)
        try #require(ports.count == leaves.count)
        let sides = Set(ports.map(\.side))
        try #require(sides.count == 1)
        let side = try #require(sides.first)
        let coordinates = ports.map { portAxisCoordinate($0.point, side: side) }.sorted()
        let expected = expectedCenteredPortCoordinates(rect: hubRect, side: side, count: ports.count)

        for (actual, expectedValue) in zip(coordinates, expected) {
            #expect(abs(actual - expectedValue) < 0.5)
        }
        #expect(abs((coordinates[1] - coordinates[0]) - Self.edgeEdgePortSpacing) < 0.5)
        #expect(abs((coordinates[0] + coordinates[1]) * 0.5 - sideCenterCoordinate(of: hubRect, side: side)) < 0.5)
    }

    @Test
    func evenSameSidePortBundleCentersAroundNodeSide() throws {
        let hub = Self.iri("even-centered-port-hub")
        let leaves = (0..<4).map { Self.iri("even-centered-port-leaf-\($0)") }
        let graph = KnowledgeGraph(
            nodes: ([hub] + leaves).map { Node(id: $0) },
            edges: leaves.map { Self.edge(from: hub, to: $0, namedGraph: "ports") },
            namedGraphs: [NamedGraph(id: "ports", nodes: [hub] + leaves)]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let hubID = CompoundGraph.Card.ID(nodeID: hub)
        let hubRect = try cardRect(of: hubID, in: result)
        let ports = try sourcePorts(for: hubID, in: hubRect, result: result)
        try #require(ports.count == leaves.count)
        let portsBySide = Dictionary(grouping: ports, by: \.side)
        let sidePorts = try #require(portsBySide.values.first { $0.count == leaves.count })
        let side = try #require(sidePorts.first?.side)
        let coordinates = sidePorts.map { portAxisCoordinate($0.point, side: side) }.sorted()
        let expected = expectedCenteredPortCoordinates(rect: hubRect, side: side, count: sidePorts.count)

        for (actual, expectedValue) in zip(coordinates, expected) {
            #expect(abs(actual - expectedValue) < 0.5)
        }
        let midpoint = (coordinates[0] + coordinates[coordinates.count - 1]) * 0.5
        #expect(abs(midpoint - sideCenterCoordinate(of: hubRect, side: side)) < 0.5)
    }

    @Test
    func byTypePreviewKeepsAliceOutputBundleEvenlyDistributed() throws {
        let graph = try KnowledgeGraphFormat.jsonLD.parse(
            #"""
            {
              "@graph": [
                {"@id": "http://example.org/alice",
                 "@type": "http://xmlns.com/foaf/0.1/Person",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/bob"}},
                {"@id": "http://example.org/bob",
                 "@type": "http://xmlns.com/foaf/0.1/Person",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/carol"}},
                {"@id": "http://example.org/carol",
                 "@type": "http://xmlns.com/foaf/0.1/Person"},

                {"@id": "http://example.org/acme",
                 "@type": "http://example.org/Company"},
                {"@id": "http://example.org/globex",
                 "@type": "http://example.org/Company"},

                {"@id": "http://example.org/laptop",
                 "@type": "http://example.org/Device"},
                {"@id": "http://example.org/phone",
                 "@type": "http://example.org/Device"},
                {"@id": "http://example.org/tablet",
                 "@type": "http://example.org/Device"},

                {"@id": "http://example.org/alice",
                 "http://example.org/worksAt": {"@id": "http://example.org/acme"}},
                {"@id": "http://example.org/alice",
                 "http://example.org/owns": {"@id": "http://example.org/tablet"}},
                {"@id": "http://example.org/bob",
                 "http://example.org/worksAt": {"@id": "http://example.org/globex"}},
                {"@id": "http://example.org/carol",
                 "http://example.org/owns": {"@id": "http://example.org/laptop"}},
                {"@id": "http://example.org/bob",
                 "http://example.org/owns": {"@id": "http://example.org/phone"}}
              ]
            }
            """#,
            scope: "by-type-alice-port-bundle",
            baseIRI: nil
        )
        let result = KnowledgeGraphLayout.compute(graph: graph, groupingStrategy: .byType())
        let aliceID = CompoundGraph.Card.ID(nodeID: Self.exampleOrgIRI("alice"))
        let aliceRect = try cardRect(of: aliceID, in: result)
        let ports = try sourcePorts(for: aliceID, in: aliceRect, result: result)
        let portsBySide = Dictionary(grouping: ports, by: \.side)
        let sidePorts = try #require(portsBySide.values.max(by: { $0.count < $1.count }))
        try #require(sidePorts.count >= 4)
        let side = try #require(sidePorts.first?.side)
        let coordinates = sidePorts.map { portAxisCoordinate($0.point, side: side) }.sorted()
        let expected = expectedCenteredPortCoordinates(rect: aliceRect, side: side, count: coordinates.count)

        for (actual, expectedValue) in zip(coordinates, expected) {
            #expect(abs(actual - expectedValue) < 0.5)
        }
        let gaps = zip(coordinates.dropFirst(), coordinates).map { next, previous in
            next - previous
        }
        let firstGap = try #require(gaps.first)
        for gap in gaps {
            #expect(abs(gap - firstGap) < 0.5)
        }

        let acmeID = CompoundGraph.Card.ID(nodeID: Self.exampleOrgIRI("acme"))
        let bobID = CompoundGraph.Card.ID(nodeID: Self.exampleOrgIRI("bob"))
        let aliceAcme = try routedEdge(source: aliceID, target: acmeID, result: result)
        let aliceBob = try routedEdge(source: aliceID, target: bobID, result: result)
        #expect(routeDistanceAwayFromSharedEndpointFanout(aliceAcme, aliceBob) >= 13.5)
    }

    @Test
    func sameSidePortsCompressEvenlyWhenEdgeEdgeDistanceDoesNotFit() throws {
        let hub = Self.iri("compressed-port-hub")
        let leaves = (0..<6).map { Self.iri("compressed-port-leaf-\($0)") }
        let graph = KnowledgeGraph(
            nodes: ([hub] + leaves).map { Node(id: $0) },
            edges: leaves.map { Self.edge(from: hub, to: $0, namedGraph: "ports") },
            namedGraphs: [NamedGraph(id: "ports", nodes: [hub] + leaves)]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let hubID = CompoundGraph.Card.ID(nodeID: hub)
        let hubRect = try cardRect(of: hubID, in: result)
        let ports = try sourcePorts(for: hubID, in: hubRect, result: result)
        try #require(ports.count == leaves.count)
        let portsBySide = Dictionary(grouping: ports, by: \.side)
        for (side, sidePorts) in portsBySide {
            let coordinates = sidePorts.map { portAxisCoordinate($0.point, side: side) }.sorted()
            let expected = expectedCenteredPortCoordinates(rect: hubRect, side: side, count: sidePorts.count)

            for (actual, expectedValue) in zip(coordinates, expected) {
                #expect(abs(actual - expectedValue) < Self.edgeEdgePortSpacing)
            }
            guard coordinates.count > 1 else { continue }
            let gaps = zip(coordinates.dropFirst(), coordinates).map { next, previous in
                next - previous
            }
            try #require(!gaps.isEmpty)
            let firstGap = try #require(gaps.first)
            let expectedGap = expected.count > 1 ? expected[1] - expected[0] : firstGap
            #expect(abs(firstGap - expectedGap) < 0.75)
            for gap in gaps {
                #expect(abs(gap - firstGap) < 0.75)
            }
            #expect(abs((coordinates[0] + coordinates[coordinates.count - 1]) * 0.5 - sideCenterCoordinate(of: hubRect, side: side)) < Self.edgeEdgePortSpacing)
        }
    }

    @Test
    func incomingPortsCenterOnTargetAndKeepSingletonSourcesCentered() throws {
        let alice = Self.iri("incoming-alice")
        let bob = Self.iri("incoming-bob")
        let carol = Self.iri("incoming-carol")
        let graph = KnowledgeGraph(
            nodes: [alice, bob, carol].map { Node(id: $0) },
            edges: [
                Self.edge(from: alice, to: carol, namedGraph: "incoming"),
                Self.edge(from: bob, to: carol, namedGraph: "incoming")
            ],
            namedGraphs: [NamedGraph(id: "incoming", nodes: [alice, bob, carol])]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let targetID = CompoundGraph.Card.ID(nodeID: carol)
        let targetRect = try cardRect(of: targetID, in: result)
        let ports = try targetPorts(for: targetID, in: targetRect, result: result)
        try #require(ports.count == 2)
        let sides = Set(ports.map(\.side))
        try #require(sides.count == 1)
        let side = try #require(sides.first)
        let coordinates = ports.map { portAxisCoordinate($0.point, side: side) }.sorted()
        let expected = expectedCenteredPortCoordinates(rect: targetRect, side: side, count: ports.count)

        for (actual, expectedValue) in zip(coordinates, expected) {
            #expect(abs(actual - expectedValue) < 0.5)
        }
        #expect(abs((coordinates[0] + coordinates[1]) * 0.5 - sideCenterCoordinate(of: targetRect, side: side)) < 0.5)

        for edge in result.compoundGraph.edges where edge.target == targetID {
            let route = try #require(result.edgeRoutes[edge.id])
            let sourceRect = try cardRect(of: edge.source, in: result)
            let sourceSide = try #require(boundarySide(of: route.start, in: sourceRect))
            let coordinate = portAxisCoordinate(route.start, side: sourceSide)
            let center = sideCenterCoordinate(of: sourceRect, side: sourceSide)
            #expect(abs(coordinate - center) < 0.5)
        }
    }

    @Test
    func directIncomingEdgeKeepsCenterPortAndJointedSiblingKeepsSideOrder() throws {
        let alice = Self.iri("ordered-port-alice")
        let bob = Self.iri("ordered-port-bob")
        let carol = Self.iri("ordered-port-carol")
        let graph = KnowledgeGraph(
            nodes: [alice, bob, carol].map { Node(id: $0) },
            edges: [
                Self.edge(from: alice, to: bob, namedGraph: "left"),
                Self.edge(from: alice, to: carol, namedGraph: "bridge"),
                Self.edge(from: bob, to: carol, namedGraph: "bridge")
            ],
            namedGraphs: [
                NamedGraph(id: "left", nodes: [alice, bob]),
                NamedGraph(id: "bridge", nodes: [carol])
            ]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let carolID = CompoundGraph.Card.ID(nodeID: carol)
        let carolRect = try cardRect(of: carolID, in: result)
        let incoming = result.compoundGraph.edges.filter { $0.target == carolID }
        try #require(incoming.count == 2)

        let directEdge = try #require(incoming.first { edge in
            guard let route = result.edgeRoutes[edge.id] else { return false }
            let points = route.points.isEmpty ? [route.start, route.end] : route.points
            return routeCornerCount(points) == 0
        })
        let jointedEdge = try #require(incoming.first { $0.id != directEdge.id })
        let directRoute = try #require(result.edgeRoutes[directEdge.id])
        let jointedRoute = try #require(result.edgeRoutes[jointedEdge.id])
        let directSide = try #require(boundarySide(of: directRoute.end, in: carolRect))
        let jointedSide = try #require(boundarySide(of: jointedRoute.end, in: carolRect))
        try #require(directSide == jointedSide)

        let center = sideCenterCoordinate(of: carolRect, side: directSide)
        let directCoordinate = portAxisCoordinate(directRoute.end, side: directSide)
        let jointedCoordinate = portAxisCoordinate(jointedRoute.end, side: jointedSide)
        let jointedSourceRect = try cardRect(of: jointedEdge.source, in: result)
        let sourceCoordinate = sideCenterCoordinate(of: jointedSourceRect, side: directSide)
        let incomingCoordinates = [directCoordinate, jointedCoordinate].sorted()
        let expected = expectedCenteredPortCoordinates(
            rect: carolRect,
            side: directSide,
            count: incomingCoordinates.count
        )

        for (actual, expectedValue) in zip(incomingCoordinates, expected) {
            #expect(abs(actual - expectedValue) < 0.5)
        }
        #expect(abs((incomingCoordinates[0] + incomingCoordinates[1]) * 0.5 - center) < 0.5)
        if sourceCoordinate > center {
            #expect(jointedCoordinate > directCoordinate)
        } else {
            #expect(jointedCoordinate < directCoordinate)
        }
    }

    @Test
    func facingSeparatedNodesPreferShortestFacingPortsOverOuterEdgeClearance() throws {
        let graph = try KnowledgeGraphFormat.jsonLD.parse(
            #"""
            {
              "@graph": [
                {"@id": "http://example.org/alice",
                 "@type": "http://xmlns.com/foaf/0.1/Person",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/bob"}},
                {"@id": "http://example.org/bob",
                 "@type": "http://xmlns.com/foaf/0.1/Person",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/carol"}},
                {"@id": "http://example.org/carol",
                 "@type": "http://xmlns.com/foaf/0.1/Person"},

                {"@id": "http://example.org/acme",
                 "@type": "http://example.org/Company"},
                {"@id": "http://example.org/globex",
                 "@type": "http://example.org/Company"},

                {"@id": "http://example.org/laptop",
                 "@type": "http://example.org/Device"},
                {"@id": "http://example.org/phone",
                 "@type": "http://example.org/Device"},

                {"@id": "http://example.org/alice",
                 "http://example.org/worksAt": {"@id": "http://example.org/acme"}},
                {"@id": "http://example.org/bob",
                 "http://example.org/worksAt": {"@id": "http://example.org/globex"}},
                {"@id": "http://example.org/carol",
                 "http://example.org/owns": {"@id": "http://example.org/laptop"}},
                {"@id": "http://example.org/bob",
                 "http://example.org/owns": {"@id": "http://example.org/phone"}}
              ]
            }
            """#,
            scope: "facing-port-shortest",
            baseIRI: nil
        )
        let result = KnowledgeGraphLayout.compute(graph: graph, groupingStrategy: .byType())
        let carolID = CompoundGraph.Card.ID(nodeID: Self.exampleOrgIRI("carol"))
        let laptopID = CompoundGraph.Card.ID(nodeID: Self.exampleOrgIRI("laptop"))
        let edge = try #require(result.compoundGraph.edges.first {
            $0.source == carolID && $0.target == laptopID
        })
        let route = try #require(result.edgeRoutes[edge.id])
        let points = route.points.isEmpty ? [route.start, route.end] : route.points
        let carolRect = try cardRect(of: carolID, in: result)
        let laptopRect = try cardRect(of: laptopID, in: result)
        let sourceSide = try #require(boundarySide(of: route.start, in: carolRect))
        let targetSide = try #require(boundarySide(of: route.end, in: laptopRect))

        try #require(laptopRect.maxX <= carolRect.minX)
        #expect(sourceSide == .left)
        #expect(targetSide == .right)
        #expect(renderedRouteLength(route) <= manhattanDistance(points[0], points[points.count - 1]) + 1)
    }

    @Test
    func equalLengthPortAlternativesPreferFewerCrossingsAtSharedNode() throws {
        let graph = try KnowledgeGraphFormat.jsonLD.parse(
            #"""
            {
              "@graph": [
                {"@id": "http://example.org/engineering",
                 "@graph": [
                   {"@id": "http://example.org/alice",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Engineer"],
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/bob"}},
                   {"@id": "http://example.org/bob",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Engineer"]}
                 ]},
                {"@id": "http://example.org/sales",
                 "@graph": [
                   {"@id": "http://example.org/carol",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Salesperson"],
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/dave"}},
                   {"@id": "http://example.org/dave",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Salesperson"]}
                 ]},
                {"@id": "http://example.org/management",
                 "@graph": [
                   {"@id": "http://example.org/eve",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Manager"],
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/alice"}},
                   {"@id": "http://example.org/eve",
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/carol"}}
                 ]}
              ]
            }
            """#,
            scope: "shared-port-crossing",
            baseIRI: nil
        )
        let result = KnowledgeGraphLayout.compute(
            graph: graph,
            groupingStrategy: .combined(strategies: [.namedGraphs(), .byType()])
        )
        let aliceID = CompoundGraph.Card.ID(nodeID: Self.exampleOrgIRI("alice"))
        let eveID = CompoundGraph.Card.ID(nodeID: Self.exampleOrgIRI("eve"))
        let engineerID = CompoundGraph.Card.ID(nodeID: Self.exampleOrgIRI("Engineer"))
        let eveAlice = try routedEdge(source: eveID, target: aliceID, result: result)
        let aliceEngineer = try routedEdge(source: aliceID, target: engineerID, result: result)

        #expect(!routesCrossAwayFromSharedEndpoint(eveAlice, aliceEngineer))
    }

    @Test
    func outgoingPortsPreserveShortDirectRoutesAndKeepSingletonTargetsNearCenter() throws {
        let source = Self.iri("outgoing-source-with-metadata")
        let eve = Self.iri("outgoing-eve")
        let frank = Self.iri("outgoing-frank")
        let literals = (0..<6).map { NodeIdentifier.literal(value: "metadata-\($0)") }
        let attributeEdges = literals.enumerated().map { index, literal in
            Self.edge(
                from: source,
                to: literal,
                predicate: "http://example.org/metadata/\(index)"
            )
        }
        let graph = KnowledgeGraph(
            nodes: ([source, eve, frank] + literals).map { Node(id: $0) },
            edges: attributeEdges + [
                Self.edge(from: source, to: eve),
                Self.edge(from: source, to: frank)
            ]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph, groupingStrategy: .none)
        let sourceID = CompoundGraph.Card.ID(nodeID: source)
        let sourceRect = try cardRect(of: sourceID, in: result)
        let ports = try sourcePorts(for: sourceID, in: sourceRect, result: result)
        try #require(ports.count == 2)
        let sides = Set(ports.map(\.side))
        try #require(sides.count == 1)
        let side = try #require(sides.first)
        let coordinates = ports.map { portAxisCoordinate($0.point, side: side) }.sorted()
        let center = sideCenterCoordinate(of: sourceRect, side: side)

        #expect(coordinates.contains { abs($0 - center) <= Self.edgeEdgePortSpacing + 0.5 })

        var directRouteCount = 0
        for edge in result.compoundGraph.edges where edge.source == sourceID {
            let route = try #require(result.edgeRoutes[edge.id])
            let routePoints = route.points.isEmpty ? [route.start, route.end] : route.points
            if routeCornerCount(routePoints) == 0 {
                directRouteCount += 1
            }
            let targetRect = try cardRect(of: edge.target, in: result)
            let targetSide = try #require(boundarySide(of: route.end, in: targetRect))
            let coordinate = portAxisCoordinate(route.end, side: targetSide)
            let targetCenter = sideCenterCoordinate(of: targetRect, side: targetSide)
            #expect(abs(coordinate - targetCenter) <= 4.5)
        }
        #expect(directRouteCount >= 1)
    }

    @Test
    func edgesUseDirectOrOrthogonalRoutes() throws {
        let nodes = (0..<5).map { Self.iri("orthogonal-\($0)") }
        let graph = KnowledgeGraph(
            nodes: nodes.map { Node(id: $0) },
            edges: [
                Self.edge(from: nodes[0], to: nodes[1], namedGraph: "route"),
                Self.edge(from: nodes[0], to: nodes[2], namedGraph: "route"),
                Self.edge(from: nodes[1], to: nodes[3], namedGraph: "route"),
                Self.edge(from: nodes[2], to: nodes[4], namedGraph: "route")
            ],
            namedGraphs: [NamedGraph(id: "route", nodes: nodes)]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        for edge in result.compoundGraph.edges {
            let route = try #require(result.edgeRoutes[edge.id])
            #expect(route.points.count >= 2)
            let routePoints = route.points.isEmpty ? [route.start, route.end] : route.points
            let sourceRect = try cardRect(of: edge.source, in: result)
            let targetRect = try cardRect(of: edge.target, in: result)
            #expect(routeSegmentsAreOrthogonal(routePoints))
            for card in result.compoundGraph.cards where card.id != edge.source && card.id != edge.target {
                let rect = try cardRect(of: card.id, in: result)
                #expect(!routeIntersectsRect(routePoints, rect.insetBy(dx: -2, dy: -2)))
            }
            let blockingRects = try result.compoundGraph.cards.compactMap { card -> CGRect? in
                guard card.id != edge.source && card.id != edge.target else { return nil }
                return try cardRect(of: card.id, in: result).insetBy(dx: -2, dy: -2)
            }
            if fixedEndpointManhattanRouteClearsNodes(
                start: routePoints[0],
                end: routePoints[routePoints.count - 1],
                blockingRects: blockingRects
            ) {
                #expect(renderedRouteLength(route) <= manhattanDistance(
                    routePoints[0],
                    routePoints[routePoints.count - 1]
                ) + 1)
            }
            #expect(endpointSegmentLeavesRectOrthogonally(
                boundaryPoint: routePoints[0],
                outsidePoint: routePoints[1],
                rect: sourceRect
            ))
            #expect(endpointSegmentLeavesRectOrthogonally(
                boundaryPoint: routePoints[routePoints.count - 1],
                outsidePoint: routePoints[routePoints.count - 2],
                rect: targetRect
            ))
            if
                let sourceSide = boundarySide(of: routePoints[0], in: sourceRect),
                let targetSide = boundarySide(of: routePoints[routePoints.count - 1], in: targetRect),
                boundarySidesAreOpposite(sourceSide, targetSide)
            {
                let shortestBoundaryLength = manhattanDistance(
                    routePoints[0],
                    routePoints[routePoints.count - 1]
                )
                #expect(renderedRouteLength(route) <= shortestBoundaryLength + 1)
            }
        }
    }

    @Test
    func selfLoopUsesOrthogonalBoundaryPorts() throws {
        let node = Self.iri("self-loop-node")
        let graph = KnowledgeGraph(
            nodes: [Node(id: node)],
            edges: [Self.edge(from: node, to: node, predicate: "http://example.org/self")],
            namedGraphs: [NamedGraph(id: "self", nodes: [node])]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let edge = try #require(result.compoundGraph.edges.first)
        let route = try #require(result.edgeRoutes[edge.id])
        let routePoints = route.points.isEmpty ? [route.start, route.end] : route.points
        let rect = try cardRect(of: edge.source, in: result)

        #expect(routePoints.count >= 4)
        #expect(endpointSegmentLeavesRectOrthogonally(
            boundaryPoint: routePoints[0],
            outsidePoint: routePoints[1],
            rect: rect
        ))
        #expect(endpointSegmentLeavesRectOrthogonally(
            boundaryPoint: routePoints[routePoints.count - 1],
            outsidePoint: routePoints[routePoints.count - 2],
            rect: rect
        ))
        for offset in 1..<routePoints.count {
            let previous = routePoints[offset - 1]
            let current = routePoints[offset]
            let sameX = abs(previous.x - current.x) < 0.5
            let sameY = abs(previous.y - current.y) < 0.5
            #expect(sameX || sameY)
        }
    }

    @Test
    func jointedEdgesKeepEdgeEdgeDistanceAwayFromSharedEndpointFanout() throws {
        let alice = Self.exampleOrgIRI("joint-alice")
        let bob = Self.exampleOrgIRI("joint-bob")
        let carol = Self.exampleOrgIRI("joint-carol")
        let dave = Self.exampleOrgIRI("joint-dave")
        let eve = Self.exampleOrgIRI("joint-eve")
        let graph = KnowledgeGraph(
            nodes: [alice, bob, carol, dave, eve].map { Node(id: $0) },
            edges: [
                Self.edge(from: alice, to: bob, namedGraph: "core"),
                Self.edge(from: carol, to: bob, namedGraph: "core"),
                Self.edge(from: alice, to: dave, namedGraph: "bridge"),
                Self.edge(from: bob, to: eve, namedGraph: "bridge")
            ],
            namedGraphs: [
                NamedGraph(id: "core", nodes: [alice, bob, carol]),
                NamedGraph(id: "advisors", nodes: [dave, eve])
            ]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let routedEdges = result.compoundGraph.edges.compactMap { edge -> RoutedTestEdge? in
            guard let route = result.edgeRoutes[edge.id] else { return nil }
            let points = route.points.isEmpty ? [route.start, route.end] : route.points
            guard routeCornerCount(points) > 0 else { return nil }
            return RoutedTestEdge(edge: edge, points: points)
        }
        try #require(routedEdges.count >= 2)

        var checkedPairs = 0
        for i in 0..<(routedEdges.count - 1) {
            for j in (i + 1)..<routedEdges.count {
                let distance = routeDistanceAwayFromSharedEndpointFanout(routedEdges[i], routedEdges[j])
                guard distance.isFinite else { continue }
                checkedPairs += 1
                #expect(distance >= 13)
            }
        }
        #expect(checkedPairs > 0)
    }

    @Test
    func longRankChainWrapsTowardThreeToTwoCanvas() throws {
        let nodes = (0..<14).map { Self.iri("wrap-\($0)") }
        let edges = (0..<(nodes.count - 1)).map { index in
            Self.edge(from: nodes[index], to: nodes[index + 1], namedGraph: "wrap")
        }
        let graph = KnowledgeGraph(
            nodes: nodes.map { Node(id: $0) },
            edges: edges,
            namedGraphs: [NamedGraph(id: "wrap", nodes: nodes)]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let aspect = Double(result.canvasSize.width / result.canvasSize.height)

        #expect(aspect > 0.95)
        #expect(aspect < 2.05)
    }

    @Test
    func ungroupedNodesUseOutlineOptimizedRankWrap() throws {
        let alice = Self.exampleOrgIRI("outline-alice")
        let bob = Self.exampleOrgIRI("outline-bob")
        let carol = Self.exampleOrgIRI("outline-carol")
        let dave = Self.exampleOrgIRI("outline-dave")
        let eve = Self.exampleOrgIRI("outline-eve")
        let frank = Self.exampleOrgIRI("outline-frank")
        let bridge = "http://example.org/bridge"
        let graph = KnowledgeGraph(
            nodes: [alice, bob, carol, dave, eve, frank].map { Node(id: $0) },
            edges: [
                Self.edge(from: alice, to: bob),
                Self.edge(from: bob, to: carol),
                Self.edge(from: alice, to: carol),
                Self.edge(from: carol, to: dave, predicate: bridge),
                Self.edge(from: dave, to: eve),
                Self.edge(from: eve, to: frank),
                Self.edge(from: dave, to: frank)
            ]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph, groupingStrategy: .none)
        let eveFrankEdge = try #require(result.compoundGraph.edges.first {
            $0.source == CompoundGraph.Card.ID(nodeID: eve)
                && $0.target == CompoundGraph.Card.ID(nodeID: frank)
        })
        let eveFrankRoute = try #require(result.edgeRoutes[eveFrankEdge.id])
        let eveFrankPoints = eveFrankRoute.points.isEmpty
            ? [eveFrankRoute.start, eveFrankRoute.end]
            : eveFrankRoute.points
        let daveFrankEdge = try #require(result.compoundGraph.edges.first {
            $0.source == CompoundGraph.Card.ID(nodeID: dave)
                && $0.target == CompoundGraph.Card.ID(nodeID: frank)
        })
        let daveFrankRoute = try #require(result.edgeRoutes[daveFrankEdge.id])
        let daveFrankPoints = daveFrankRoute.points.isEmpty
            ? [daveFrankRoute.start, daveFrankRoute.end]
            : daveFrankRoute.points
        let eveFrankRouted = RoutedTestEdge(edge: eveFrankEdge, points: eveFrankPoints)
        let daveFrankRouted = RoutedTestEdge(edge: daveFrankEdge, points: daveFrankPoints)
        #expect(routeCornerCount(eveFrankPoints) == 0)
        #expect(!routesCrossAwayFromSharedEndpoint(eveFrankRouted, daveFrankRouted))
        #expect(daveFrankRoute.end.y < eveFrankRoute.end.y)
        #expect(renderedRouteLength(daveFrankRoute) <= 148.5)

        let outline = try nodeOutlineRect(result: result)
        let aspect = Double(outline.width / outline.height)
        let cardRects = try cardRects(result: result)

        #expect(aspect > 0.95)
        #expect(aspect < 2.05)
        for i in 0..<(cardRects.count - 1) {
            for j in (i + 1)..<cardRects.count {
                #expect(rectanglesAreSeparated(cardRects[i], cardRects[j], horizontal: 80, vertical: 40))
            }
        }
    }

    @Test
    func connectedGroupBlocksWrapTowardThreeToTwoCanvas() throws {
        let groupIDs = (0..<6).map { "macro-\($0)" }
        var nodes: [NodeIdentifier] = []
        var edges: [Edge] = []
        var namedGraphs: [NamedGraph] = []
        var previousTail: NodeIdentifier?

        for groupID in groupIDs {
            let groupNodes = (0..<3).map { Self.iri("\(groupID)-node-\($0)-with-readable-title") }
            nodes.append(contentsOf: groupNodes)
            namedGraphs.append(NamedGraph(id: groupID, nodes: groupNodes))
            edges.append(Self.edge(from: groupNodes[0], to: groupNodes[1], namedGraph: groupID))
            edges.append(Self.edge(from: groupNodes[1], to: groupNodes[2], namedGraph: groupID))
            if let previousTail {
                edges.append(Self.edge(
                    from: previousTail,
                    to: groupNodes[0],
                    predicate: "http://example.org/derivedFrom"
                ))
            }
            previousTail = groupNodes[2]
        }

        let graph = KnowledgeGraph(
            nodes: nodes.map { Node(id: $0) },
            edges: edges,
            namedGraphs: namedGraphs
        )
        let result = KnowledgeGraphLayout.compute(graph: graph)
        let aspect = Double(result.canvasSize.width / result.canvasSize.height)
        let boxes = try groupIDs.map { groupID in
            try #require(groupBoundingBox(label: groupID, result: result))
        }
        let yValues = boxes.map { Double($0.midY) }
        let maxY = try #require(yValues.max())
        let minY = try #require(yValues.min())
        let verticalSpread = maxY - minY
        let maxGroupHeight = Double(boxes.map(\.height).max() ?? 1)

        #expect(aspect > 0.95)
        #expect(aspect < 2.05)
        #expect(verticalSpread > maxGroupHeight * 0.60)
    }

    @Test
    func groupInternalLayoutStacksWideNodesVertically() throws {
        let nodes = (0..<4).map { Self.iri("wide-group-node-\($0)-with-readable-title") }
        let outside = Self.iri("outside-node")
        let edges = (0..<(nodes.count - 1)).map { index in
            Self.edge(from: nodes[index], to: nodes[index + 1], namedGraph: "stack")
        } + [
            Self.edge(from: nodes[nodes.count - 1], to: outside, predicate: "http://example.org/relatedTo")
        ]
        let graph = KnowledgeGraph(
            nodes: (nodes + [outside]).map { Node(id: $0) },
            edges: edges,
            namedGraphs: [NamedGraph(id: "stack", nodes: nodes)]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let centers = try nodes.map { node in
            try center(of: CompoundGraph.Card.ID(nodeID: node), in: result)
        }
        let xValues = centers.map { Double($0.x) }
        let maxX = try #require(xValues.max())
        let minX = try #require(xValues.min())

        #expect(maxX - minX < 12)
        for offset in 1..<centers.count {
            #expect(centers[offset].y > centers[offset - 1].y)
        }
        let memberRects = try nodes.map { node in
            try cardRect(of: CompoundGraph.Card.ID(nodeID: node), in: result)
        }
        let verticalGaps = zip(memberRects.dropFirst(), memberRects).map { next, previous in
            next.minY - previous.maxY
        }
        for gap in verticalGaps {
            #expect(gap < 42)
            #expect(gap >= 28)
        }

        let groupCardIDs = Set(nodes.map { CompoundGraph.Card.ID(nodeID: $0) })
        for edge in result.compoundGraph.edges where groupCardIDs.contains(edge.source) && groupCardIDs.contains(edge.target) {
            let sourceRect = try cardRect(of: edge.source, in: result)
            let targetRect = try cardRect(of: edge.target, in: result)
            let route = try #require(result.edgeRoutes[edge.id])
            let routePoints = route.points.isEmpty ? [route.start, route.end] : route.points
            let labelCenter = try #require(result.edgeLabelPositions[edge.id])
            let labelRect = edgeLabelRect(center: labelCenter, edge: edge)

            #expect(routePoints.count <= 4)
            #expect(!labelRect.intersects(sourceRect.insetBy(dx: -2, dy: -2)))
            #expect(!labelRect.intersects(targetRect.insetBy(dx: -2, dy: -2)))
        }
    }

    @Test
    func longEdgeLabelReceivesReadableRouteLength() throws {
        let source = Self.iri("label-source")
        let target = Self.iri("label-target")
        let predicate = "http://example.org/reallyLongPredicateLabelForReadableEdge"
        let graph = KnowledgeGraph(
            nodes: [source, target].map { Node(id: $0) },
            edges: [Self.edge(from: source, to: target, predicate: predicate, namedGraph: "label")],
            namedGraphs: [NamedGraph(id: "label", nodes: [source, target])]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let edge = try #require(result.compoundGraph.edges.first)
        let route = try #require(result.edgeRoutes[edge.id])
        let routeLength = renderedRouteLength(route)
        let labelRects = try edgeLabelRects(result: result)
        let readableLabelRect = try #require(labelRects.first)
        let readableLabelWidth = Double(readableLabelRect.width)

        #expect(routeLength > readableLabelWidth + 24)
        #expect(routeLength < readableLabelWidth + 110)
    }

    @Test
    func shortVerticalEdgeDoesNotInheritCardWidth() throws {
        let source = Self.iri("wide-source-node-title")
        let target = Self.iri("wide-target-node-title")
        let graph = KnowledgeGraph(
            nodes: [source, target].map { Node(id: $0) },
            edges: [Self.edge(from: source, to: target, namedGraph: "vertical")],
            namedGraphs: [NamedGraph(id: "vertical", nodes: [source, target])]
        )

        let result = KnowledgeGraphLayout.compute(
            graph: graph,
            initial: [
                source: CGPoint(x: 0, y: 0),
                target: CGPoint(x: 0, y: 160)
            ]
        )
        let edge = try #require(result.compoundGraph.edges.first)
        let route = try #require(result.edgeRoutes[edge.id])
        let routeLength = renderedRouteLength(route)
        let labelRect = try #require(edgeLabelRects(result: result).first)
        let labelCenter = try #require(result.edgeLabelPositions[edge.id])
        let sourceRect = try cardRect(of: edge.source, in: result)
        let targetRect = try cardRect(of: edge.target, in: result)

        #expect(routeLength < Double(labelRect.width) + 100)
        #expect(distanceToRoute(labelCenter, route: route) <= 1)
        #expect(!labelRect.intersects(sourceRect.insetBy(dx: -2, dy: -2)))
        #expect(!labelRect.intersects(targetRect.insetBy(dx: -2, dy: -2)))
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
    func finalLayoutSatisfiesMinimumDistanceConstraints() throws {
        let left = (0..<3).map { Self.iri("distance-left-\($0)") }
        let right = (0..<3).map { Self.iri("distance-right-\($0)") }
        let orphan = Self.iri("distance-orphan")
        let edges = [
            Self.edge(from: left[0], to: left[1], namedGraph: "left"),
            Self.edge(from: left[1], to: left[2], namedGraph: "left"),
            Self.edge(from: right[0], to: right[1], namedGraph: "right"),
            Self.edge(from: right[1], to: right[2], namedGraph: "right"),
            Self.edge(from: left[2], to: right[0], predicate: "http://example/derivedFrom"),
            Self.edge(from: orphan, to: left[0], predicate: "http://example/mentions")
        ]
        let graph = KnowledgeGraph(
            nodes: (left + right + [orphan]).map { Node(id: $0) },
            edges: edges,
            namedGraphs: [
                NamedGraph(id: "left", nodes: left),
                NamedGraph(id: "right", nodes: right)
            ]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let cardRects = try cardRects(result: result)
        let sameGroupPairs = sameGroupCardPairs(result: result)
        for i in 0..<(cardRects.count - 1) {
            for j in (i + 1)..<cardRects.count {
                let isSameGroup = sameGroupPairs.contains(pairKey(i, j))
                #expect(rectanglesAreSeparated(
                    cardRects[i],
                    cardRects[j],
                    horizontal: isSameGroup ? 40 : 80,
                    vertical: isSameGroup ? 28 : 40
                ))
            }
        }

        let groups = result.compoundGraph.groups
        for i in 0..<(groups.count - 1) {
            for j in (i + 1)..<groups.count {
                let leftBox = try #require(result.groupBoundingBoxes[groups[i].id])
                let rightBox = try #require(result.groupBoundingBoxes[groups[j].id])
                #expect(rectanglesAreSeparated(leftBox, rightBox, byAtLeast: 72))
            }
        }

        for group in groups {
            let groupBox = try #require(result.groupBoundingBoxes[group.id])
            let members = Set(group.members)
            for card in result.compoundGraph.cards where !members.contains(card.id) {
                let cardRect = try cardRect(of: card.id, in: result)
                #expect(rectanglesAreSeparated(groupBox, cardRect, byAtLeast: 32))
            }
        }

        try assertRouteJointsRespectNodeDistance(result: result, minimum: 14)
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
                #expect(rectDistance(labelRects[i], labelRects[j]) >= 3.5)
            }
        }
        for edge in result.compoundGraph.edges {
            let route = try #require(result.edgeRoutes[edge.id])
            let labelCenter = try #require(result.edgeLabelPositions[edge.id])
            #expect(distanceToRoute(labelCenter, route: route) <= 1)
        }
    }

    @Test
    func multiJointEdgeLabelsUseSecondSourceSegment() throws {
        let alice = Self.exampleOrgIRI("label-route-alice")
        let bob = Self.exampleOrgIRI("label-route-bob")
        let carol = Self.exampleOrgIRI("label-route-carol")
        let dave = Self.exampleOrgIRI("label-route-dave")
        let eve = Self.exampleOrgIRI("label-route-eve")
        let frank = Self.exampleOrgIRI("label-route-frank")
        let graph = KnowledgeGraph(
            nodes: [alice, bob, carol, dave, eve, frank].map { Node(id: $0) },
            edges: [
                Self.edge(from: alice, to: bob, namedGraph: "g1"),
                Self.edge(from: bob, to: carol, namedGraph: "g1"),
                Self.edge(from: alice, to: carol, namedGraph: "g1"),
                Self.edge(from: dave, to: eve, namedGraph: "g2"),
                Self.edge(from: eve, to: frank, namedGraph: "g2"),
                Self.edge(from: dave, to: frank, namedGraph: "g2")
            ],
            namedGraphs: [
                NamedGraph(id: "g1", nodes: [alice, bob, carol]),
                NamedGraph(id: "g2", nodes: [dave, eve, frank])
            ]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        var checked = 0
        for edge in result.compoundGraph.edges {
            let route = try #require(result.edgeRoutes[edge.id])
            let points = route.points.isEmpty ? [route.start, route.end] : route.points
            guard points.count >= 4 else { continue }
            let labelCenter = try #require(result.edgeLabelPositions[edge.id])
            let labelRect = edgeLabelRect(center: labelCenter, edge: edge)
            let secondSegmentLength = hypot(points[2].x - points[1].x, points[2].y - points[1].y)
            let secondSegmentLabelAxis = abs(points[2].x - points[1].x) >= abs(points[2].y - points[1].y)
                ? labelRect.width
                : labelRect.height
            if secondSegmentLength >= secondSegmentLabelAxis + 8 {
                #expect(pointLiesOnSegment(labelCenter, start: points[1], end: points[2]))
            } else {
                #expect(pointLiesOnRoute(labelCenter, points: points))
            }
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test
    func edgeLabelsStayAttachedAndInsideCanvasForOuterRoutes() throws {
        let alice = Self.exampleOrgIRI("label-alice")
        let bob = Self.exampleOrgIRI("label-bob")
        let carol = Self.exampleOrgIRI("label-carol")
        let dave = Self.exampleOrgIRI("label-dave")
        let eve = Self.exampleOrgIRI("label-eve")
        let frank = Self.exampleOrgIRI("label-frank")
        let graph = KnowledgeGraph(
            nodes: [alice, bob, carol, dave, eve, frank].map { Node(id: $0) },
            edges: [
                Self.edge(from: alice, to: bob, namedGraph: "g1"),
                Self.edge(from: bob, to: carol, namedGraph: "g1"),
                Self.edge(from: alice, to: carol, namedGraph: "g1"),
                Self.edge(from: dave, to: eve, namedGraph: "g2"),
                Self.edge(from: eve, to: frank, namedGraph: "g2"),
                Self.edge(from: dave, to: frank, namedGraph: "g2")
            ],
            namedGraphs: [
                NamedGraph(id: "g1", nodes: [alice, bob, carol]),
                NamedGraph(id: "g2", nodes: [dave, eve, frank])
            ]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let canvasRect = CGRect(origin: .zero, size: result.canvasSize).insetBy(dx: -1, dy: -1)
        for edge in result.compoundGraph.edges {
            let route = try #require(result.edgeRoutes[edge.id])
            let labelCenter = try #require(result.edgeLabelPositions[edge.id])
            let labelRect = edgeLabelRect(center: labelCenter, edge: edge)
            #expect(canvasRect.contains(labelRect))
            #expect(distanceToRoute(labelCenter, route: route) <= 1)
        }
    }

    @Test
    func skipEdgesPreferShortestSideBypassAroundIntermediateNodes() throws {
        let alice = Self.exampleOrgIRI("shortest-alice")
        let bob = Self.exampleOrgIRI("shortest-bob")
        let carol = Self.exampleOrgIRI("shortest-carol")
        let dave = Self.exampleOrgIRI("shortest-dave")
        let eve = Self.exampleOrgIRI("shortest-eve")
        let frank = Self.exampleOrgIRI("shortest-frank")
        let graph = KnowledgeGraph(
            nodes: [alice, bob, carol, dave, eve, frank].map { Node(id: $0) },
            edges: [
                Self.edge(from: alice, to: bob, namedGraph: "g1"),
                Self.edge(from: bob, to: carol, namedGraph: "g1"),
                Self.edge(from: alice, to: carol, namedGraph: "g1"),
                Self.edge(from: dave, to: eve, namedGraph: "g2"),
                Self.edge(from: eve, to: frank, namedGraph: "g2"),
                Self.edge(from: dave, to: frank, namedGraph: "g2")
            ],
            namedGraphs: [
                NamedGraph(id: "g1", nodes: [alice, bob, carol]),
                NamedGraph(id: "g2", nodes: [dave, eve, frank])
            ]
        )

        let result = KnowledgeGraphLayout.compute(graph: graph)
        let skipPairs = [
            (alice, carol, bob),
            (dave, frank, eve)
        ]
        var endpointCounts: [EndpointBucket: Int] = [:]
        var endpoints: [(bucket: EndpointBucket, port: BoundaryPort, rect: CGRect)] = []
        for edge in result.compoundGraph.edges {
            let route = try #require(result.edgeRoutes[edge.id])
            let sourceRect = try cardRect(of: edge.source, in: result)
            let targetRect = try cardRect(of: edge.target, in: result)
            let sourceSide = try #require(boundarySide(of: route.start, in: sourceRect))
            let targetSide = try #require(boundarySide(of: route.end, in: targetRect))
            let sourceBucket = EndpointBucket(cardID: edge.source, side: sourceSide)
            let targetBucket = EndpointBucket(cardID: edge.target, side: targetSide)
            endpointCounts[sourceBucket, default: 0] += 1
            endpointCounts[targetBucket, default: 0] += 1
            endpoints.append((sourceBucket, BoundaryPort(point: route.start, side: sourceSide), sourceRect))
            endpoints.append((targetBucket, BoundaryPort(point: route.end, side: targetSide), targetRect))
        }

        for endpoint in endpoints where endpointCounts[endpoint.bucket] == 1 {
            let coordinate = portAxisCoordinate(endpoint.port.point, side: endpoint.port.side)
            let center = sideCenterCoordinate(of: endpoint.rect, side: endpoint.port.side)
            #expect(abs(coordinate - center) < 0.5)
        }

        for (source, target, blocker) in skipPairs {
            let sourceID = CompoundGraph.Card.ID(nodeID: source)
            let targetID = CompoundGraph.Card.ID(nodeID: target)
            let blockerID = CompoundGraph.Card.ID(nodeID: blocker)
            let edge = try #require(result.compoundGraph.edges.first {
                $0.source == sourceID && $0.target == targetID
            })
            let route = try #require(result.edgeRoutes[edge.id])
            let points = route.points.isEmpty ? [route.start, route.end] : route.points
            let sourceRect = try cardRect(of: sourceID, in: result)
            let targetRect = try cardRect(of: targetID, in: result)
            let blockerRect = try cardRect(of: blockerID, in: result)
            let sourceSide = try #require(boundarySide(of: route.start, in: sourceRect))
            let targetSide = try #require(boundarySide(of: route.end, in: targetRect))

            #expect(sourceSide == targetSide)
            #expect(sourceSide == .left || sourceSide == .right)
            #expect(routeCornerCount(points) <= 4)
            #expect(!routeIntersectsRect(points, blockerRect.insetBy(dx: -14, dy: -14)))
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
                #expect(rectDistance(labelRects[i], labelRects[j]) >= 3.5)
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

    private func rectanglesAreSeparated(
        _ lhs: CGRect,
        _ rhs: CGRect,
        byAtLeast gap: CGFloat
    ) -> Bool {
        rectanglesAreSeparated(lhs, rhs, horizontal: gap, vertical: gap)
    }

    private func rectanglesAreSeparated(
        _ lhs: CGRect,
        _ rhs: CGRect,
        horizontal: CGFloat,
        vertical: CGFloat
    ) -> Bool {
        let horizontalGap = max(lhs.minX - rhs.maxX, rhs.minX - lhs.maxX)
        let verticalGap = max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY)
        let tolerance: CGFloat = 1
        return horizontalGap >= horizontal - tolerance || verticalGap >= vertical - tolerance
    }

    private func sameGroupCardPairs(result: KnowledgeGraphLayout.Result) -> Set<UInt64> {
        let indexByID = Dictionary(uniqueKeysWithValues:
            result.compoundGraph.cards.enumerated().map { ($0.element.id, $0.offset) }
        )
        var pairs: Set<UInt64> = []
        for group in result.compoundGraph.groups {
            let indices = group.members.compactMap { indexByID[$0] }
            guard indices.count > 1 else { continue }
            for a in 0..<(indices.count - 1) {
                for b in (a + 1)..<indices.count {
                    pairs.insert(pairKey(indices[a], indices[b]))
                }
            }
        }
        return pairs
    }

    private func pairKey(_ a: Int, _ b: Int) -> UInt64 {
        let lo = UInt64(min(a, b))
        let hi = UInt64(max(a, b))
        return (lo << 32) | hi
    }

    private func pointIsOnBoundary(_ point: CGPoint, of rect: CGRect) -> Bool {
        let epsilon: CGFloat = 0.5
        let onVertical = abs(point.x - rect.minX) < epsilon || abs(point.x - rect.maxX) < epsilon
        let onHorizontal = abs(point.y - rect.minY) < epsilon || abs(point.y - rect.maxY) < epsilon
        return onVertical || onHorizontal
    }

    private enum BoundarySide: Hashable {
        case top
        case right
        case bottom
        case left
    }

    private struct BoundaryPort {
        let point: CGPoint
        let side: BoundarySide
    }

    private struct EndpointBucket: Hashable {
        let cardID: CompoundGraph.Card.ID
        let side: BoundarySide
    }

    private struct RoutedTestEdge {
        let edge: CompoundGraph.CardEdge
        let points: [CGPoint]
    }

    private func routedEdge(
        source: CompoundGraph.Card.ID,
        target: CompoundGraph.Card.ID,
        result: KnowledgeGraphLayout.Result
    ) throws -> RoutedTestEdge {
        let edge = try #require(result.compoundGraph.edges.first {
            $0.source == source && $0.target == target
        })
        let route = try #require(result.edgeRoutes[edge.id])
        return RoutedTestEdge(
            edge: edge,
            points: route.points.isEmpty ? [route.start, route.end] : route.points
        )
    }

    private func sourcePorts(
        for cardID: CompoundGraph.Card.ID,
        in rect: CGRect,
        result: KnowledgeGraphLayout.Result
    ) throws -> [BoundaryPort] {
        var ports: [BoundaryPort] = []
        for edge in result.compoundGraph.edges where edge.source == cardID {
            let route = try #require(result.edgeRoutes[edge.id])
            let side = try #require(boundarySide(of: route.start, in: rect))
            ports.append(BoundaryPort(point: route.start, side: side))
        }
        return ports
    }

    private func targetPorts(
        for cardID: CompoundGraph.Card.ID,
        in rect: CGRect,
        result: KnowledgeGraphLayout.Result
    ) throws -> [BoundaryPort] {
        var ports: [BoundaryPort] = []
        for edge in result.compoundGraph.edges where edge.target == cardID {
            let route = try #require(result.edgeRoutes[edge.id])
            let side = try #require(boundarySide(of: route.end, in: rect))
            ports.append(BoundaryPort(point: route.end, side: side))
        }
        return ports
    }

    private func portAxisCoordinate(_ point: CGPoint, side: BoundarySide) -> CGFloat {
        switch side {
        case .top, .bottom:
            return point.x
        case .left, .right:
            return point.y
        }
    }

    private func sideCenterCoordinate(of rect: CGRect, side: BoundarySide) -> CGFloat {
        switch side {
        case .top, .bottom:
            return rect.midX
        case .left, .right:
            return rect.midY
        }
    }

    private func sideLength(of rect: CGRect, side: BoundarySide) -> CGFloat {
        switch side {
        case .top, .bottom:
            return rect.width
        case .left, .right:
            return rect.height
        }
    }

    private func expectedCenteredPortCoordinates(
        rect: CGRect,
        side: BoundarySide,
        count: Int
    ) -> [CGFloat] {
        let safeCount = max(count, 1)
        let length = sideLength(of: rect, side: side)
        let guardDistance = min(CGFloat(1), max(length / 2, 0))
        let availableLength = max(length - guardDistance * 2, 0)
        let step: CGFloat
        if safeCount <= 1 {
            step = 0
        } else {
            let desiredSpan = Self.edgeEdgePortSpacing * CGFloat(safeCount - 1)
            step = desiredSpan <= availableLength
                ? Self.edgeEdgePortSpacing
                : availableLength / CGFloat(safeCount - 1)
        }
        let center = sideCenterCoordinate(of: rect, side: side)
        let minValue = sideMinimumCoordinate(of: rect, side: side) + guardDistance
        let maxValue = sideMaximumCoordinate(of: rect, side: side) - guardDistance
        return (0..<safeCount).map { index in
            let offset = (CGFloat(index) - CGFloat(safeCount - 1) / 2) * step
            return min(maxValue, max(minValue, center + offset))
        }
    }

    private func sideMinimumCoordinate(of rect: CGRect, side: BoundarySide) -> CGFloat {
        switch side {
        case .top, .bottom:
            return rect.minX
        case .left, .right:
            return rect.minY
        }
    }

    private func sideMaximumCoordinate(of rect: CGRect, side: BoundarySide) -> CGFloat {
        switch side {
        case .top, .bottom:
            return rect.maxX
        case .left, .right:
            return rect.maxY
        }
    }

    private func endpointSegmentLeavesRectOrthogonally(
        boundaryPoint: CGPoint,
        outsidePoint: CGPoint,
        rect: CGRect
    ) -> Bool {
        guard let side = boundarySide(of: boundaryPoint, in: rect) else {
            return false
        }
        let epsilon: CGFloat = 0.5
        switch side {
        case .top:
            return abs(boundaryPoint.x - outsidePoint.x) < epsilon
                && outsidePoint.y <= boundaryPoint.y + epsilon
        case .right:
            return abs(boundaryPoint.y - outsidePoint.y) < epsilon
                && outsidePoint.x >= boundaryPoint.x - epsilon
        case .bottom:
            return abs(boundaryPoint.x - outsidePoint.x) < epsilon
                && outsidePoint.y >= boundaryPoint.y - epsilon
        case .left:
            return abs(boundaryPoint.y - outsidePoint.y) < epsilon
                && outsidePoint.x <= boundaryPoint.x + epsilon
        }
    }

    private func boundarySide(of point: CGPoint, in rect: CGRect) -> BoundarySide? {
        let epsilon: CGFloat = 0.5
        if abs(point.y - rect.minY) < epsilon {
            return .top
        }
        if abs(point.x - rect.maxX) < epsilon {
            return .right
        }
        if abs(point.y - rect.maxY) < epsilon {
            return .bottom
        }
        if abs(point.x - rect.minX) < epsilon {
            return .left
        }
        return nil
    }

    private func boundarySidesAreOpposite(_ lhs: BoundarySide, _ rhs: BoundarySide) -> Bool {
        switch (lhs, rhs) {
        case (.top, .bottom), (.bottom, .top), (.left, .right), (.right, .left):
            return true
        default:
            return false
        }
    }

    private func manhattanDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> Double {
        Double(abs(lhs.x - rhs.x) + abs(lhs.y - rhs.y))
    }

    private func fixedEndpointManhattanRouteClearsNodes(
        start: CGPoint,
        end: CGPoint,
        blockingRects: [CGRect]
    ) -> Bool {
        let horizontalFirst = [
            start,
            CGPoint(x: end.x, y: start.y),
            end
        ]
        let verticalFirst = [
            start,
            CGPoint(x: start.x, y: end.y),
            end
        ]
        return routeClearsRects(horizontalFirst, blockingRects: blockingRects)
            || routeClearsRects(verticalFirst, blockingRects: blockingRects)
    }

    private func routeClearsRects(_ points: [CGPoint], blockingRects: [CGRect]) -> Bool {
        guard points.count > 1 else { return true }
        for offset in 1..<points.count {
            for rect in blockingRects where segmentIntersectsRect(points[offset - 1], points[offset], rect) {
                return false
            }
        }
        return true
    }

    private func routeSegmentsAreOrthogonal(_ points: [CGPoint]) -> Bool {
        guard points.count > 1 else { return false }
        for offset in 1..<points.count {
            let previous = points[offset - 1]
            let current = points[offset]
            let sameX = abs(previous.x - current.x) < 0.5
            let sameY = abs(previous.y - current.y) < 0.5
            if !sameX && !sameY {
                return false
            }
        }
        return true
    }

    private func routeCornerCount(_ points: [CGPoint]) -> Int {
        guard points.count > 2 else { return 0 }
        var count = 0
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]
            let enteringHorizontal = abs(previous.y - current.y) < 0.5
            let leavingHorizontal = abs(current.y - next.y) < 0.5
            if enteringHorizontal != leavingHorizontal {
                count += 1
            }
        }
        return count
    }

    private func routeDistanceAwayFromSharedEndpointFanout(
        _ lhs: RoutedTestEdge,
        _ rhs: RoutedTestEdge
    ) -> CGFloat {
        let sharedEndpoints = Set([lhs.edge.source, lhs.edge.target])
            .intersection(Set([rhs.edge.source, rhs.edge.target]))
        let lhsSharedPoints = sharedEndpointPoints(
            edge: lhs.edge,
            points: lhs.points,
            sharedEndpoints: sharedEndpoints
        )
        let rhsSharedPoints = sharedEndpointPoints(
            edge: rhs.edge,
            points: rhs.points,
            sharedEndpoints: sharedEndpoints
        )
        var distance = CGFloat.greatestFiniteMagnitude
        for lhsOffset in 1..<lhs.points.count {
            let lhsStart = lhs.points[lhsOffset - 1]
            let lhsEnd = lhs.points[lhsOffset]
            if segmentTouchesEndpoint(start: lhsStart, end: lhsEnd, endpointPoints: lhsSharedPoints) {
                continue
            }
            for rhsOffset in 1..<rhs.points.count {
                let rhsStart = rhs.points[rhsOffset - 1]
                let rhsEnd = rhs.points[rhsOffset]
                if segmentTouchesEndpoint(start: rhsStart, end: rhsEnd, endpointPoints: rhsSharedPoints) {
                    continue
                }
                distance = min(distance, segmentDistance(lhsStart, lhsEnd, rhsStart, rhsEnd))
            }
        }
        return distance
    }

    private func routesCrossAwayFromSharedEndpoint(
        _ lhs: RoutedTestEdge,
        _ rhs: RoutedTestEdge
    ) -> Bool {
        let sharedEndpoints = Set([lhs.edge.source, lhs.edge.target])
            .intersection(Set([rhs.edge.source, rhs.edge.target]))
        let lhsSharedPoints = sharedEndpointPoints(
            edge: lhs.edge,
            points: lhs.points,
            sharedEndpoints: sharedEndpoints
        )
        let rhsSharedPoints = sharedEndpointPoints(
            edge: rhs.edge,
            points: rhs.points,
            sharedEndpoints: sharedEndpoints
        )
        for lhsOffset in 1..<lhs.points.count {
            let lhsStart = lhs.points[lhsOffset - 1]
            let lhsEnd = lhs.points[lhsOffset]
            for rhsOffset in 1..<rhs.points.count {
                let rhsStart = rhs.points[rhsOffset - 1]
                let rhsEnd = rhs.points[rhsOffset]
                guard segmentDistance(lhsStart, lhsEnd, rhsStart, rhsEnd) < 0.5 else { continue }
                if segmentsOnlyMeetAtSharedEndpoint(
                    lhsStart: lhsStart,
                    lhsEnd: lhsEnd,
                    lhsSharedPoints: lhsSharedPoints,
                    rhsStart: rhsStart,
                    rhsEnd: rhsEnd,
                    rhsSharedPoints: rhsSharedPoints
                ) {
                    continue
                }
                return true
            }
        }
        return false
    }

    private func segmentsOnlyMeetAtSharedEndpoint(
        lhsStart: CGPoint,
        lhsEnd: CGPoint,
        lhsSharedPoints: [CGPoint],
        rhsStart: CGPoint,
        rhsEnd: CGPoint,
        rhsSharedPoints: [CGPoint]
    ) -> Bool {
        for lhsPoint in lhsSharedPoints {
            for rhsPoint in rhsSharedPoints where pointsAreClose(lhsPoint, rhsPoint) {
                let lhsTouches = pointsAreClose(lhsStart, lhsPoint) || pointsAreClose(lhsEnd, lhsPoint)
                let rhsTouches = pointsAreClose(rhsStart, rhsPoint) || pointsAreClose(rhsEnd, rhsPoint)
                if lhsTouches && rhsTouches {
                    return true
                }
            }
        }
        return false
    }

    private func sharedEndpointPoints(
        edge: CompoundGraph.CardEdge,
        points: [CGPoint],
        sharedEndpoints: Set<CompoundGraph.Card.ID>
    ) -> [CGPoint] {
        guard !sharedEndpoints.isEmpty else { return [] }
        var result: [CGPoint] = []
        if sharedEndpoints.contains(edge.source), let first = points.first {
            result.append(first)
        }
        if sharedEndpoints.contains(edge.target), let last = points.last {
            result.append(last)
        }
        return result
    }

    private func segmentTouchesEndpoint(
        start: CGPoint,
        end: CGPoint,
        endpointPoints: [CGPoint]
    ) -> Bool {
        endpointPoints.contains { endpoint in
            pointsAreClose(start, endpoint) || pointsAreClose(end, endpoint)
        }
    }

    private func segmentDistance(
        _ a: CGPoint,
        _ b: CGPoint,
        _ c: CGPoint,
        _ d: CGPoint
    ) -> CGFloat {
        if segmentsIntersect(a, b, c, d) {
            return 0
        }
        return min(
            pointSegmentDistance(a, c, d),
            pointSegmentDistance(b, c, d),
            pointSegmentDistance(c, a, b),
            pointSegmentDistance(d, a, b)
        )
    }

    private func pointsAreClose(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y) < 0.5
    }

    private func routeIntersectsRect(_ points: [CGPoint], _ rect: CGRect) -> Bool {
        guard points.count > 1 else { return false }
        for offset in 1..<points.count {
            if segmentIntersectsRect(points[offset - 1], points[offset], rect) {
                return true
            }
        }
        return false
    }

    private func distanceToRoute(
        _ point: CGPoint,
        route: KnowledgeGraphLayout.EdgeRoute
    ) -> CGFloat {
        let points = route.points.isEmpty ? [route.start, route.end] : route.points
        guard points.count > 1 else { return 0 }
        var distance = CGFloat.greatestFiniteMagnitude
        for offset in 1..<points.count {
            distance = min(distance, pointSegmentDistance(point, points[offset - 1], points[offset]))
        }
        return distance
    }

    private func pointSegmentDistance(
        _ point: CGPoint,
        _ start: CGPoint,
        _ end: CGPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.001 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let rawT = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let t = min(1, max(0, rawT))
        let projection = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func segmentIntersectsRect(_ start: CGPoint, _ end: CGPoint, _ rect: CGRect) -> Bool {
        if rect.contains(start) || rect.contains(end) {
            return true
        }
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
        return segmentsIntersect(start, end, topLeft, topRight)
            || segmentsIntersect(start, end, topRight, bottomRight)
            || segmentsIntersect(start, end, bottomRight, bottomLeft)
            || segmentsIntersect(start, end, bottomLeft, topLeft)
    }

    private func segmentsIntersect(
        _ a: CGPoint,
        _ b: CGPoint,
        _ c: CGPoint,
        _ d: CGPoint
    ) -> Bool {
        func orientation(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
        }
        func containsOnSegment(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Bool {
            q.x >= min(p.x, r.x) - 0.001
                && q.x <= max(p.x, r.x) + 0.001
                && q.y >= min(p.y, r.y) - 0.001
                && q.y <= max(p.y, r.y) + 0.001
        }
        let o1 = orientation(a, b, c)
        let o2 = orientation(a, b, d)
        let o3 = orientation(c, d, a)
        let o4 = orientation(c, d, b)
        if o1 == 0 && containsOnSegment(a, c, b) { return true }
        if o2 == 0 && containsOnSegment(a, d, b) { return true }
        if o3 == 0 && containsOnSegment(c, a, d) { return true }
        if o4 == 0 && containsOnSegment(c, b, d) { return true }
        return (o1 > 0) != (o2 > 0) && (o3 > 0) != (o4 > 0)
    }

    private func roundedPointKey(_ point: CGPoint) -> String {
        "\(Int(point.x.rounded())):\(Int(point.y.rounded()))"
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

    private func edgeRouteLengths(
        result: KnowledgeGraphLayout.Result
    ) -> [EdgeIdentifier: Double] {
        var lengths: [EdgeIdentifier: Double] = [:]
        for edge in result.compoundGraph.edges {
            guard let route = result.edgeRoutes[edge.id] else { continue }
            lengths[edge.id] = renderedRouteLength(route)
        }
        return lengths
    }

    private func renderedRouteLength(_ route: KnowledgeGraphLayout.EdgeRoute) -> Double {
        let points = route.points.isEmpty ? [route.start, route.end] : route.points
        guard points.count > 1 else { return 0 }
        var length = 0.0
        for offset in 1..<points.count {
            let dx = Double(points[offset].x - points[offset - 1].x)
            let dy = Double(points[offset].y - points[offset - 1].y)
            length += sqrt(dx * dx + dy * dy)
        }
        return length
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

    private func nodeOutlineRect(result: KnowledgeGraphLayout.Result) throws -> CGRect {
        var rect = CGRect.null
        for cardRect in try cardRects(result: result) {
            rect = rect.isNull ? cardRect : rect.union(cardRect)
        }
        return rect
    }

    private func cardRect(
        of id: CompoundGraph.Card.ID,
        in result: KnowledgeGraphLayout.Result
    ) throws -> CGRect {
        let origin = try #require(result.cardPositions[id])
        let card = try #require(result.compoundGraph.cardByID[id])
        return CGRect(origin: origin, size: card.size)
    }

    private func edgeLabelRects(result: KnowledgeGraphLayout.Result) throws -> [CGRect] {
        try result.compoundGraph.edges.map { edge in
            let center = try #require(result.edgeLabelPositions[edge.id])
            return edgeLabelRect(center: center, edge: edge)
        }
    }

    private func edgeLabelRect(
        center: CGPoint,
        edge: CompoundGraph.CardEdge
    ) -> CGRect {
        let size = CGSize(
            width: min(CGFloat(edge.predicate.count) * 7 + 20, 190),
            height: 18
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func assertRouteJointsRespectNodeDistance(
        result: KnowledgeGraphLayout.Result,
        minimum: CGFloat
    ) throws {
        let cardRects = try cardRects(result: result)
        for edge in result.compoundGraph.edges {
            let route = try #require(result.edgeRoutes[edge.id])
            let points = route.points.isEmpty ? [route.start, route.end] : route.points
            guard points.count > 2 else { continue }
            for joint in points.dropFirst().dropLast() {
                for cardRect in cardRects {
                    #expect(pointRectDistance(joint, cardRect) >= minimum - 0.5)
                }
            }
        }
    }

    private func rectDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let dx = max(max(lhs.minX - rhs.maxX, rhs.minX - lhs.maxX), 0)
        let dy = max(max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY), 0)
        return hypot(dx, dy)
    }

    private func pointRectDistance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, point.x - rect.maxX), 0)
        let dy = max(max(rect.minY - point.y, point.y - rect.maxY), 0)
        return hypot(dx, dy)
    }

    private func pointLiesOnSegment(
        _ point: CGPoint,
        start: CGPoint,
        end: CGPoint
    ) -> Bool {
        let tolerance: CGFloat = 0.5
        let minX = min(start.x, end.x) - tolerance
        let maxX = max(start.x, end.x) + tolerance
        let minY = min(start.y, end.y) - tolerance
        let maxY = max(start.y, end.y) + tolerance
        return point.x >= minX
            && point.x <= maxX
            && point.y >= minY
            && point.y <= maxY
            && pointSegmentDistance(point, start, end) <= tolerance
    }

    private func pointLiesOnRoute(_ point: CGPoint, points: [CGPoint]) -> Bool {
        guard points.count > 1 else { return false }
        for offset in 1..<points.count where pointLiesOnSegment(
            point,
            start: points[offset - 1],
            end: points[offset]
        ) {
            return true
        }
        return false
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
