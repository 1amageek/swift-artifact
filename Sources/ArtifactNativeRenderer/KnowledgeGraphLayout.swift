import Foundation
import CoreGraphics
import KnowledgeGraph

/// Layered, Mermaid-inspired layout for a `KnowledgeGraph`.
///
/// The pipeline is:
///
/// 1. **Decomposition** — `CompoundGraph.decompose` folds every leaf literal
///    into its owning subject's card. Layout therefore operates on cards
///    rather than raw nodes, which eliminates the foaf:name "Alice" pattern
///    as an independent vertex.
///
/// 2. **Layer assignment** — each connected component is cycle-broken into a
///    DAG, then assigned left-to-right ranks with a longest-path pass. This
///    mirrors the ELK layered pipeline used by BeautifulMermaidSwift instead
///    of treating graph layout as a force simulation.
///
/// 3. **Crossing reduction** — nodes in every rank are repeatedly sorted by
///    neighbour barycentres in downward and upward sweeps, with group
///    membership and source order as deterministic tie breakers.
///
/// 4. **Coordinate assignment** — rank gaps are computed from card sizes,
///    edge-label span, degree load, and group boundaries. This keeps short
///    labels short while still giving hubs enough vertical slots.
///
/// 5. **Distance projection and compaction** — node-node, group-node, and
///    group-group clearances are projected as hard rectangle constraints.
///    The remaining outline is compacted with fixed separation axes so no
///    extra shelf or group gap survives before routing.
///
/// 6. **Compound cleanup** — overlapping group components are kept as a
///    single compaction unit, non-member cards are ejected from group bboxes,
///    and card/group overlaps are resolved without returning to global force
///    physics.
///
/// 7. **Orthogonal edge routing** — each edge receives deterministic boundary
///    ports and a Manhattan polyline. Parallel edges use separate lanes and
///    labels prefer off-centre slots on the routed path, following Mermaid's
///    orthogonal edge model.
///
/// All steps are deterministic and pure functions of the input graph plus
/// any warm-restart positions, so re-running the pipeline on the same
/// snapshot produces pixel-identical output.
struct KnowledgeGraphLayout: Sendable {

    /// Output of a layout run. All coordinates use a top-left origin in
    /// `[0, canvasSize]`.
    struct Result: Sendable {
        let compoundGraph: CompoundGraph
        /// Top-left corner of each card.
        let cardPositions: [CompoundGraph.Card.ID: CGPoint]
        /// Pre-computed edge anchors / control points so the renderer does
        /// not have to re-derive geometry per frame.
        let edgeRoutes: [EdgeIdentifier: EdgeRoute]
        /// Position of every edge label, post collision avoidance.
        let edgeLabelPositions: [EdgeIdentifier: CGPoint]
        /// Padded bounding box for each group, ready to draw. Empty when the
        /// strategy produced no groups.
        let groupBoundingBoxes: [CompoundGraph.Group.ID: CGRect]
        let canvasSize: CGSize
    }

    /// Pre-computed geometry for a single rendered edge.
    struct EdgeRoute: Sendable {
        let start: CGPoint
        let end: CGPoint
        /// Quadratic Bezier control point. Equal to the midpoint of
        /// `start → end` for straight edges.
        let control: CGPoint
        /// Orthogonal polyline points. Empty for legacy quadratic routes and
        /// self-loops.
        let points: [CGPoint]
        /// `true` when this edge is one of multiple parallel edges between
        /// the same pair of cards (or its sibling pair `(t, s)`) and needs a
        /// curved render.
        let isCurved: Bool

        init(
            start: CGPoint,
            end: CGPoint,
            control: CGPoint,
            isCurved: Bool,
            points: [CGPoint] = []
        ) {
            self.start = start
            self.end = end
            self.control = control
            self.points = points
            self.isCurved = isCurved
        }

        func translatedBy(dx: CGFloat, dy: CGFloat) -> EdgeRoute {
            EdgeRoute(
                start: CGPoint(x: start.x + dx, y: start.y + dy),
                end: CGPoint(x: end.x + dx, y: end.y + dy),
                control: CGPoint(x: control.x + dx, y: control.y + dy),
                isCurved: isCurved,
                points: points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            )
        }
    }

    static let defaultIterations = 200

    private enum LayoutSpacing {
        static let edgeEdge: CGFloat = 14
        static let nodeNodeHorizontal: CGFloat = 80
        static let nodeNodeVertical: CGFloat = 40
        static let groupInternalNodeNodeHorizontal: CGFloat = 40
        static let groupInternalNodeNodeVertical: CGFloat = 28
        static let groupInternalConnectedNodeNodeHorizontal: CGFloat = 48
        static let groupInternalConnectedNodeNodeVertical: CGFloat = 36
        static let edgeNode: CGFloat = 18
        static let groupNode: CGFloat = 32
        static let groupGroup: CGFloat = 72
        static let portCornerGuard: CGFloat = 1

        static let labelHeight: CGFloat = 18
        static let edgeLabelLabel: CGFloat = 4
        static let connectedNodeNode: CGFloat = labelHeight + edgeNode * 2
    }

    /// Desired empty space between adjacent card boundaries for a *large*
    /// graph (n ≥ 14). The actual centre-to-centre target for a graph edge
    /// adds the two cards' bounding radii on top of this, so cards never
    /// overlap regardless of their individual sizes. Small graphs scale this
    /// down — see `adaptiveEdgeGap(cardCount:)` — because the same 140 pt
    /// gap that reads as balanced in a 14-node diagram leaves obvious empty
    /// space in a 3-node chain.
    static let defaultEdgeGap: Double = 140

    /// Edge gap scaled by `n`. Returns `defaultEdgeGap` for graphs of 14+
    /// cards and clamps down to `0.45 × defaultEdgeGap` for very small
    /// graphs. The `sqrt(n / 14)` curve matches the natural FR scaling
    /// (`k ∝ sqrt(area/n)` with area-per-card roughly constant) so the
    /// transition is smooth as cards are added or removed during streaming.
    static func adaptiveEdgeGap(cardCount n: Int) -> Double {
        let factor = max(0.45, min(1.0, sqrt(Double(n) / 14.0)))
        return defaultEdgeGap * factor
    }

    private static func estimatedEdgeLabelSpan(_ edge: CompoundGraph.CardEdge) -> Double {
        let labelWidth = Double(edgeLabelSize(edge).width)
        let parallelSpan = Double(max(edge.parallelCount - 1, 0)) * Double(LayoutSpacing.edgeEdge)
        return labelWidth + parallelSpan
    }

    /// Compute the layout for `graph`.
    ///
    /// - Parameters:
    ///   - graph: The graph to lay out.
    ///   - iterations: Number of Fruchterman–Reingold iterations. 200 is
    ///     sufficient for `n < 200`.
    ///   - initial: Warm-restart positions keyed by `NodeIdentifier`. Cards
    ///     whose underlying node has a warm-start position use it; newcomers
    ///     are seeded on a golden-angle spiral around the centroid of warm
    ///     positions.
    static func compute(
        graph: KnowledgeGraph,
        iterations: Int = defaultIterations,
        initial: [NodeIdentifier: CGPoint] = [:],
        groupingStrategy: GroupingStrategy = .namedGraphs()
    ) -> Result {
        let compound = CompoundGraph.decompose(graph, groupingStrategy: groupingStrategy)
        guard !compound.cards.isEmpty else {
            return Result(
                compoundGraph: compound,
                cardPositions: [:],
                edgeRoutes: [:],
                edgeLabelPositions: [:],
                groupBoundingBoxes: [:],
                canvasSize: CGSize(width: 420, height: 280)
            )
        }

        let indexByID = Dictionary(uniqueKeysWithValues:
            compound.cards.enumerated().map { ($0.element.id, $0.offset) }
        )

        let sizes = compound.cards.map { $0.size }
        let radii = sizes.map { Double(hypot($0.width, $0.height)) / 2.0 }
        var positions = computeLayeredPositions(
            cards: compound.cards,
            edges: compound.edges,
            groups: compound.groups,
            sizes: sizes,
            indexByID: indexByID,
            initial: initial,
            sweepLimit: max(8, min(32, iterations / 8))
        )
        finalizeLayeredLayout(
            positions: &positions,
            sizes: sizes,
            radii: radii,
            edges: compound.edges,
            groups: compound.groups,
            indexByID: indexByID
        )

        // Translate to a non-negative coordinate space and finalise canvas.
        // Groups need extra slack so their padded bbox + outside-top label
        // fit inside the canvas without clipping.
        let canvasPadding: CGFloat = compound.groups.isEmpty ? 36 : 64
        var (cardPositions, canvasSize) = anchorAndCanvas(
            cards: compound.cards,
            centerPositions: positions,
            padding: canvasPadding
        )

        // Step 5 & 6: edge routes and label slotting.
        var routes = computeEdgeRoutes(
            edges: compound.edges,
            cards: compound.cards,
            indexByID: indexByID,
            cardPositions: cardPositions,
            groups: compound.groups
        )
        let cardRects = compound.cards.map { card -> CGRect in
            // anchorAndCanvas produces an origin for every card, so a missing
            // lookup here would mean the pipeline desynced — fail loudly.
            guard let origin = cardPositions[card.id] else {
                preconditionFailure("Card \(card.id) missing from cardPositions")
            }
            return CGRect(origin: origin, size: card.size)
        }
        var labels = placeEdgeLabels(
            edges: compound.edges,
            routes: routes,
            cardRects: cardRects
        )

        var groupBoxes = computeGroupBoundingBoxes(
            groups: compound.groups,
            cards: compound.cards,
            indexByID: indexByID,
            cardPositions: cardPositions
        )
        normalizeFinalGeometry(
            cards: compound.cards,
            edges: compound.edges,
            cardPositions: &cardPositions,
            edgeRoutes: &routes,
            edgeLabelPositions: &labels,
            groupBoundingBoxes: &groupBoxes,
            canvasSize: &canvasSize,
            padding: 24
        )

        return Result(
            compoundGraph: compound,
            cardPositions: cardPositions,
            edgeRoutes: routes,
            edgeLabelPositions: labels,
            groupBoundingBoxes: groupBoxes,
            canvasSize: canvasSize
        )
    }

    // MARK: - Layered layout model

    private struct LayeredEdge: Sendable {
        let source: Int
        let target: Int
        let order: Int
        let labelSpan: Double
        let sharesGroup: Bool
    }

    private struct LayeredComponentLayout: Sendable {
        let indices: [Int]
        let positions: [Int: CGPoint]
        let rect: CGRect
    }

    private struct LayoutBlock: Sendable {
        let id: Int
        let groupIndex: Int?
        let indices: [Int]
        let localPositions: [Int: CGPoint]
        let size: CGSize
    }

    private struct DisjointSet {
        private var parents: [Int]
        private var ranks: [Int]

        init(count: Int) {
            self.parents = Array(0..<count)
            self.ranks = Array(repeating: 0, count: count)
        }

        mutating func find(_ value: Int) -> Int {
            if parents[value] != value {
                parents[value] = find(parents[value])
            }
            return parents[value]
        }

        mutating func union(_ lhs: Int, _ rhs: Int) {
            let left = find(lhs)
            let right = find(rhs)
            guard left != right else { return }
            if ranks[left] < ranks[right] {
                parents[left] = right
            } else if ranks[left] > ranks[right] {
                parents[right] = left
            } else {
                parents[right] = left
                ranks[left] += 1
            }
        }
    }

    private static func computeLayeredPositions(
        cards: [CompoundGraph.Card],
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        sizes: [CGSize],
        indexByID: [CompoundGraph.Card.ID: Int],
        initial: [NodeIdentifier: CGPoint],
        sweepLimit: Int
    ) -> [CGPoint] {
        let count = cards.count
        guard count > 1 else {
            return cards.isEmpty ? [] : [CGPoint(x: 0, y: 0)]
        }

        let membership = groupMembershipIndex(groups: groups, indexByID: indexByID)
        var layeredEdges: [LayeredEdge] = []
        layeredEdges.reserveCapacity(edges.count)
        for (order, edge) in edges.enumerated() {
            guard
                let source = indexByID[edge.source],
                let target = indexByID[edge.target]
            else { continue }
            if source != target {
                layeredEdges.append(LayeredEdge(
                    source: source,
                    target: target,
                    order: order,
                    labelSpan: estimatedEdgeLabelSpan(edge),
                    sharesGroup: shareAnyGroup(source, target, membership: membership)
                ))
            }
        }

        let blocks = makeLayoutBlocks(
            groups: groups,
            sizes: sizes,
            edges: layeredEdges,
            membership: membership,
            initial: initial,
            cards: cards,
            sweepLimit: sweepLimit
        )
        guard blocks.count > 1 else {
            var result = Array(repeating: CGPoint.zero, count: count)
            if let block = blocks.first {
                for index in block.indices {
                    result[index] = block.localPositions[index] ?? .zero
                }
            }
            return result
        }

        var blockByCard: [Int: Int] = [:]
        blockByCard.reserveCapacity(count)
        for block in blocks {
            for index in block.indices {
                blockByCard[index] = block.id
            }
        }
        let blockSizes = blocks.map(\.size)
        let macroEdges = makeBlockEdges(
            cardEdges: layeredEdges,
            blockByCard: blockByCard
        )

        var disjointSet = DisjointSet(count: blocks.count)
        for edge in macroEdges where edge.source != edge.target {
            disjointSet.union(edge.source, edge.target)
        }
        var componentMembers: [Int: [Int]] = [:]
        for index in blocks.indices {
            componentMembers[disjointSet.find(index), default: []].append(index)
        }
        let blockComponents = componentMembers.values
            .map { $0.sorted() }
            .sorted { lhs, rhs in
                (lhs.first ?? 0) < (rhs.first ?? 0)
            }
        let blockLayouts = blockComponents.map { component in
            layoutLayeredBlockComponent(
                indices: component,
                edges: macroEdges.filter { component.contains($0.source) && component.contains($0.target) },
                sizes: blockSizes,
                sweepLimit: sweepLimit,
                optimizeOutlineWrap: groups.isEmpty
            )
        }
        let blockCenters = packLayeredComponents(
            blockLayouts,
            sizes: blockSizes,
            cardCount: blocks.count
        )

        var result = Array(repeating: CGPoint.zero, count: count)
        for block in blocks {
            let blockCenter = blockCenters[block.id]
            for index in block.indices {
                let local = block.localPositions[index] ?? .zero
                result[index] = CGPoint(
                    x: blockCenter.x + local.x,
                    y: blockCenter.y + local.y
                )
            }
        }
        return result
    }

    private static func makeLayoutBlocks(
        groups: [CompoundGraph.Group],
        sizes: [CGSize],
        edges: [LayeredEdge],
        membership: GroupMembershipIndex,
        initial: [NodeIdentifier: CGPoint],
        cards: [CompoundGraph.Card],
        sweepLimit: Int
    ) -> [LayoutBlock] {
        let count = sizes.count
        let primaryGroupByCard = primaryGroupByCard(
            cardCount: count,
            groups: groups,
            membership: membership
        )

        var ownedByGroup: [Int: [Int]] = [:]
        for (cardIndex, groupIndex) in primaryGroupByCard {
            ownedByGroup[groupIndex, default: []].append(cardIndex)
        }

        var blocks: [LayoutBlock] = []
        blocks.reserveCapacity(groups.count + count)
        var assigned: Set<Int> = []
        for groupIndex in groups.indices {
            let indices = (ownedByGroup[groupIndex] ?? []).sorted()
            guard !indices.isEmpty else { continue }
            let block = makeGroupLayoutBlock(
                id: blocks.count,
                groupIndex: groupIndex,
                indices: indices,
                group: groups[groupIndex],
                sizes: sizes,
                edges: edges,
                membership: membership,
                initial: initial,
                cards: cards,
                sweepLimit: sweepLimit,
                useVerticalBase: groups.count > 1 || hasExternalEdges(indices: indices, edges: edges)
            )
            assigned.formUnion(indices)
            blocks.append(block)
        }

        for index in 0..<count {
            guard !assigned.contains(index) else { continue }
            let size = sizes[index]
            blocks.append(LayoutBlock(
                id: blocks.count,
                groupIndex: nil,
                indices: [index],
                localPositions: [index: .zero],
                size: size
            ))
        }
        return blocks
    }

    private static func primaryGroupByCard(
        cardCount: Int,
        groups: [CompoundGraph.Group],
        membership: GroupMembershipIndex
    ) -> [Int: Int] {
        var result: [Int: Int] = [:]
        result.reserveCapacity(cardCount)
        for index in 0..<cardCount {
            guard let groupIndices = membership.memberToGroups[index], !groupIndices.isEmpty else {
                continue
            }
            let primary = groupIndices.min { lhs, rhs in
                let leftCount = groups.indices.contains(lhs) ? groups[lhs].members.count : Int.max
                let rightCount = groups.indices.contains(rhs) ? groups[rhs].members.count : Int.max
                if leftCount != rightCount {
                    return leftCount < rightCount
                }
                return lhs < rhs
            }
            if let primary {
                result[index] = primary
            }
        }
        return result
    }

    private static func makeGroupLayoutBlock(
        id: Int,
        groupIndex: Int,
        indices: [Int],
        group: CompoundGraph.Group,
        sizes: [CGSize],
        edges: [LayeredEdge],
        membership: GroupMembershipIndex,
        initial: [NodeIdentifier: CGPoint],
        cards: [CompoundGraph.Card],
        sweepLimit: Int,
        useVerticalBase: Bool
    ) -> LayoutBlock {
        let localLayout: LayeredComponentLayout
        if useVerticalBase {
            localLayout = layoutVerticalGroupComponent(
                indices: indices,
                edges: edges,
                sizes: sizes
            )
        } else {
            let indexSet = Set(indices)
            let localEdges = edges.filter { indexSet.contains($0.source) && indexSet.contains($0.target) }
            localLayout = layoutLayeredComponent(
                indices: indices,
                edges: localEdges,
                sizes: sizes,
                membership: membership,
                initial: initial,
                cards: cards,
                sweepLimit: sweepLimit,
                optimizeOutlineWrap: false
            )
        }
        // Group padding is applied when rendering the final group box. Keeping
        // layout blocks unpadded prevents padding from being counted twice as
        // Node-Node distance when an overlapping group owns the target card.
        let rect = localLayout.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var localPositions: [Int: CGPoint] = [:]
        localPositions.reserveCapacity(indices.count)
        for index in indices {
            let point = localLayout.positions[index] ?? .zero
            localPositions[index] = CGPoint(
                x: point.x - center.x,
                y: point.y - center.y
            )
        }
        return LayoutBlock(
            id: id,
            groupIndex: groupIndex,
            indices: indices,
            localPositions: localPositions,
            size: CGSize(width: rect.width, height: rect.height)
        )
    }

    private static func hasExternalEdges(
        indices: [Int],
        edges: [LayeredEdge]
    ) -> Bool {
        let indexSet = Set(indices)
        for edge in edges {
            let sourceInside = indexSet.contains(edge.source)
            let targetInside = indexSet.contains(edge.target)
            if sourceInside != targetInside {
                return true
            }
        }
        return false
    }

    private static func layoutVerticalGroupComponent(
        indices: [Int],
        edges: [LayeredEdge],
        sizes: [CGSize]
    ) -> LayeredComponentLayout {
        guard indices.count > 1 else {
            let index = indices[0]
            let positions = [index: CGPoint(x: 0, y: 0)]
            return LayeredComponentLayout(
                indices: indices,
                positions: positions,
                rect: componentRect(indices: indices, positions: positions, sizes: sizes)
            )
        }

        let indexSet = Set(indices)
        let localEdges = edges.filter { indexSet.contains($0.source) && indexSet.contains($0.target) }
        let ranks = assignLayerRanks(indices: indices, edges: localEdges)
        let degree = layeredDegrees(indices: indices, edges: edges)
        let externalOrder = externalEdgeOrder(indices: indices, edges: edges)
        let ordered = indices.sorted { lhs, rhs in
            let leftRank = ranks[lhs] ?? 0
            let rightRank = ranks[rhs] ?? 0
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            let leftExternal = externalOrder[lhs] ?? Int.max
            let rightExternal = externalOrder[rhs] ?? Int.max
            if leftExternal != rightExternal {
                return leftExternal < rightExternal
            }
            let leftDegree = degree[lhs] ?? 0
            let rightDegree = degree[rhs] ?? 0
            if leftDegree != rightDegree {
                return leftDegree > rightDegree
            }
            return lhs < rhs
        }

        var cursor: CGFloat = 0
        var positions: [Int: CGPoint] = [:]
        positions.reserveCapacity(indices.count)
        for (offset, index) in ordered.enumerated() {
            if offset > 0 {
                cursor += verticalGroupNodeGap(
                    between: ordered[offset - 1],
                    and: index,
                    edges: localEdges
                )
            }
            cursor += sizes[index].height / 2
            positions[index] = CGPoint(x: 0, y: cursor)
            cursor += sizes[index].height / 2
        }
        return LayeredComponentLayout(
            indices: indices,
            positions: positions,
            rect: componentRect(indices: indices, positions: positions, sizes: sizes)
        )
    }

    private static func verticalGroupNodeGap(
        between lhs: Int,
        and rhs: Int,
        edges: [LayeredEdge]
    ) -> CGFloat {
        let multiplicity = edges.reduce(0) { partial, edge in
            let matchesForward = edge.source == lhs && edge.target == rhs
            let matchesBackward = edge.source == rhs && edge.target == lhs
            return partial + (matchesForward || matchesBackward ? 1 : 0)
        }
        guard multiplicity > 0 else {
            return LayoutSpacing.groupInternalNodeNodeVertical
        }
        let parallelReserve = CGFloat(max(multiplicity - 1, 0)) * LayoutSpacing.edgeEdge
        return max(
            LayoutSpacing.groupInternalNodeNodeVertical,
            LayoutSpacing.groupInternalConnectedNodeNodeVertical + parallelReserve
        )
    }

    private static func externalEdgeOrder(
        indices: [Int],
        edges: [LayeredEdge]
    ) -> [Int: Int] {
        let indexSet = Set(indices)
        var result: [Int: Int] = [:]
        for edge in edges {
            let sourceInside = indexSet.contains(edge.source)
            let targetInside = indexSet.contains(edge.target)
            guard sourceInside != targetInside else { continue }
            let inside = sourceInside ? edge.source : edge.target
            result[inside] = min(result[inside] ?? Int.max, edge.order)
        }
        return result
    }

    private static func makeBlockEdges(
        cardEdges: [LayeredEdge],
        blockByCard: [Int: Int]
    ) -> [LayeredEdge] {
        var result: [LayeredEdge] = []
        result.reserveCapacity(cardEdges.count)
        var bestByPair: [UInt64: LayeredEdge] = [:]
        for edge in cardEdges {
            guard
                let source = blockByCard[edge.source],
                let target = blockByCard[edge.target],
                source != target
            else { continue }
            let key = pairKey(source, target)
            let candidate = LayeredEdge(
                source: source,
                target: target,
                order: edge.order,
                labelSpan: edge.labelSpan,
                sharesGroup: edge.sharesGroup
            )
            if let existing = bestByPair[key] {
                bestByPair[key] = LayeredEdge(
                    source: existing.source,
                    target: existing.target,
                    order: min(existing.order, candidate.order),
                    labelSpan: max(existing.labelSpan, candidate.labelSpan),
                    sharesGroup: existing.sharesGroup && candidate.sharesGroup
                )
            } else {
                bestByPair[key] = candidate
            }
        }
        for edge in bestByPair.values.sorted(by: layeredEdgeSort) {
            result.append(edge)
        }
        return result
    }

    private static func layoutLayeredBlockComponent(
        indices: [Int],
        edges: [LayeredEdge],
        sizes: [CGSize],
        sweepLimit: Int,
        optimizeOutlineWrap: Bool
    ) -> LayeredComponentLayout {
        guard indices.count > 1 else {
            let index = indices[0]
            let positions = [index: CGPoint(x: 0, y: 0)]
            return LayeredComponentLayout(
                indices: indices,
                positions: positions,
                rect: componentRect(indices: indices, positions: positions, sizes: sizes)
            )
        }

        let degree = layeredDegrees(indices: indices, edges: edges)
        var ranks = assignLayerRanks(indices: indices, edges: edges)
        let minRank = ranks.values.min() ?? 0
        for index in ranks.keys {
            ranks[index] = (ranks[index] ?? 0) - minRank
        }
        let rankCount = (ranks.values.max() ?? 0) + 1
        var layers = Array(repeating: [Int](), count: rankCount)
        for index in indices {
            layers[ranks[index] ?? 0].append(index)
        }
        for rank in layers.indices {
            layers[rank].sort { lhs, rhs in
                let leftDegree = degree[lhs] ?? 0
                let rightDegree = degree[rhs] ?? 0
                if leftDegree != rightDegree {
                    return leftDegree > rightDegree
                }
                return lhs < rhs
            }
        }
        layers = reduceLayerCrossingsForBlocks(
            layers: layers,
            ranks: ranks,
            edges: edges,
            degree: degree,
            sweeps: sweepLimit
        )

        let membership = GroupMembershipIndex(memberToGroups: [:], groupMembers: [])
        var positions = assignLayeredCoordinates(
            layers: layers,
            ranks: ranks,
            edges: edges,
            sizes: sizes,
            degree: degree,
            membership: membership,
            optimizeOutlineWrap: optimizeOutlineWrap
        )
        relaxLayeredYCoordinates(
            positions: &positions,
            layers: layers,
            edges: edges,
            sizes: sizes,
            iterations: 8
        )

        return LayeredComponentLayout(
            indices: indices,
            positions: positions,
            rect: componentRect(indices: indices, positions: positions, sizes: sizes)
        )
    }

    private static func layoutLayeredComponent(
        indices: [Int],
        edges: [LayeredEdge],
        sizes: [CGSize],
        membership: GroupMembershipIndex,
        initial: [NodeIdentifier: CGPoint],
        cards: [CompoundGraph.Card],
        sweepLimit: Int,
        optimizeOutlineWrap: Bool
    ) -> LayeredComponentLayout {
        guard indices.count > 1 else {
            let index = indices[0]
            let positions = [index: CGPoint(x: 0, y: 0)]
            return LayeredComponentLayout(
                indices: indices,
                positions: positions,
                rect: componentRect(indices: indices, positions: positions, sizes: sizes)
            )
        }

        let degree = layeredDegrees(indices: indices, edges: edges)
        var ranks = assignLayerRanks(indices: indices, edges: edges)
        let minRank = ranks.values.min() ?? 0
        for index in ranks.keys {
            ranks[index] = (ranks[index] ?? 0) - minRank
        }

        let rankCount = (ranks.values.max() ?? 0) + 1
        var layers = Array(repeating: [Int](), count: rankCount)
        for index in indices {
            let rank = ranks[index] ?? 0
            layers[rank].append(index)
        }
        for rank in layers.indices {
            layers[rank].sort {
                layeredInitialOrder(
                    lhs: $0,
                    rhs: $1,
                    membership: membership,
                    degree: degree,
                    initial: initial,
                    cards: cards
                )
            }
        }

        layers = reduceLayerCrossings(
            layers: layers,
            ranks: ranks,
            edges: edges,
            membership: membership,
            degree: degree,
            initial: initial,
            cards: cards,
            sweeps: sweepLimit
        )

        var positions = assignLayeredCoordinates(
            layers: layers,
            ranks: ranks,
            edges: edges,
            sizes: sizes,
            degree: degree,
            membership: membership,
            optimizeOutlineWrap: optimizeOutlineWrap
        )
        relaxLayeredYCoordinates(
            positions: &positions,
            layers: layers,
            edges: edges,
            sizes: sizes,
            iterations: 10
        )

        return LayeredComponentLayout(
            indices: indices,
            positions: positions,
            rect: componentRect(indices: indices, positions: positions, sizes: sizes)
        )
    }

    private static func layeredDegrees(
        indices: [Int],
        edges: [LayeredEdge]
    ) -> [Int: Int] {
        var result = Dictionary(uniqueKeysWithValues: indices.map { ($0, 0) })
        var seenPairs: Set<UInt64> = []
        for edge in edges where edge.source != edge.target {
            let key = pairKey(edge.source, edge.target)
            guard seenPairs.insert(key).inserted else { continue }
            result[edge.source, default: 0] += 1
            result[edge.target, default: 0] += 1
        }
        return result
    }

    private static func assignLayerRanks(
        indices: [Int],
        edges: [LayeredEdge]
    ) -> [Int: Int] {
        let localByGlobal = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        let globalByLocal = indices
        var dag = Array(repeating: Set<Int>(), count: indices.count)
        var seenDirected: Set<UInt64> = []

        for edge in edges.sorted(by: layeredEdgeSort) {
            guard
                let source = localByGlobal[edge.source],
                let target = localByGlobal[edge.target],
                source != target
            else { continue }
            let directedKey = (UInt64(source) << 32) | UInt64(target)
            guard seenDirected.insert(directedKey).inserted else { continue }

            if !pathExists(from: target, to: source, adjacency: dag) {
                dag[source].insert(target)
            } else if !pathExists(from: source, to: target, adjacency: dag) {
                dag[target].insert(source)
            }
        }

        var indegree = Array(repeating: 0, count: indices.count)
        for source in dag.indices {
            for target in dag[source] {
                indegree[target] += 1
            }
        }

        var queue = indegree.indices
            .filter { indegree[$0] == 0 }
            .sorted { globalByLocal[$0] < globalByLocal[$1] }
        var cursor = 0
        var rank = Array(repeating: 0, count: indices.count)
        while cursor < queue.count {
            let source = queue[cursor]
            cursor += 1
            for target in dag[source].sorted(by: { globalByLocal[$0] < globalByLocal[$1] }) {
                rank[target] = max(rank[target], rank[source] + 1)
                indegree[target] -= 1
                if indegree[target] == 0 {
                    queue.append(target)
                    queue[cursor...].sort { globalByLocal[$0] < globalByLocal[$1] }
                }
            }
        }

        return Dictionary(uniqueKeysWithValues: indices.enumerated().map { offset, global in
            (global, rank[offset])
        })
    }

    private static func pathExists(
        from start: Int,
        to target: Int,
        adjacency: [Set<Int>]
    ) -> Bool {
        if start == target { return true }
        var visited: Set<Int> = [start]
        var stack = [start]
        while let node = stack.popLast() {
            for next in adjacency[node] where !visited.contains(next) {
                if next == target { return true }
                visited.insert(next)
                stack.append(next)
            }
        }
        return false
    }

    private static func layeredEdgeSort(_ lhs: LayeredEdge, _ rhs: LayeredEdge) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        return lhs.target < rhs.target
    }

    private static func layeredInitialOrder(
        lhs: Int,
        rhs: Int,
        membership: GroupMembershipIndex,
        degree: [Int: Int],
        initial: [NodeIdentifier: CGPoint],
        cards: [CompoundGraph.Card]
    ) -> Bool {
        let leftGroup = primaryGroupIndex(lhs, membership: membership)
        let rightGroup = primaryGroupIndex(rhs, membership: membership)
        if leftGroup != rightGroup {
            return leftGroup < rightGroup
        }
        let leftInitial = initial[cards[lhs].id.nodeID]
        let rightInitial = initial[cards[rhs].id.nodeID]
        if let leftInitial, let rightInitial, leftInitial.y != rightInitial.y {
            return leftInitial.y < rightInitial.y
        }
        let leftDegree = degree[lhs] ?? 0
        let rightDegree = degree[rhs] ?? 0
        if leftDegree != rightDegree {
            return leftDegree > rightDegree
        }
        return lhs < rhs
    }

    private static func primaryGroupIndex(
        _ index: Int,
        membership: GroupMembershipIndex
    ) -> Int {
        membership.memberToGroups[index]?.min() ?? Int.max
    }

    private static func reduceLayerCrossings(
        layers inputLayers: [[Int]],
        ranks: [Int: Int],
        edges: [LayeredEdge],
        membership: GroupMembershipIndex,
        degree: [Int: Int],
        initial: [NodeIdentifier: CGPoint],
        cards: [CompoundGraph.Card],
        sweeps: Int
    ) -> [[Int]] {
        guard inputLayers.count > 1 else { return inputLayers }
        var layers = inputLayers

        for _ in 0..<sweeps {
            for rank in 1..<layers.count {
                sortLayerByBarycenter(
                    layer: &layers[rank],
                    ranks: ranks,
                    referenceRanks: Set(0..<rank),
                    layers: layers,
                    edges: edges,
                    membership: membership,
                    degree: degree,
                    initial: initial,
                    cards: cards
                )
            }
            if layers.count > 1 {
                for rank in stride(from: layers.count - 2, through: 0, by: -1) {
                    sortLayerByBarycenter(
                        layer: &layers[rank],
                        ranks: ranks,
                        referenceRanks: Set((rank + 1)..<layers.count),
                        layers: layers,
                        edges: edges,
                        membership: membership,
                        degree: degree,
                        initial: initial,
                        cards: cards
                    )
                }
            }
        }
        return layers
    }

    private static func sortLayerByBarycenter(
        layer: inout [Int],
        ranks: [Int: Int],
        referenceRanks: Set<Int>,
        layers: [[Int]],
        edges: [LayeredEdge],
        membership: GroupMembershipIndex,
        degree: [Int: Int],
        initial: [NodeIdentifier: CGPoint],
        cards: [CompoundGraph.Card]
    ) {
        let order = layerOrderMap(layers)
        func barycenter(for node: Int) -> Double? {
            var total = 0.0
            var count = 0.0
            for edge in edges {
                let other: Int
                if edge.source == node {
                    other = edge.target
                } else if edge.target == node {
                    other = edge.source
                } else {
                    continue
                }
                guard let rank = ranks[other], referenceRanks.contains(rank) else { continue }
                total += order[other] ?? 0
                count += 1
            }
            guard count > 0 else { return nil }
            return total / count
        }

        layer.sort { lhs, rhs in
            let leftBarycenter = barycenter(for: lhs)
            let rightBarycenter = barycenter(for: rhs)
            switch (leftBarycenter, rightBarycenter) {
            case let (left?, right?) where abs(left - right) > 0.0001:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return layeredInitialOrder(
                    lhs: lhs,
                    rhs: rhs,
                    membership: membership,
                    degree: degree,
                    initial: initial,
                    cards: cards
                )
            }
        }
    }

    private static func reduceLayerCrossingsForBlocks(
        layers inputLayers: [[Int]],
        ranks: [Int: Int],
        edges: [LayeredEdge],
        degree: [Int: Int],
        sweeps: Int
    ) -> [[Int]] {
        guard inputLayers.count > 1 else { return inputLayers }
        var layers = inputLayers
        for _ in 0..<sweeps {
            for rank in 1..<layers.count {
                sortBlockLayerByBarycenter(
                    layer: &layers[rank],
                    ranks: ranks,
                    referenceRanks: Set(0..<rank),
                    layers: layers,
                    edges: edges,
                    degree: degree
                )
            }
            if layers.count > 1 {
                for rank in stride(from: layers.count - 2, through: 0, by: -1) {
                    sortBlockLayerByBarycenter(
                        layer: &layers[rank],
                        ranks: ranks,
                        referenceRanks: Set((rank + 1)..<layers.count),
                        layers: layers,
                        edges: edges,
                        degree: degree
                    )
                }
            }
        }
        return layers
    }

    private static func sortBlockLayerByBarycenter(
        layer: inout [Int],
        ranks: [Int: Int],
        referenceRanks: Set<Int>,
        layers: [[Int]],
        edges: [LayeredEdge],
        degree: [Int: Int]
    ) {
        let order = layerOrderMap(layers)
        func barycenter(for node: Int) -> Double? {
            var total = 0.0
            var count = 0.0
            for edge in edges {
                let other: Int
                if edge.source == node {
                    other = edge.target
                } else if edge.target == node {
                    other = edge.source
                } else {
                    continue
                }
                guard let rank = ranks[other], referenceRanks.contains(rank) else { continue }
                total += order[other] ?? 0
                count += 1
            }
            guard count > 0 else { return nil }
            return total / count
        }

        layer.sort { lhs, rhs in
            let leftBarycenter = barycenter(for: lhs)
            let rightBarycenter = barycenter(for: rhs)
            switch (leftBarycenter, rightBarycenter) {
            case let (left?, right?) where abs(left - right) > 0.0001:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let leftDegree = degree[lhs] ?? 0
                let rightDegree = degree[rhs] ?? 0
                if leftDegree != rightDegree {
                    return leftDegree > rightDegree
                }
                return lhs < rhs
            }
        }
    }

    private static func layerOrderMap(_ layers: [[Int]]) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for layer in layers {
            for (offset, node) in layer.enumerated() {
                result[node] = Double(offset)
            }
        }
        return result
    }

    private static func assignLayeredCoordinates(
        layers: [[Int]],
        ranks: [Int: Int],
        edges: [LayeredEdge],
        sizes: [CGSize],
        degree: [Int: Int],
        membership: GroupMembershipIndex,
        optimizeOutlineWrap: Bool
    ) -> [Int: CGPoint] {
        struct RankBand {
            let ranks: [Int]
            let width: Double
            let height: Double
        }

        let rankWidths = layers.map { layer in
            layer.map { Double(sizes[$0].width) }.max() ?? 0
        }
        let gapBeforeRank = layers.indices.map { rank in
            rank == 0 ? 0.0 : layerGap(
                before: rank,
                ranks: ranks,
                edges: edges,
                degree: degree,
                membership: membership
            )
        }

        var layerHeights: [Double] = []
        layerHeights.reserveCapacity(layers.count)
        for layer in layers {
            guard !layer.isEmpty else {
                layerHeights.append(0)
                continue
            }
            var height = 0.0
            for (offset, index) in layer.enumerated() {
                if offset > 0 {
                    height += verticalGap(
                        between: layer[offset - 1],
                        and: index,
                        degree: degree,
                        membership: membership
                    )
                }
                height += Double(sizes[index].height)
            }
            layerHeights.append(height)
        }

        let tallestRank = max(layerHeights.max() ?? 0, 1.0)
        let bandGap = max(118.0, tallestRank * 0.34)
        let bands: [RankBand]
        if optimizeOutlineWrap {
            bands = optimizedRankBands(
                rankWidths: rankWidths,
                rankHeights: layerHeights,
                gapBeforeRank: gapBeforeRank,
                bandGap: bandGap
            ).map { band in
                RankBand(ranks: band.ranks, width: band.width, height: band.height)
            }
        } else {
            bands = greedyRankBands(
                rankWidths: rankWidths,
                rankHeights: layerHeights,
                gapBeforeRank: gapBeforeRank
            ).map { band in
                RankBand(ranks: band.ranks, width: band.width, height: band.height)
            }
        }

        var xByRank = Array(repeating: 0.0, count: layers.count)
        var yBaseByRank = Array(repeating: 0.0, count: layers.count)
        var bandTop = 0.0
        for (bandIndex, band) in bands.enumerated() {
            var cursor = 0.0
            for (offset, rank) in band.ranks.enumerated() {
                if offset > 0 {
                    cursor += gapBeforeRank[rank]
                }
                let centerX = cursor + rankWidths[rank] * 0.5
                xByRank[rank] = bandIndex.isMultiple(of: 2)
                    ? centerX
                    : band.width - centerX
                yBaseByRank[rank] = bandTop + band.height * 0.5
                cursor += rankWidths[rank]
            }
            bandTop += band.height + bandGap
        }

        var positions: [Int: CGPoint] = [:]
        for (rank, layer) in layers.enumerated() {
            var yCursor = yBaseByRank[rank] - layerHeights[rank] * 0.5
            for (offset, index) in layer.enumerated() {
                if offset > 0 {
                    yCursor += verticalGap(
                        between: layer[offset - 1],
                        and: index,
                        degree: degree,
                        membership: membership
                    )
                }
                yCursor += Double(sizes[index].height) * 0.5
                positions[index] = CGPoint(x: xByRank[rank], y: yCursor)
                yCursor += Double(sizes[index].height) * 0.5
            }
        }
        return positions
    }

    private struct OptimizedRankBand {
        let ranks: [Int]
        let width: Double
        let height: Double
    }

    private static func greedyRankBands(
        rankWidths: [Double],
        rankHeights: [Double],
        gapBeforeRank: [Double]
    ) -> [OptimizedRankBand] {
        guard !rankWidths.isEmpty else { return [] }
        let targetAspect = 1.5
        let unwrappedWidth = rankWidths.enumerated().reduce(0.0) { partial, entry in
            partial + entry.element + (entry.offset == 0 ? 0.0 : gapBeforeRank[entry.offset])
        }
        let tallestRank = max(rankHeights.max() ?? 0, 1.0)
        let widestAdjacentPair = rankWidths.indices.dropLast().reduce(0.0) { partial, rank in
            max(partial, rankWidths[rank] + gapBeforeRank[rank + 1] + rankWidths[rank + 1])
        }
        let widestThreeRankRun = rankWidths.indices.dropLast(2).reduce(0.0) { partial, rank in
            max(
                partial,
                rankWidths[rank]
                    + gapBeforeRank[rank + 1]
                    + rankWidths[rank + 1]
                    + gapBeforeRank[rank + 2]
                    + rankWidths[rank + 2]
            )
        }
        let minimumWrappedWidth = rankWidths.count >= 6
            ? max(widestAdjacentPair, widestThreeRankRun)
            : widestAdjacentPair
        let targetWidth = min(
            max(max(920.0, minimumWrappedWidth), sqrt(unwrappedWidth * tallestRank * targetAspect) * 1.25),
            max(unwrappedWidth, 920.0)
        )
        let unwrappedAspect = unwrappedWidth / tallestRank
        let shouldWrap = rankWidths.count >= 3
            && unwrappedWidth > 760
            && unwrappedAspect > targetAspect * 1.35
        let wrapWidth = shouldWrap ? targetWidth : Double.greatestFiniteMagnitude

        var bands: [OptimizedRankBand] = []
        var currentRanks: [Int] = []
        var currentWidth = 0.0
        var currentHeight = 0.0
        func finishBand() {
            guard !currentRanks.isEmpty else { return }
            bands.append(OptimizedRankBand(
                ranks: currentRanks,
                width: currentWidth,
                height: currentHeight
            ))
            currentRanks.removeAll(keepingCapacity: true)
            currentWidth = 0
            currentHeight = 0
        }

        for rank in rankWidths.indices {
            let addedWidth = currentRanks.isEmpty
                ? rankWidths[rank]
                : gapBeforeRank[rank] + rankWidths[rank]
            if !currentRanks.isEmpty, currentWidth + addedWidth > wrapWidth {
                finishBand()
            }
            currentRanks.append(rank)
            currentWidth += currentRanks.count == 1 ? rankWidths[rank] : gapBeforeRank[rank] + rankWidths[rank]
            currentHeight = max(currentHeight, rankHeights[rank])
        }
        finishBand()
        return bands
    }

    private struct RankBandLayoutScore {
        let aspectViolation: Double
        let area: Double
        let aspectDelta: Double
        let bandCount: Int

        func isBetter(than other: RankBandLayoutScore) -> Bool {
            if abs(aspectViolation - other.aspectViolation) > 0.001 {
                return aspectViolation < other.aspectViolation
            }
            if abs(area - other.area) > 0.001 {
                return area < other.area
            }
            if abs(aspectDelta - other.aspectDelta) > 0.001 {
                return aspectDelta < other.aspectDelta
            }
            return bandCount < other.bandCount
        }
    }

    private struct RankBandDPState {
        let height: Double
        let previousRank: Int
    }

    private static func optimizedRankBands(
        rankWidths: [Double],
        rankHeights: [Double],
        gapBeforeRank: [Double],
        bandGap: Double
    ) -> [OptimizedRankBand] {
        let rankCount = rankWidths.count
        guard rankCount > 0 else { return [] }
        guard rankCount > 1 else {
            return [OptimizedRankBand(ranks: [0], width: rankWidths[0], height: rankHeights[0])]
        }
        guard rankCount > 2 else {
            return greedyRankBands(
                rankWidths: rankWidths,
                rankHeights: rankHeights,
                gapBeforeRank: gapBeforeRank
            )
        }

        let bandOptions = rankBandOptions(
            rankWidths: rankWidths,
            rankHeights: rankHeights,
            gapBeforeRank: gapBeforeRank
        )
        let candidateWidths = sortedUniqueDoubleValues(bandOptions.flatMap { row in
            row.compactMap { $0?.width }
        })
        var bestBands: [OptimizedRankBand] = []
        var bestScore: RankBandLayoutScore?

        for maximumWidth in candidateWidths {
            guard let bands = optimalRankBandPartition(
                bandOptions: bandOptions,
                maximumWidth: maximumWidth,
                bandGap: bandGap
            ) else { continue }
            let width = bands.map(\.width).max() ?? 0
            let height = bands.enumerated().reduce(0.0) { partial, entry in
                partial + entry.element.height + (entry.offset == 0 ? 0.0 : bandGap)
            }
            guard width > 0, height > 0 else { continue }
            let aspect = width / height
            let targetAspect = 1.5
            let minAspect = 0.95
            let maxAspect = 2.05
            let aspectViolation = max(minAspect - aspect, 0) + max(aspect - maxAspect, 0)
            let score = RankBandLayoutScore(
                aspectViolation: aspectViolation,
                area: width * height,
                aspectDelta: abs(aspect - targetAspect),
                bandCount: bands.count
            )
            if bestScore.map({ score.isBetter(than: $0) }) ?? true {
                bestScore = score
                bestBands = bands
            }
        }

        return bestBands.isEmpty
            ? [OptimizedRankBand(ranks: Array(0..<rankCount), width: rankWidths.reduce(0, +), height: rankHeights.max() ?? 0)]
            : bestBands
    }

    private static func rankBandOptions(
        rankWidths: [Double],
        rankHeights: [Double],
        gapBeforeRank: [Double]
    ) -> [[OptimizedRankBand?]] {
        let count = rankWidths.count
        var options = Array(
            repeating: Array<OptimizedRankBand?>(repeating: nil, count: count),
            count: count
        )
        for start in 0..<count {
            var width = 0.0
            var height = 0.0
            for end in start..<count {
                width += end == start ? rankWidths[end] : gapBeforeRank[end] + rankWidths[end]
                height = max(height, rankHeights[end])
                options[start][end] = OptimizedRankBand(
                    ranks: Array(start...end),
                    width: width,
                    height: height
                )
            }
        }
        return options
    }

    private static func optimalRankBandPartition(
        bandOptions: [[OptimizedRankBand?]],
        maximumWidth: Double,
        bandGap: Double
    ) -> [OptimizedRankBand]? {
        let count = bandOptions.count
        var states = Array<RankBandDPState?>(repeating: nil, count: count + 1)
        states[0] = RankBandDPState(height: 0, previousRank: -1)
        for end in 1...count {
            var best: RankBandDPState?
            for start in 0..<end {
                guard
                    let prior = states[start],
                    let band = bandOptions[start][end - 1],
                    band.width <= maximumWidth + 0.001
                else { continue }
                let addedGap = start == 0 ? 0.0 : bandGap
                let candidate = RankBandDPState(
                    height: prior.height + addedGap + band.height,
                    previousRank: start
                )
                if best == nil || candidate.height < (best?.height ?? .greatestFiniteMagnitude) {
                    best = candidate
                }
            }
            states[end] = best
        }
        guard states[count] != nil else { return nil }

        var bands: [OptimizedRankBand] = []
        var end = count
        while end > 0 {
            guard
                let state = states[end],
                let band = bandOptions[state.previousRank][end - 1]
            else { return nil }
            bands.append(band)
            end = state.previousRank
        }
        return bands.reversed()
    }

    private static func sortedUniqueDoubleValues(_ values: [Double]) -> [Double] {
        var result: [Double] = []
        for value in values.sorted() {
            if !result.contains(where: { abs($0 - value) < 0.5 }) {
                result.append(value)
            }
        }
        return result
    }

    private static func layerGap(
        before rank: Int,
        ranks: [Int: Int],
        edges: [LayeredEdge],
        degree: [Int: Int],
        membership: GroupMembershipIndex
    ) -> Double {
        var gap = Double(LayoutSpacing.nodeNodeHorizontal)
        for edge in edges {
            guard let sourceRank = ranks[edge.source], let targetRank = ranks[edge.target] else {
                continue
            }
            let minRank = min(sourceRank, targetRank)
            let maxRank = max(sourceRank, targetRank)
            guard minRank < rank && rank <= maxRank else { continue }
            let degreeLoad = log2(Double(max(degree[edge.source] ?? 0, degree[edge.target] ?? 0)) + 1.0)
            let labelGap = edge.labelSpan
                + Double(LayoutSpacing.edgeNode * 2)
                + min(72.0, degreeLoad * Double(LayoutSpacing.edgeEdge))
            gap = max(gap, min(260.0, labelGap))
            if !edge.sharesGroup, !shareAnyGroup(edge.source, edge.target, membership: membership) {
                gap = max(gap, Double(LayoutSpacing.nodeNodeHorizontal))
            }
        }
        return gap
    }

    private static func verticalGap(
        between lhs: Int,
        and rhs: Int,
        degree: [Int: Int],
        membership: GroupMembershipIndex
    ) -> Double {
        let degreeLoad = log2(Double(max(degree[lhs] ?? 0, degree[rhs] ?? 0)) + 1.0)
        var gap = Double(LayoutSpacing.nodeNodeVertical) + min(34.0, degreeLoad * 7.0)
        let leftGroups = membership.memberToGroups[lhs] ?? []
        let rightGroups = membership.memberToGroups[rhs] ?? []
        if !leftGroups.isEmpty, !rightGroups.isEmpty, leftGroups.isDisjoint(with: rightGroups) {
            gap += Double(LayoutSpacing.groupGroup - LayoutSpacing.nodeNodeVertical)
        }
        return gap
    }

    private static func shareAnyGroup(
        _ lhs: Int,
        _ rhs: Int,
        membership: GroupMembershipIndex
    ) -> Bool {
        guard
            let leftGroups = membership.memberToGroups[lhs],
            let rightGroups = membership.memberToGroups[rhs]
        else { return false }
        return !leftGroups.isDisjoint(with: rightGroups)
    }

    private static func relaxLayeredYCoordinates(
        positions: inout [Int: CGPoint],
        layers: [[Int]],
        edges: [LayeredEdge],
        sizes: [CGSize],
        iterations: Int
    ) {
        guard layers.count > 1, iterations > 0 else { return }
        var neighbours: [Int: [Int]] = [:]
        for edge in edges {
            neighbours[edge.source, default: []].append(edge.target)
            neighbours[edge.target, default: []].append(edge.source)
        }

        for _ in 0..<iterations {
            for layer in layers {
                guard layer.count > 1 else { continue }
                var desired: [Int: Double] = [:]
                for index in layer {
                    let ys = (neighbours[index] ?? []).compactMap { positions[$0].map { Double($0.y) } }
                    guard !ys.isEmpty, let current = positions[index] else { continue }
                    let average = ys.reduce(0, +) / Double(ys.count)
                    desired[index] = Double(current.y) * 0.55 + average * 0.45
                }

                var laidOut: [(index: Int, y: Double)] = []
                laidOut.reserveCapacity(layer.count)
                for index in layer {
                    let y = desired[index] ?? Double(positions[index]?.y ?? 0)
                    laidOut.append((index, y))
                }
                let targetCenter = layer.compactMap { positions[$0].map { Double($0.y) } }
                    .reduce(0, +) / Double(layer.count)
                for offset in 1..<laidOut.count {
                    let previous = laidOut[offset - 1]
                    let current = laidOut[offset]
                    let minDistance = Double(sizes[previous.index].height + sizes[current.index].height) * 0.5
                        + Double(LayoutSpacing.nodeNodeVertical)
                    if current.y < previous.y + minDistance {
                        laidOut[offset].y = previous.y + minDistance
                    }
                }
                let center = laidOut.reduce(0.0) { $0 + $1.y } / Double(laidOut.count)
                for entry in laidOut {
                    guard var point = positions[entry.index] else { continue }
                    point.y = CGFloat(targetCenter + entry.y - center)
                    positions[entry.index] = point
                }
            }
        }
    }

    private static func componentRect(
        indices: [Int],
        positions: [Int: CGPoint],
        sizes: [CGSize]
    ) -> CGRect {
        var rect = CGRect.null
        for index in indices {
            guard let center = positions[index] else { continue }
            let cardRect = CGRect(
                x: center.x - sizes[index].width / 2,
                y: center.y - sizes[index].height / 2,
                width: sizes[index].width,
                height: sizes[index].height
            )
            rect = rect.isNull ? cardRect : rect.union(cardRect)
        }
        return rect
    }

    private static func packLayeredComponents(
        _ layouts: [LayeredComponentLayout],
        sizes: [CGSize],
        cardCount: Int
    ) -> [CGPoint] {
        var result = Array(repeating: CGPoint.zero, count: cardCount)
        guard !layouts.isEmpty else { return result }

        let totalArea = layouts.reduce(0.0) { partial, layout in
            partial + Double(max(layout.rect.width, 1) * max(layout.rect.height, 1))
        }
        let maxShelfWidth = max(820.0, sqrt(totalArea) * 1.85)
        let componentGapX: CGFloat = 180
        let componentGapY: CGFloat = 150
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var shelfHeight: CGFloat = 0

        for layout in layouts {
            let width = layout.rect.width
            let height = layout.rect.height
            if cursorX > 0, Double(cursorX + width) > maxShelfWidth {
                cursorX = 0
                cursorY += shelfHeight + componentGapY
                shelfHeight = 0
            }
            let shiftX = cursorX - layout.rect.minX
            let shiftY = cursorY - layout.rect.minY
            for index in layout.indices {
                if let point = layout.positions[index] {
                    result[index] = CGPoint(x: point.x + shiftX, y: point.y + shiftY)
                }
            }
            cursorX += width + componentGapX
            shelfHeight = max(shelfHeight, height)
        }
        return result
    }

    private static func finalizeLayeredLayout(
        positions: inout [CGPoint],
        sizes: [CGSize],
        radii: [Double],
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) {
        let sameGroupPairs = sameGroupPairKeys(groups: groups, indexByID: indexByID)
        resolveOverlaps(
            positions: &positions,
            sizes: sizes,
            horizontalMargin: LayoutSpacing.nodeNodeHorizontal,
            verticalMargin: LayoutSpacing.nodeNodeVertical,
            sameGroupPairs: sameGroupPairs,
            iterations: 36
        )
        resolveLayeredGroupGaps(
            positions: &positions,
            sizes: sizes,
            edges: edges,
            groups: groups,
            indexByID: indexByID,
            iterations: 18
        )
        ejectNonMembersFromGroups(
            positions: &positions,
            sizes: sizes,
            groups: groups,
            indexByID: indexByID
        )
        resolveGroupOverlaps(
            positions: &positions,
            sizes: sizes,
            groups: groups,
            indexByID: indexByID,
            margin: LayoutSpacing.groupGroup,
            iterations: 54
        )
        compactSparseGroups(
            positions: &positions,
            radii: radii,
            edges: edges,
            groups: groups,
            indexByID: indexByID,
            cardCount: sizes.count,
            iterations: 20
        )
        resolveOverlaps(
            positions: &positions,
            sizes: sizes,
            horizontalMargin: LayoutSpacing.nodeNodeHorizontal,
            verticalMargin: LayoutSpacing.nodeNodeVertical,
            sameGroupPairs: sameGroupPairs,
            iterations: 42
        )
        resolveLayeredGroupGaps(
            positions: &positions,
            sizes: sizes,
            edges: edges,
            groups: groups,
            indexByID: indexByID,
            iterations: 12
        )
        enforceLayoutDistanceConstraints(
            positions: &positions,
            sizes: sizes,
            edges: edges,
            groups: groups,
            indexByID: indexByID,
            iterations: 12
        )
        minimizeConstrainedOutlineArea(
            positions: &positions,
            sizes: sizes,
            edges: edges,
            groups: groups,
            indexByID: indexByID
        )
        enforceLayoutDistanceConstraints(
            positions: &positions,
            sizes: sizes,
            edges: edges,
            groups: groups,
            indexByID: indexByID,
            iterations: 16
        )
    }

    private struct LayeredGroupBox {
        let groupIndex: Int
        let indices: [Int]
        let memberSet: Set<Int>
        var rect: CGRect
    }

    private static func resolveLayeredGroupGaps(
        positions: inout [CGPoint],
        sizes: [CGSize],
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int],
        iterations: Int
    ) {
        guard groups.count > 1, iterations > 0 else { return }
        let groupEdgeCounts = disjointGroupEdgeCounts(
            edges: edges,
            groups: groups,
            indexByID: indexByID
        )

        for _ in 0..<iterations {
            var boxes = layeredGroupBoxes(
                positions: positions,
                sizes: sizes,
                groups: groups,
                indexByID: indexByID
            )
            guard boxes.count > 1 else { return }
            var moved = false
            for a in 0..<(boxes.count - 1) {
                for b in (a + 1)..<boxes.count {
                    guard boxes[a].memberSet.isDisjoint(with: boxes[b].memberSet) else {
                        continue
                    }
                    let pair = pairKey(boxes[a].groupIndex, boxes[b].groupIndex)
                    let targetGap = minimumGroupGroupGap(edgeCount: groupEdgeCounts[pair] ?? 0)
                    let expandedA = boxes[a].rect.insetBy(dx: -targetGap / 2, dy: -targetGap / 2)
                    let expandedB = boxes[b].rect.insetBy(dx: -targetGap / 2, dy: -targetGap / 2)
                    let intersection = expandedA.intersection(expandedB)
                    guard
                        !intersection.isNull,
                        intersection.width > 0,
                        intersection.height > 0
                    else { continue }

                    if intersection.width < intersection.height {
                        let direction: CGFloat
                        if abs(boxes[a].rect.midX - boxes[b].rect.midX) < 0.001 {
                            direction = boxes[a].groupIndex < boxes[b].groupIndex ? 1 : -1
                        } else {
                            direction = boxes[a].rect.midX < boxes[b].rect.midX ? 1 : -1
                        }
                        let shift = intersection.width * 0.5 * 0.72
                        translate(indices: boxes[a].indices, dx: -direction * shift, dy: 0, positions: &positions)
                        translate(indices: boxes[b].indices, dx: direction * shift, dy: 0, positions: &positions)
                        boxes[a].rect.origin.x -= direction * shift
                        boxes[b].rect.origin.x += direction * shift
                    } else {
                        let direction: CGFloat
                        if abs(boxes[a].rect.midY - boxes[b].rect.midY) < 0.001 {
                            direction = boxes[a].groupIndex < boxes[b].groupIndex ? 1 : -1
                        } else {
                            direction = boxes[a].rect.midY < boxes[b].rect.midY ? 1 : -1
                        }
                        let shift = intersection.height * 0.5 * 0.72
                        translate(indices: boxes[a].indices, dx: 0, dy: -direction * shift, positions: &positions)
                        translate(indices: boxes[b].indices, dx: 0, dy: direction * shift, positions: &positions)
                        boxes[a].rect.origin.y -= direction * shift
                        boxes[b].rect.origin.y += direction * shift
                    }
                    moved = true
                }
            }
            if !moved { break }
        }
    }

    private static func layeredGroupBoxes(
        positions: [CGPoint],
        sizes: [CGSize],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> [LayeredGroupBox] {
        var result: [LayeredGroupBox] = []
        result.reserveCapacity(groups.count)
        for (groupIndex, group) in groups.enumerated() where group.cohesionStrength > 0 {
            var indices: [Int] = []
            indices.reserveCapacity(group.members.count)
            for member in group.members {
                if let index = indexByID[member] {
                    indices.append(index)
                }
            }
            guard !indices.isEmpty else { continue }
            var rect = CGRect.null
            for index in indices {
                let center = positions[index]
                let cardRect = CGRect(
                    x: center.x - sizes[index].width / 2,
                    y: center.y - sizes[index].height / 2,
                    width: sizes[index].width,
                    height: sizes[index].height
                )
                rect = rect.isNull ? cardRect : rect.union(cardRect)
            }
            let padded = rect.insetBy(
                dx: -group.style.padding,
                dy: -group.style.padding
            )
            result.append(LayeredGroupBox(
                groupIndex: groupIndex,
                indices: indices,
                memberSet: Set(indices),
                rect: padded
            ))
        }
        return result
    }

    private static func linkedDisjointGroupPairs(
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> Set<UInt64> {
        let membership = groupMembershipIndex(groups: groups, indexByID: indexByID)
        var result: Set<UInt64> = []
        for edge in edges {
            guard
                let source = indexByID[edge.source],
                let target = indexByID[edge.target],
                source != target,
                let sourceGroups = membership.memberToGroups[source],
                let targetGroups = membership.memberToGroups[target]
            else { continue }
            if !sourceGroups.isDisjoint(with: targetGroups) {
                continue
            }
            for sourceGroup in sourceGroups {
                for targetGroup in targetGroups where sourceGroup != targetGroup {
                    guard groups.indices.contains(sourceGroup), groups.indices.contains(targetGroup) else {
                        continue
                    }
                    let sourceMembers = Set(membership.groupMembers[sourceGroup])
                    let targetMembers = Set(membership.groupMembers[targetGroup])
                    if sourceMembers.isDisjoint(with: targetMembers) {
                        result.insert(pairKey(sourceGroup, targetGroup))
                    }
                }
            }
        }
        return result
    }

    private static func translate(
        indices: [Int],
        dx: CGFloat,
        dy: CGFloat,
        positions: inout [CGPoint]
    ) {
        for index in indices {
            positions[index].x += dx
            positions[index].y += dy
        }
    }

    // MARK: - Constraint layout model

    private struct LayoutPlan: Sendable {
        let sizes: [CGSize]
        let radii: [Double]
        let baseGap: Double
        let nodeBudgets: [NodeBudget]
        let edgeSprings: [LayoutSpring]
        let groupSprings: [LayoutSpring]
        let groups: [GroupPlan]
        let linkedGroupPairs: Set<UInt64>
    }

    private struct NodeBudget: Sendable {
        let degree: Int
        let personalRadius: Double
    }

    private struct LayoutSpring: Sendable {
        let i: Int
        let j: Int
        let ideal: Double
        let boundaryGap: Double?
        let strength: Double
        let axisBias: Double
    }

    private struct GroupPlan: Sendable {
        let indices: [Int]
        let memberSet: Set<Int>
        let padding: Double
        let cohesionStrength: Double
    }

    private static func makeLayoutPlan(
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        radii: [Double],
        sizes: [CGSize],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> LayoutPlan {
        let n = radii.count
        let baseGap = adaptiveEdgeGap(cardCount: n)

        var groupPlans: [GroupPlan] = []
        groupPlans.reserveCapacity(groups.count)
        for group in groups {
            let indices = group.members.compactMap { indexByID[$0] }
            guard !indices.isEmpty else { continue }
            groupPlans.append(GroupPlan(
                indices: indices,
                memberSet: Set(indices),
                padding: Double(group.style.padding),
                cohesionStrength: group.cohesionStrength
            ))
        }

        var memberToGroups: [Int: Set<Int>] = [:]
        for (groupIndex, group) in groupPlans.enumerated() {
            for index in group.indices {
                memberToGroups[index, default: []].insert(groupIndex)
            }
        }

        var degree = [Int](repeating: 0, count: n)
        var labelLoad = [Double](repeating: 0, count: n)
        var edgePairs: Set<UInt64> = []
        edgePairs.reserveCapacity(edges.count)
        for edge in edges {
            guard
                let i = indexByID[edge.source],
                let j = indexByID[edge.target],
                i != j
            else { continue }
            let key = pairKey(i, j)
            if edgePairs.insert(key).inserted {
                degree[i] += 1
                degree[j] += 1
            }
            let span = estimatedEdgeLabelSpan(edge)
            labelLoad[i] += span
            labelLoad[j] += span
        }

        var externalGroupsByNode: [Int: Set<Int>] = [:]
        for edge in edges {
            guard
                let i = indexByID[edge.source],
                let j = indexByID[edge.target],
                i != j
            else { continue }
            let gi = memberToGroups[i] ?? []
            let gj = memberToGroups[j] ?? []
            let externalForI = gj.subtracting(gi)
            let externalForJ = gi.subtracting(gj)
            if !externalForI.isEmpty {
                externalGroupsByNode[i, default: []].formUnion(externalForI)
            }
            if !externalForJ.isEmpty {
                externalGroupsByNode[j, default: []].formUnion(externalForJ)
            }
        }

        let degreeWeights = degree.map { min(log2(Double($0) + 1.0), 4.0) }
        let labelWeights = labelLoad.map { min($0 / 260.0, 2.2) }
        var nodeBudgets: [NodeBudget] = []
        nodeBudgets.reserveCapacity(n)
        for index in 0..<n {
            let groupLoad = min(Double(memberToGroups[index]?.count ?? 0), 3.0)
            let personal = radii[index]
                + 44
                + baseGap * (
                    0.18 * degreeWeights[index]
                    + 0.08 * labelWeights[index]
                    + 0.10 * groupLoad
                )
            nodeBudgets.append(NodeBudget(
                degree: degree[index],
                personalRadius: personal
            ))
        }

        var realPairKeys: Set<UInt64> = []
        realPairKeys.reserveCapacity(edges.count)
        var edgeSprings: [LayoutSpring] = []
        edgeSprings.reserveCapacity(edges.count)
        for edge in edges {
            guard
                let i = indexByID[edge.source],
                let j = indexByID[edge.target],
                i != j
            else { continue }
            let key = pairKey(i, j)
            guard realPairKeys.insert(key).inserted else { continue }
            let gi = memberToGroups[i] ?? []
            let gj = memberToGroups[j] ?? []
            let sharesGroup = !gi.isDisjoint(with: gj)
            let externalCount = max(
                externalGroupsByNode[i]?.count ?? 0,
                externalGroupsByNode[j]?.count ?? 0
            )
            let degreeLoad = max(degreeWeights[i], degreeWeights[j])
            let labelWeight = max(labelWeights[i], labelWeights[j])
            let membershipLoad = min(Double(max(gi.count, gj.count)), 3.0)
            let labelSpan = estimatedEdgeLabelSpan(edge)
            let relationMultiplier = 1.0
                + 0.24 * degreeLoad
                + 0.08 * labelWeight
                + 0.12 * Double(externalCount)
                + 0.10 * membershipLoad
            let groupMultiplier = sharesGroup ? 0.78 : 1.65
            let topologyGap = baseGap * groupMultiplier * relationMultiplier
            let degreeReadableGap = baseGap * min(0.90, 0.32 * max(degreeLoad - 1.0, 0.0))
            let labelReadableGap = labelSpan + 36.0 + degreeReadableGap
            let maxReadableGap = labelReadableGap
                + baseGap * (sharesGroup ? 0.45 : 0.90)
                + min(48.0, Double(LayoutSpacing.edgeEdge) * Double(externalCount))
            let resolvedGap = min(max(topologyGap, labelReadableGap), maxReadableGap)
            let ideal = radii[i] + radii[j]
                + resolvedGap
            edgeSprings.append(LayoutSpring(
                i: i,
                j: j,
                ideal: ideal,
                boundaryGap: resolvedGap,
                strength: sharesGroup ? 0.030 : 0.022,
                axisBias: 0.050
            ))
        }

        var groupSprings: [LayoutSpring] = []
        for group in groupPlans where group.indices.count > 1 && group.cohesionStrength > 0 {
            let perPairStrength = (0.050 + group.cohesionStrength * 0.40)
                / Double(max(group.indices.count - 1, 1))
            for a in 0..<(group.indices.count - 1) {
                for b in (a + 1)..<group.indices.count {
                    let i = group.indices[a]
                    let j = group.indices[b]
                    if realPairKeys.contains(pairKey(i, j)) { continue }
                    let degreeLoad = max(degreeWeights[i], degreeWeights[j])
                    let ideal = radii[i] + radii[j] + baseGap * (0.42 + min(0.24, 0.05 * degreeLoad))
                    groupSprings.append(LayoutSpring(
                        i: i,
                        j: j,
                        ideal: ideal,
                        boundaryGap: nil,
                        strength: perPairStrength,
                        axisBias: 0.025
                    ))
                }
            }
        }

        var linkedGroupPairs: Set<UInt64> = []
        for edge in edges {
            guard
                let i = indexByID[edge.source],
                let j = indexByID[edge.target],
                i != j
            else { continue }
            let gi = memberToGroups[i] ?? []
            let gj = memberToGroups[j] ?? []
            if !gi.isDisjoint(with: gj) { continue }
            for a in gi {
                for b in gj where a != b && groupPlans[a].memberSet.isDisjoint(with: groupPlans[b].memberSet) {
                    linkedGroupPairs.insert(pairKey(a, b))
                }
            }
        }

        return LayoutPlan(
            sizes: sizes,
            radii: radii,
            baseGap: baseGap,
            nodeBudgets: nodeBudgets,
            edgeSprings: edgeSprings,
            groupSprings: groupSprings,
            groups: groupPlans,
            linkedGroupPairs: linkedGroupPairs
        )
    }

    private static func seedConstraintPositions(
        cards: [CompoundGraph.Card],
        edges: [CompoundGraph.CardEdge],
        initial: [NodeIdentifier: CGPoint],
        plan: LayoutPlan
    ) -> [CGPoint] {
        let n = cards.count
        let totalArea = cards.reduce(0.0) { result, card in
            result + Double(card.size.width * card.size.height)
        }
        let canvasSeed = max(640.0, sqrt(totalArea) * 3.8)
        let center = CGPoint(x: canvasSeed / 2, y: canvasSeed / 2)

        var adjacency = Array(repeating: [Int](), count: n)
        let indexByID = Dictionary(uniqueKeysWithValues:
            cards.enumerated().map { ($0.element.id, $0.offset) }
        )
        for edge in edges {
            guard
                let i = indexByID[edge.source],
                let j = indexByID[edge.target],
                i != j
            else { continue }
            adjacency[i].append(j)
            adjacency[j].append(i)
        }
        for index in adjacency.indices {
            adjacency[index].sort()
        }

        var components: [[Int]] = []
        var visited = Set<Int>()
        for start in 0..<n where !visited.contains(start) {
            var queue = [start]
            var cursor = 0
            visited.insert(start)
            while cursor < queue.count {
                let current = queue[cursor]
                cursor += 1
                for next in adjacency[current] where !visited.contains(next) {
                    visited.insert(next)
                    queue.append(next)
                }
            }
            components.append(queue.sorted())
        }

        let goldenAngle = Double.pi * (3.0 - sqrt(5.0))
        let componentStep = max(canvasSeed / max(sqrt(Double(components.count)), 1.0), plan.baseGap * 3.0)
        var positions = Array(repeating: center, count: n)
        for (componentIndex, component) in components.enumerated() {
            let warmPoints = component.compactMap { initial[cards[$0].id.nodeID] }
            let componentCenter: CGPoint
            if warmPoints.isEmpty {
                let angle = Double(componentIndex) * goldenAngle
                let radius = componentIndex == 0 ? 0 : componentStep * sqrt(Double(componentIndex))
                componentCenter = CGPoint(
                    x: center.x + CGFloat(cos(angle) * radius),
                    y: center.y + CGFloat(sin(angle) * radius)
                )
            } else {
                componentCenter = CGPoint(
                    x: warmPoints.reduce(0) { $0 + $1.x } / CGFloat(warmPoints.count),
                    y: warmPoints.reduce(0) { $0 + $1.y } / CGFloat(warmPoints.count)
                )
            }

            let root = component.max { lhs, rhs in
                if plan.nodeBudgets[lhs].degree == plan.nodeBudgets[rhs].degree {
                    return lhs > rhs
                }
                return plan.nodeBudgets[lhs].degree < plan.nodeBudgets[rhs].degree
            } ?? component[0]
            let order = breadthFirstOrder(root: root, component: component, adjacency: adjacency)
            let localStep = max(plan.baseGap * 0.82, 130.0)
            for (localIndex, index) in order.enumerated() {
                if let warm = initial[cards[index].id.nodeID] {
                    positions[index] = warm
                    continue
                }
                guard localIndex > 0 else {
                    positions[index] = componentCenter
                    continue
                }
                let angle = Double(localIndex - 1) * goldenAngle
                let radius = localStep * sqrt(Double(localIndex))
                positions[index] = CGPoint(
                    x: componentCenter.x + CGFloat(cos(angle) * radius),
                    y: componentCenter.y + CGFloat(sin(angle) * radius)
                )
            }
        }
        return positions
    }

    private static func breadthFirstOrder(
        root: Int,
        component: [Int],
        adjacency: [[Int]]
    ) -> [Int] {
        let componentSet = Set(component)
        var visited: Set<Int> = [root]
        var queue = [root]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            for next in adjacency[current] where componentSet.contains(next) && !visited.contains(next) {
                visited.insert(next)
                queue.append(next)
            }
        }
        for index in component where !visited.contains(index) {
            queue.append(index)
        }
        return queue
    }

    private static func solveConstraintLayout(
        positions: inout [CGPoint],
        plan: LayoutPlan,
        iterations: Int
    ) {
        let n = positions.count
        guard n > 1, iterations > 0 else { return }

        var working = positions
        var dispX = Array(repeating: 0.0, count: n)
        var dispY = Array(repeating: 0.0, count: n)
        let initialTemperature = max(plan.baseGap * 1.8, 180.0)

        for step in 0..<iterations {
            for index in 0..<n {
                dispX[index] = 0
                dispY[index] = 0
            }

            accumulateNodeRepulsion(
                positions: working,
                plan: plan,
                dispX: &dispX,
                dispY: &dispY
            )
            accumulateSpringForces(
                springs: plan.edgeSprings,
                positions: working,
                sizes: plan.sizes,
                dispX: &dispX,
                dispY: &dispY
            )
            accumulateSpringForces(
                springs: plan.groupSprings,
                positions: working,
                sizes: plan.sizes,
                dispX: &dispX,
                dispY: &dispY
            )
            accumulateGroupCohesion(
                positions: working,
                plan: plan,
                dispX: &dispX,
                dispY: &dispY
            )
            accumulateGroupSeparation(
                positions: working,
                plan: plan,
                dispX: &dispX,
                dispY: &dispY,
                strength: 0.08
            )
            accumulateGravity(
                positions: working,
                dispX: &dispX,
                dispY: &dispY,
                strength: 0.012
            )

            let progress = Double(step) / Double(iterations)
            let temperature = initialTemperature * pow(max(1.0 - progress, 0.0), 1.35)
            for index in 0..<n {
                let magnitude = sqrt(dispX[index] * dispX[index] + dispY[index] * dispY[index])
                guard magnitude > 0.0001 else { continue }
                let scale = min(magnitude, temperature) / magnitude
                working[index].x += CGFloat(dispX[index] * scale)
                working[index].y += CGFloat(dispY[index] * scale)
            }
        }

        positions = working
    }

    private static func finalizeConstraintLayout(
        positions: inout [CGPoint],
        plan: LayoutPlan,
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) {
        for _ in 0..<3 {
            projectPlannedEdgeLengths(
                positions: &positions,
                springs: plan.edgeSprings,
                sizes: plan.sizes,
                iterations: 10,
                stiffness: 0.35
            )
            relaxEdgeAngles(
                positions: &positions,
                edges: edges,
                indexByID: indexByID,
                iterations: 16,
                strength: 0.16
            )
            spreadHubIncidentEdges(
                positions: &positions,
                edges: edges,
                indexByID: indexByID,
                iterations: 18,
                strength: 0.40
            )
            resolveOverlaps(
                positions: &positions,
                sizes: plan.sizes,
                margin: 56,
                iterations: 48
            )
            resolvePlannedGroupGaps(
                positions: &positions,
                plan: plan,
                iterations: 22,
                strength: 0.70
            )
            compactSparseGroups(
                positions: &positions,
                radii: plan.radii,
                edges: edges,
                groups: groups,
                indexByID: indexByID,
                cardCount: plan.sizes.count,
                iterations: 24
            )
        }

        ejectNonMembersFromGroups(
            positions: &positions,
            sizes: plan.sizes,
            groups: groups,
            indexByID: indexByID
        )
        resolveOverlaps(
            positions: &positions,
            sizes: plan.sizes,
            margin: 58,
            iterations: 72
        )
        resolveGroupOverlaps(
            positions: &positions,
            sizes: plan.sizes,
            groups: groups,
            indexByID: indexByID,
            margin: 48,
            iterations: 48
        )
        resolveOverlaps(
            positions: &positions,
            sizes: plan.sizes,
            margin: 58,
            iterations: 72
        )
        compactSparseGroups(
            positions: &positions,
            radii: plan.radii,
            edges: edges,
            groups: groups,
            indexByID: indexByID,
            cardCount: plan.sizes.count,
            iterations: 36
        )
        resolveOverlaps(
            positions: &positions,
            sizes: plan.sizes,
            margin: 58,
            iterations: 72
        )
    }

    private static func accumulateNodeRepulsion(
        positions: [CGPoint],
        plan: LayoutPlan,
        dispX: inout [Double],
        dispY: inout [Double]
    ) {
        let n = positions.count
        guard n > 1 else { return }
        for i in 0..<(n - 1) {
            let xi = Double(positions[i].x)
            let yi = Double(positions[i].y)
            for j in (i + 1)..<n {
                let dx = xi - Double(positions[j].x)
                let dy = yi - Double(positions[j].y)
                let distance = max(sqrt(dx * dx + dy * dy), 0.01)
                let target = plan.nodeBudgets[i].personalRadius + plan.nodeBudgets[j].personalRadius
                let cutoff = target * 2.75
                guard distance < cutoff else { continue }
                let ux = dx / distance
                let uy = dy / distance
                let collision = max(0, target - distance) * 0.55
                let field = (target * target) / distance * 0.012
                let force = collision + field
                dispX[i] += ux * force
                dispY[i] += uy * force
                dispX[j] -= ux * force
                dispY[j] -= uy * force
            }
        }
    }

    private static func accumulateSpringForces(
        springs: [LayoutSpring],
        positions: [CGPoint],
        sizes: [CGSize],
        dispX: inout [Double],
        dispY: inout [Double]
    ) {
        for spring in springs {
            let i = spring.i
            let j = spring.j
            let dx = Double(positions[j].x - positions[i].x)
            let dy = Double(positions[j].y - positions[i].y)
            let distance = max(sqrt(dx * dx + dy * dy), 0.01)
            let ux = dx / distance
            let uy = dy / distance
            let ideal = idealDistance(
                for: spring,
                positions: positions,
                sizes: sizes,
                fallbackDistance: distance
            )
            let force = (distance - ideal) * spring.strength
            dispX[i] += ux * force
            dispY[i] += uy * force
            dispX[j] -= ux * force
            dispY[j] -= uy * force

            if abs(dx) >= abs(dy) {
                let correction = dy * spring.axisBias
                dispY[i] += correction
                dispY[j] -= correction
            } else {
                let correction = dx * spring.axisBias
                dispX[i] += correction
                dispX[j] -= correction
            }
        }
    }

    private static func idealDistance(
        for spring: LayoutSpring,
        positions: [CGPoint],
        sizes: [CGSize],
        fallbackDistance: Double
    ) -> Double {
        guard let boundaryGap = spring.boundaryGap else {
            return spring.ideal
        }

        let dx = Double(positions[spring.j].x - positions[spring.i].x)
        let dy = Double(positions[spring.j].y - positions[spring.i].y)
        let distance = max(sqrt(dx * dx + dy * dy), max(fallbackDistance, 0.001))
        let ux = dx / distance
        let uy = dy / distance
        let sourceExit = rayBoundaryDistance(size: sizes[spring.i], ux: ux, uy: uy)
        let targetExit = rayBoundaryDistance(size: sizes[spring.j], ux: -ux, uy: -uy)
        return max(sourceExit + targetExit + boundaryGap, 1.0)
    }

    private static func rayBoundaryDistance(size: CGSize, ux: Double, uy: Double) -> Double {
        let halfWidth = max(Double(size.width) * 0.5, 1.0)
        let halfHeight = max(Double(size.height) * 0.5, 1.0)
        let absX = abs(ux)
        let absY = abs(uy)

        if absX < 0.0001 {
            return halfHeight
        }
        if absY < 0.0001 {
            return halfWidth
        }
        return min(halfWidth / absX, halfHeight / absY)
    }

    private static func accumulateGroupCohesion(
        positions: [CGPoint],
        plan: LayoutPlan,
        dispX: inout [Double],
        dispY: inout [Double]
    ) {
        for group in plan.groups where group.indices.count > 1 && group.cohesionStrength > 0 {
            var cx = 0.0
            var cy = 0.0
            for index in group.indices {
                cx += Double(positions[index].x)
                cy += Double(positions[index].y)
            }
            let invCount = 1.0 / Double(group.indices.count)
            cx *= invCount
            cy *= invCount
            let strength = group.cohesionStrength * 1.20
            for index in group.indices {
                dispX[index] += (cx - Double(positions[index].x)) * strength
                dispY[index] += (cy - Double(positions[index].y)) * strength
            }
        }
    }

    private static func accumulateGroupSeparation(
        positions: [CGPoint],
        plan: LayoutPlan,
        dispX: inout [Double],
        dispY: inout [Double],
        strength: Double
    ) {
        let rects = groupRects(positions: positions, plan: plan)
        guard rects.count > 1 else { return }
        for a in 0..<(rects.count - 1) {
            for b in (a + 1)..<rects.count {
                guard plan.groups[a].memberSet.isDisjoint(with: plan.groups[b].memberSet) else {
                    continue
                }
                let linked = plan.linkedGroupPairs.contains(pairKey(a, b))
                let targetGap = linked ? 190.0 : 90.0
                let vector = groupSeparationVector(
                    first: rects[a],
                    second: rects[b],
                    targetGap: targetGap,
                    forceHorizontal: true
                )
                guard vector.dx != 0 || vector.dy != 0 else { continue }
                let dx = vector.dx * strength
                let dy = vector.dy * strength
                for index in plan.groups[a].indices {
                    dispX[index] -= dx
                    dispY[index] -= dy
                }
                for index in plan.groups[b].indices {
                    dispX[index] += dx
                    dispY[index] += dy
                }
            }
        }
    }

    private static func accumulateGravity(
        positions: [CGPoint],
        dispX: inout [Double],
        dispY: inout [Double],
        strength: Double
    ) {
        guard !positions.isEmpty else { return }
        var cx = 0.0
        var cy = 0.0
        for position in positions {
            cx += Double(position.x)
            cy += Double(position.y)
        }
        cx /= Double(positions.count)
        cy /= Double(positions.count)
        for index in positions.indices {
            dispX[index] += (cx - Double(positions[index].x)) * strength
            dispY[index] += (cy - Double(positions[index].y)) * strength
        }
    }

    private static func projectPlannedEdgeLengths(
        positions: inout [CGPoint],
        springs: [LayoutSpring],
        sizes: [CGSize],
        iterations: Int,
        stiffness: Double
    ) {
        guard !springs.isEmpty, iterations > 0 else { return }
        for _ in 0..<iterations {
            for spring in springs {
                let dx = Double(positions[spring.j].x - positions[spring.i].x)
                let dy = Double(positions[spring.j].y - positions[spring.i].y)
                let distance = max(sqrt(dx * dx + dy * dy), 0.001)
                let ideal = idealDistance(
                    for: spring,
                    positions: positions,
                    sizes: sizes,
                    fallbackDistance: distance
                )
                let error = distance - ideal
                guard abs(error) > 0.01 else { continue }
                let ux = dx / distance
                let uy = dy / distance
                let correction = error * 0.5 * stiffness
                positions[spring.i].x += CGFloat(ux * correction)
                positions[spring.i].y += CGFloat(uy * correction)
                positions[spring.j].x -= CGFloat(ux * correction)
                positions[spring.j].y -= CGFloat(uy * correction)
            }
        }
    }

    private static func resolvePlannedGroupGaps(
        positions: inout [CGPoint],
        plan: LayoutPlan,
        iterations: Int,
        strength: Double
    ) {
        guard plan.groups.count > 1, iterations > 0 else { return }
        for _ in 0..<iterations {
            let rects = groupRects(positions: positions, plan: plan)
            for a in 0..<(rects.count - 1) {
                for b in (a + 1)..<rects.count {
                    guard plan.groups[a].memberSet.isDisjoint(with: plan.groups[b].memberSet) else {
                        continue
                    }
                    let linked = plan.linkedGroupPairs.contains(pairKey(a, b))
                    let targetGap = linked ? 190.0 : 90.0
                    let vector = groupSeparationVector(
                        first: rects[a],
                        second: rects[b],
                        targetGap: targetGap,
                        forceHorizontal: true
                    )
                    guard vector.dx != 0 || vector.dy != 0 else { continue }
                    let dx = vector.dx * strength
                    let dy = vector.dy * strength
                    for index in plan.groups[a].indices {
                        positions[index].x -= CGFloat(dx)
                        positions[index].y -= CGFloat(dy)
                    }
                    for index in plan.groups[b].indices {
                        positions[index].x += CGFloat(dx)
                        positions[index].y += CGFloat(dy)
                    }
                }
            }
        }
    }

    private static func groupRects(
        positions: [CGPoint],
        plan: LayoutPlan
    ) -> [CGRect] {
        plan.groups.map { group in
            var rect = CGRect.null
            for index in group.indices {
                let size = plan.sizes[index]
                let origin = CGPoint(
                    x: positions[index].x - size.width / 2,
                    y: positions[index].y - size.height / 2
                )
                let cardRect = CGRect(origin: origin, size: size)
                rect = rect.isNull ? cardRect : rect.union(cardRect)
            }
            return rect.insetBy(dx: -group.padding, dy: -group.padding)
        }
    }

    private static func groupSeparationVector(
        first: CGRect,
        second: CGRect,
        targetGap: Double,
        forceHorizontal: Bool
    ) -> CGVector {
        let centerDX = Double(second.midX - first.midX)
        let centerDY = Double(second.midY - first.midY)
        if forceHorizontal || abs(centerDX) >= abs(centerDY) {
            let direction = forceHorizontal ? 1.0 : (centerDX >= 0 ? 1.0 : -1.0)
            let gap = direction > 0
                ? Double(second.minX - first.maxX)
                : Double(first.minX - second.maxX)
            let deficit = targetGap - gap
            guard deficit > 0 else { return .zero }
            return CGVector(dx: direction * deficit * 0.5, dy: 0)
        } else {
            let direction = centerDY >= 0 ? 1.0 : -1.0
            let gap = direction > 0
                ? Double(second.minY - first.maxY)
                : Double(first.minY - second.maxY)
            let deficit = targetGap - gap
            guard deficit > 0 else { return .zero }
            return CGVector(dx: 0, dy: direction * deficit * 0.5)
        }
    }

    private static func pairKey(_ a: Int, _ b: Int) -> UInt64 {
        let lo = UInt64(min(a, b))
        let hi = UInt64(max(a, b))
        return (lo << 32) | hi
    }

    // MARK: - Group bounding boxes

    /// Compute the padded bounding box for each group. Cards already settled
    /// in `cardPositions`; we union their rectangles and inset by negative
    /// `style.padding` so the box sits a uniform distance outside its members.
    ///
    /// Invariants enforced via precondition:
    ///   - `decompose` drops empty groups, so `group.members` is non-empty.
    ///   - Every member of every group is also in `cards` and `cardPositions`.
    /// A violation indicates a pipeline desync and must crash rather than
    /// silently produce a missing bbox (silent fallback is banned).
    private static func computeGroupBoundingBoxes(
        groups: [CompoundGraph.Group],
        cards: [CompoundGraph.Card],
        indexByID: [CompoundGraph.Card.ID: Int],
        cardPositions: [CompoundGraph.Card.ID: CGPoint]
    ) -> [CompoundGraph.Group.ID: CGRect] {
        var result: [CompoundGraph.Group.ID: CGRect] = [:]
        result.reserveCapacity(groups.count)
        for group in groups {
            precondition(
                !group.members.isEmpty,
                "Group \(group.id) is empty — decompose should have dropped it"
            )
            var bbox: CGRect = .null
            for memberID in group.members {
                guard let index = indexByID[memberID] else {
                    preconditionFailure(
                        "Group \(group.id) member \(memberID) missing from cards"
                    )
                }
                guard let origin = cardPositions[memberID] else {
                    preconditionFailure(
                        "Group \(group.id) member \(memberID) missing from cardPositions"
                    )
                }
                let rect = CGRect(origin: origin, size: cards[index].size)
                bbox = bbox.isNull ? rect : bbox.union(rect)
            }
            let pad = group.style.padding
            result[group.id] = bbox.insetBy(dx: -pad, dy: -pad)
        }
        return result
    }

    // MARK: - Seeding

    /// Seed newcomer cards on a golden-angle (Vogel) spiral around the
    /// centroid of warm-start positions. Same-radius seeding causes hubs to
    /// collapse onto a single ring during relaxation; the spiral spreads
    /// initial positions across an annulus instead, giving every card room
    /// to settle independently.
    private static func seedPositions(
        cards: [CompoundGraph.Card],
        initial: [NodeIdentifier: CGPoint],
        canvasSeed: Double
    ) -> [CGPoint] {
        let center = CGPoint(x: canvasSeed / 2, y: canvasSeed / 2)
        let warmPoints: [CGPoint] = cards.compactMap { initial[$0.id.nodeID] }
        let centroid = warmPoints.isEmpty
            ? center
            : CGPoint(
                x: warmPoints.reduce(0) { $0 + $1.x } / CGFloat(warmPoints.count),
                y: warmPoints.reduce(0) { $0 + $1.y } / CGFloat(warmPoints.count)
            )

        // The Vogel-spiral step controls how fast successive points spread
        // outward. `canvasSeed / 22` keeps the seed annulus comparable to the
        // pre-relaxation working area for typical card counts.
        let spiralStep = max(canvasSeed / 22.0, 18.0)
        let goldenAngle = .pi * (3.0 - sqrt(5.0))
        var newcomerCounter = 0

        var seeded: [CGPoint] = []
        seeded.reserveCapacity(cards.count)
        for card in cards {
            if let warm = initial[card.id.nodeID] {
                seeded.append(warm)
            } else {
                let index = Double(newcomerCounter)
                let angle = index * goldenAngle
                let radius = spiralStep * sqrt(index + 1.0)
                let point = CGPoint(
                    x: centroid.x + CGFloat(radius * cos(angle)),
                    y: centroid.y + CGFloat(radius * sin(angle))
                )
                seeded.append(point)
                newcomerCounter += 1
            }
        }
        return seeded
    }

    // MARK: - Intra-group pre-pass

    /// For each multi-member group, run a small Fruchterman–Reingold
    /// relaxation over **just the group's members**, then translate the
    /// resulting cluster back to its original centroid before writing the
    /// member positions back to `positions`.
    ///
    /// Rationale: the global FR sees every card simultaneously, so a
    /// member of group G whose only real edge points at an external card
    /// E feels the full edge spring `d² / ideal` pulling outward toward
    /// E. The intra-group pseudo-spring competing for that same member
    /// is per-pair `≤ 1 / (members − 1)` strength — far weaker than one
    /// real edge. Members therefore drift to wherever their external
    /// connections lie, and the group's bbox stretches to enclose a
    /// scattered set of nodes.
    ///
    /// This pre-pass converges *inside* each group first, using only
    /// real edges that connect two members plus a strong pseudo-spring
    /// for unconnected member pairs. With no external repulsion or
    /// springs in scope, the cluster settles tight. We then re-center
    /// the cluster on its original seed centroid so the group occupies
    /// the same canvas region it did before the pass — the global FR
    /// only has to settle the *group's position*, not its internal
    /// arrangement.
    ///
    /// Cards belonging to multiple groups are processed once per group
    /// in the order groups are emitted; the last group to touch the
    /// card wins. Multi-group membership is rare in practice (nested
    /// groups are represented by subset relationships rather than
    /// re-membership), so the simple ordering is acceptable.
    private static func intraGroupPrePass(
        positions: inout [CGPoint],
        radii: [Double],
        edges: [CompoundGraph.CardEdge],
        indexByID: [CompoundGraph.Card.ID: Int],
        groups: [CompoundGraph.Group]
    ) {
        guard !groups.isEmpty else { return }
        // Tighter than the global Node-Node gap: group members should read as
        // one compact unit, especially because labels usually connect outward.
        let intraGap = Double(LayoutSpacing.groupInternalNodeNodeHorizontal)
        let preIterations = 90
        let pseudoStrength: Double = 0.6
        let coolingExponent: Double = 1.3

        for group in groups where group.cohesionStrength > 0 {
            var memberIdx: [Int] = []
            memberIdx.reserveCapacity(group.members.count)
            for member in group.members {
                if let idx = indexByID[member] {
                    memberIdx.append(idx)
                }
            }
            let n = memberIdx.count
            guard n > 1 else { continue }

            // Local index map: global card index → 0..<n local index.
            var localIndex: [Int: Int] = [:]
            localIndex.reserveCapacity(n)
            for (li, gi) in memberIdx.enumerated() {
                localIndex[gi] = li
            }
            let memberSet = Set(memberIdx)

            // Copy out current positions and seed centroid.
            var local: [CGPoint] = memberIdx.map { positions[$0] }
            let seedCX = local.reduce(0.0) { $0 + Double($1.x) } / Double(n)
            let seedCY = local.reduce(0.0) { $0 + Double($1.y) } / Double(n)

            // FR constants for this mini-system.
            let avgRadius = memberIdx.map { radii[$0] }.reduce(0, +) / Double(n)
            let k = avgRadius * 2.0 + intraGap
            let kSq = k * k
            let initialTemp = k * 0.8

            // Real edges with both endpoints in this group.
            struct LocalEdge { let a: Int; let b: Int; let ideal: Double }
            var realEdges: [LocalEdge] = []
            var seenPairs: Set<UInt64> = []
            for edge in edges {
                guard
                    let s = indexByID[edge.source],
                    let t = indexByID[edge.target],
                    memberSet.contains(s),
                    memberSet.contains(t),
                    s != t,
                    let la = localIndex[s],
                    let lb = localIndex[t]
                else { continue }
                let lo = UInt64(min(la, lb))
                let hi = UInt64(max(la, lb))
                let key = (lo << 32) | hi
                if !seenPairs.insert(key).inserted { continue }
                let ideal = radii[memberIdx[la]] + radii[memberIdx[lb]] + intraGap
                realEdges.append(LocalEdge(a: la, b: lb, ideal: ideal))
            }
            // Pseudo-springs for unconnected pairs.
            var pseudoEdges: [LocalEdge] = []
            for a in 0..<(n - 1) {
                for b in (a + 1)..<n {
                    let lo = UInt64(a)
                    let hi = UInt64(b)
                    let key = (lo << 32) | hi
                    if seenPairs.contains(key) { continue }
                    let ideal = radii[memberIdx[a]] + radii[memberIdx[b]] + intraGap
                    pseudoEdges.append(LocalEdge(a: a, b: b, ideal: ideal))
                }
            }

            var dispX = [Double](repeating: 0, count: n)
            var dispY = [Double](repeating: 0, count: n)

            for step in 0..<preIterations {
                for i in 0..<n {
                    dispX[i] = 0
                    dispY[i] = 0
                }
                // Repulsion within the group only.
                for i in 0..<(n - 1) {
                    let pix = Double(local[i].x)
                    let piy = Double(local[i].y)
                    for j in (i + 1)..<n {
                        let dx = pix - Double(local[j].x)
                        let dy = piy - Double(local[j].y)
                        let dist = max(sqrt(dx * dx + dy * dy), 0.01)
                        let force = kSq / dist
                        let ux = dx / dist
                        let uy = dy / dist
                        dispX[i] += ux * force
                        dispY[i] += uy * force
                        dispX[j] -= ux * force
                        dispY[j] -= uy * force
                    }
                }
                // Real edge attraction — full FR strength.
                for e in realEdges {
                    let dx = Double(local[e.a].x) - Double(local[e.b].x)
                    let dy = Double(local[e.a].y) - Double(local[e.b].y)
                    let dist = max(sqrt(dx * dx + dy * dy), 0.01)
                    let force = (dist * dist) / e.ideal
                    let ux = dx / dist
                    let uy = dy / dist
                    dispX[e.a] -= ux * force
                    dispY[e.a] -= uy * force
                    dispX[e.b] += ux * force
                    dispY[e.b] += uy * force
                }
                // Pseudo-spring attraction — weaker but still significant
                // because there is no external pull competing here.
                for e in pseudoEdges {
                    let dx = Double(local[e.a].x) - Double(local[e.b].x)
                    let dy = Double(local[e.a].y) - Double(local[e.b].y)
                    let dist = max(sqrt(dx * dx + dy * dy), 0.01)
                    let force = pseudoStrength * (dist * dist) / e.ideal
                    let ux = dx / dist
                    let uy = dy / dist
                    dispX[e.a] -= ux * force
                    dispY[e.a] -= uy * force
                    dispX[e.b] += ux * force
                    dispY[e.b] += uy * force
                }

                let progress = Double(step) / Double(preIterations)
                let temp = initialTemp * pow(max(1.0 - progress, 0), coolingExponent)
                for i in 0..<n {
                    let mag = sqrt(dispX[i] * dispX[i] + dispY[i] * dispY[i])
                    if mag < 0.0001 { continue }
                    let scale = min(mag, temp) / mag
                    local[i].x += CGFloat(dispX[i] * scale)
                    local[i].y += CGFloat(dispY[i] * scale)
                }
            }

            // Re-center to seed centroid so the group keeps its original
            // canvas region; the global FR is responsible for inter-group
            // placement, not intra-group arrangement.
            var newCX = 0.0
            var newCY = 0.0
            for p in local {
                newCX += Double(p.x)
                newCY += Double(p.y)
            }
            newCX /= Double(n)
            newCY /= Double(n)
            let shiftX = seedCX - newCX
            let shiftY = seedCY - newCY
            for (li, gi) in memberIdx.enumerated() {
                positions[gi] = CGPoint(
                    x: local[li].x + CGFloat(shiftX),
                    y: local[li].y + CGFloat(shiftY)
                )
            }
        }
    }

    // MARK: - Fruchterman–Reingold

    /// Fruchterman–Reingold relaxation. Each iteration applies pairwise
    /// Coulomb-style repulsion plus per-edge spring attraction, then caps
    /// the net displacement by a cooling temperature.
    ///
    /// - The baseline repulsion constant `k = avgRadius·2 + edgeGap` matches
    ///   the expected ideal distance between two average cards connected by an
    ///   edge. Each pair then derives a local `k` from endpoint degree and
    ///   label load so hubs reserve more whitespace than leaf pairs.
    /// - Repulsion is gated by a local cutoff. Pairs farther apart contribute
    ///   zero force, preventing disconnected components from drifting to
    ///   infinity while still letting connected hubs spread freely within
    ///   their larger influence radius.
    /// - Spring attraction uses per-edge ideal distance
    ///   `radii[i] + radii[j] + groupGap + topologyGap`, so hubs with many
    ///   incident neighbours anchor farther out than leaf-to-leaf pairs.
    /// - Temperature decays polynomially as `t₀ · (1 - i/N)^1.3` so the
    ///   layout converges smoothly rather than oscillating in the final
    ///   passes.
    private static func fruchtermanReingold(
        positions: inout [CGPoint],
        radii: [Double],
        edges: [CompoundGraph.CardEdge],
        indexByID: [CompoundGraph.Card.ID: Int],
        groups: [CompoundGraph.Group],
        iterations: Int
    ) {
        let n = positions.count
        guard n > 1, iterations > 0 else { return }

        let avgRadius = radii.reduce(0, +) / Double(n)
        let effectiveGap = adaptiveEdgeGap(cardCount: n)
        let k0 = avgRadius * 2.0 + effectiveGap
        // Repulsion cutoff. At distances beyond the cutoff cards no longer
        // push each other apart, so disjoint components settle at roughly
        // this distance once gravity pulls them back into range. 1.8k is
        // tight enough that disjoint groups read as a unified diagram
        // rather than islands; below this gravity can no longer hold them
        // and they collapse together (resolveOverlaps then becomes the
        // dominant separator, which over-tightens the diagram).
        let repelCutoff = k0 * 1.8
        let initialTemp = k0 * 1.6
        let coolingExponent: Double = 1.3
        // Weak global gravity toward the layout centroid. FR has no attraction
        // between disconnected components, so without this they drift apart
        // until cooling stops — leaving disjoint clusters scattered to the
        // canvas corners. 0.02 is ~0.5% of a typical spring force at the
        // group's working distance, so it does nothing inside a connected
        // group but pulls disconnected clusters back into a shared neighbourhood.
        let gravityStrength: Double = 0.02
        // Axis-alignment bias. Each iteration nudges every edge (and every
        // intra-group pseudo-spring) toward the nearer cardinal axis: if
        // the edge is wider than tall, its endpoints' y values are pulled
        // toward their midpoint, snapping it horizontal; if taller than
        // wide, the x values are pulled together, snapping it vertical.
        // The bias only acts on the perpendicular component to the
        // dominant axis, so already-axis-aligned edges are untouched and
        // only diagonals are pulled in. 0.10 is weak enough that FR
        // dominates direction during early hot iterations and only the
        // final relaxation is biased orthogonal.
        let axisAlignBias: Double = 0.10

        // Pre-compute card → active-group memberships. Only "active"
        // groups (cohesion > 0 and >1 member) participate in layout, so
        // membership for *spring classification* must filter the same
        // way; inactive groups are visual-only and should not stretch
        // edges. The index assigned here is a synthetic "active group"
        // index and is only used for set comparison, so it does not
        // need to align with `groupForces` (built below).
        var memberToGroups: [Int: Set<Int>] = [:]
        do {
            var gfIdx = 0
            for group in groups where group.cohesionStrength > 0 {
                var resolved: [Int] = []
                resolved.reserveCapacity(group.members.count)
                for member in group.members {
                    if let idx = indexByID[member] {
                        resolved.append(idx)
                    }
                }
                if resolved.count <= 1 { continue }
                for idx in resolved {
                    memberToGroups[idx, default: []].insert(gfIdx)
                }
                gfIdx += 1
            }
        }

        // Pre-compute the unique neighbour list with per-edge ideal distance
        // so self-loops and parallel edges contribute a single spring each.
        //
        // Cross-group edges (endpoints in no shared active group) use an
        // inflated rest length. Two effects:
        //
        //   1. Edges that cross over a group stretch around it rather
        //      than cutting through, because the longer spring settles
        //      at a distance that lets the edge route past the group's
        //      bbox.
        //
        //   2. Groups joined by a cross-edge settle visibly apart. The
        //      cross-edge is itself a visual statement ("these groups
        //      *interact*"), and a short edge collapses that statement
        //      into a single merged region. With the multiplier at
        //      2.0 the rest length is `radii + 280` ≈ 380 centre-to-
        //      centre for average cards, which leaves clear room
        //      between the two padded bboxes plus headroom for the
        //      `snapGroupCentroidsToAxes` pass to align the pair on
        //      a row/column.
        let crossGroupGapMultiplier: Double = 2.0
        // Multi-group hub multiplier. A card qualifies as a
        // "multi-group hub" when *either*:
        //
        //   - it is a member of ≥ 2 active groups directly
        //     (bridging groups by membership — e.g. `dave ∈
        //     {right, bridge}` in a Trig payload), OR
        //
        //   - it participates in cross-group edges to ≥ 2 distinct
        //     *external* groups (bridging groups by connection
        //     rather than membership — e.g. `bob` connected to
        //     members of group A and group B without itself
        //     belonging to either).
        //
        // Edges incident to a hub get extra rest length so the
        // hub's other terminals fan out angularly rather than
        // stacking, and so an intra-group edge that reaches a
        // multi-group member visibly steers the member toward the
        // "boundary" of the group it shares. Combined with the
        // base 2.0× cross-group multiplier, hub cross-edges land
        // at 2.6× of `effectiveGap`. For intra-group edges where
        // one endpoint is a hub, only the 1.3× is applied — the
        // intra-group rest length already starts at `effectiveGap`,
        // so the multiplier modestly stretches the edge (~17% more
        // centre-to-centre) without uprooting the group.
        let hubGapMultiplier: Double = 1.3
        // Count external groups each card is connected to via
        // cross-group edges. "External" means the other endpoint
        // belongs to at least one active group that the current
        // endpoint does *not* belong to.
        var hubGroupCount: [Int: Int] = [:]
        do {
            var perCard: [Int: Set<Int>] = [:]
            for edge in edges {
                guard
                    let i = indexByID[edge.source],
                    let j = indexByID[edge.target],
                    i != j
                else { continue }
                let gi = memberToGroups[i] ?? []
                let gj = memberToGroups[j] ?? []
                let externalForI = gj.subtracting(gi)
                let externalForJ = gi.subtracting(gj)
                if !externalForI.isEmpty {
                    perCard[i, default: []].formUnion(externalForI)
                }
                if !externalForJ.isEmpty {
                    perCard[j, default: []].formUnion(externalForJ)
                }
            }
            for (idx, set) in perCard {
                hubGroupCount[idx] = set.count
            }
        }
        // Unified hub set: connection-based hubs ∪ membership-based hubs.
        var multiGroupHubs: Set<Int> = []
        for (idx, count) in hubGroupCount where count >= 2 {
            multiGroupHubs.insert(idx)
        }
        for (idx, set) in memberToGroups where set.count >= 2 {
            multiGroupHubs.insert(idx)
        }

        // Direct degree is a layout budget, not just metadata. A high-degree
        // card needs more radial space for incident labels and more angular
        // slots for neighbours; otherwise dense schema-like graphs collapse
        // into a text pile even when card sizes and edge lengths are valid.
        var directDegree = [Int](repeating: 0, count: n)
        var labelLoad = [Double](repeating: 0, count: n)
        var degreePairs: Set<UInt64> = []
        degreePairs.reserveCapacity(edges.count)
        for edge in edges {
            guard
                let i = indexByID[edge.source],
                let j = indexByID[edge.target],
                i != j
            else { continue }
            let lo = UInt64(min(i, j))
            let hi = UInt64(max(i, j))
            let key = (lo << 32) | hi
            if degreePairs.insert(key).inserted {
                directDegree[i] += 1
                directDegree[j] += 1
            }
            let span = estimatedEdgeLabelSpan(edge)
            labelLoad[i] += span
            labelLoad[j] += span
        }
        let degreeWeights = directDegree.map { min(log2(Double($0) + 1.0), 4.0) }
        let labelWeights = labelLoad.map { min($0 / 220.0, 2.2) }
        let personalRadii = radii.enumerated().map { index, radius in
            radius + effectiveGap * (0.16 * degreeWeights[index] + 0.08 * labelWeights[index])
        }

        struct Spring { let i: Int; let j: Int; let ideal: Double }
        var seenPairs: Set<UInt64> = []
        seenPairs.reserveCapacity(edges.count)
        var springs: [Spring] = []
        springs.reserveCapacity(edges.count)
        for edge in edges {
            guard
                let i = indexByID[edge.source],
                let j = indexByID[edge.target],
                i != j
            else { continue }
            let lo = UInt64(min(i, j))
            let hi = UInt64(max(i, j))
            let key = (lo << 32) | hi
            if !seenPairs.insert(key).inserted { continue }
            let sharesGroup: Bool
            if let gi = memberToGroups[i], let gj = memberToGroups[j] {
                sharesGroup = !gi.isDisjoint(with: gj)
            } else {
                sharesGroup = false
            }
            var gap = sharesGroup ? effectiveGap : effectiveGap * crossGroupGapMultiplier
            // Apply hub multiplier irrespective of `sharesGroup`. The
            // user's complaint case (multi-group member `dave` with
            // intra-group edges `eve-dave`, `frank-dave`) is exactly
            // the intra-group / hub-endpoint combination; restricting
            // the multiplier to cross-group edges would leave those
            // edges at the baseline rest length and the hub would
            // continue to crowd its neighbours.
            if multiGroupHubs.contains(i) || multiGroupHubs.contains(j) {
                gap *= hubGapMultiplier
            }
            let endpointDegree = max(degreeWeights[i], degreeWeights[j])
            let endpointLabel = max(labelWeights[i], labelWeights[j])
            let topologyGap = min(0.95, 0.18 * endpointDegree + 0.06 * endpointLabel)
            gap += effectiveGap * topologyGap
            gap += min(72.0, estimatedEdgeLabelSpan(edge) * 0.18)
            let ideal = radii[i] + radii[j] + gap
            springs.append(Spring(i: i, j: j, ideal: ideal))
        }

        // Pre-compute the per-group member index list. Singletons contribute
        // no cohesion force (the centroid would be the member itself, which
        // is a no-op pull and also avoids any divide-by-zero risk). Groups
        // whose `cohesionStrength` is zero are also skipped, which is the
        // configured opt-out path callers use to disable the force per-group.
        struct GroupForce { let indices: [Int]; let strength: Double }
        var groupForces: [GroupForce] = []
        groupForces.reserveCapacity(groups.count)
        // Intra-group pseudo-springs. The linear cohesion pull is a
        // few-percent bias that grows linearly with distance, so it cannot
        // defeat the `k²/d` repulsion at moderate distances — two
        // disconnected cards in the same group settle near the repulsion
        // cutoff and read as scattered to opposite corners of the bbox. To
        // fix this we treat *every* same-group pair without a real edge as
        // a weak FR spring with `force = strength · d² / ideal`. Quadratic
        // growth dominates the `k²/d` repulsion at moderate `d`, so the
        // pair settles near `ideal` rather than at the cutoff. Per-pair
        // strength is scaled by `1 / (memberCount − 1)` so the *total*
        // pseudo-attraction felt by each card is roughly one real edge's
        // worth regardless of group size — small groups are tightened
        // visibly while large already-connected groups barely notice.
        struct GroupSpring { let i: Int; let j: Int; let ideal: Double; let strength: Double }
        var groupSprings: [GroupSpring] = []
        // Intra-group spring coefficient. Per-card total normalises to
        // ≈ one real edge worth of attraction at 1.0; we go a bit above
        // so groups remain compact even when several members are
        // simultaneously pulled outward by cross-group edges. The
        // pre-pass packs members into a tight cluster initially; this
        // coefficient is what *holds* that cluster against external
        // pulls during the global FR.
        let intraGroupCoefficient: Double = 1.2
        // Intra-group rest length is an absolute compact spacing rather than
        // a factor of the global edge gap. This keeps grouped nodes tighter
        // even when the external graph needs large horizontal spacing.
        let intraGroupGap = Double(LayoutSpacing.groupInternalNodeNodeHorizontal)
        for group in groups where group.cohesionStrength > 0 {
            var indices: [Int] = []
            indices.reserveCapacity(group.members.count)
            for member in group.members {
                if let index = indexByID[member] {
                    indices.append(index)
                }
            }
            guard indices.count > 1 else { continue }
            groupForces.append(GroupForce(
                indices: indices,
                strength: group.cohesionStrength
            ))
            let perPairStrength = intraGroupCoefficient / Double(indices.count - 1)
            for a in 0..<(indices.count - 1) {
                for b in (a + 1)..<indices.count {
                    let i = indices[a]
                    let j = indices[b]
                    let lo = UInt64(min(i, j))
                    let hi = UInt64(max(i, j))
                    let key = (lo << 32) | hi
                    if seenPairs.contains(key) { continue }
                    let endpointDegree = max(degreeWeights[i], degreeWeights[j])
                    let ideal = radii[i] + radii[j]
                        + intraGroupGap
                        + min(28.0, effectiveGap * 0.08 * endpointDegree)
                    groupSprings.append(GroupSpring(
                        i: i,
                        j: j,
                        ideal: ideal,
                        strength: perPairStrength
                    ))
                }
            }
        }

        var working = positions
        var dispX = Array(repeating: 0.0, count: n)
        var dispY = Array(repeating: 0.0, count: n)

        for step in 0..<iterations {
            for k in 0..<n {
                dispX[k] = 0
                dispY[k] = 0
            }

            // Pairwise repulsion. The local radius grows with endpoint
            // degree and incident label load, so dense hubs reserve enough
            // personal space for their neighbours before spring attraction
            // pulls them into angle slots.
            for i in 0..<(n - 1) {
                let pix = Double(working[i].x)
                let piy = Double(working[i].y)
                for j in (i + 1)..<n {
                    let dx = pix - Double(working[j].x)
                    let dy = piy - Double(working[j].y)
                    let distSq = dx * dx + dy * dy
                    let dist = max(sqrt(distSq), 0.01)
                    let pairK = personalRadii[i] + personalRadii[j] + effectiveGap
                    let pairCutoff = max(repelCutoff, pairK * 2.05)
                    if dist > pairCutoff { continue }
                    let force = (pairK * pairK) / dist
                    let ux = dx / dist
                    let uy = dy / dist
                    dispX[i] += ux * force
                    dispY[i] += uy * force
                    dispX[j] -= ux * force
                    dispY[j] -= uy * force
                }
            }

            // Spring attraction along direct edges. `force = d² / ideal` is
            // the standard FR attractive law. With per-edge `ideal` the
            // equilibrium between attraction and the `k²/d` repulsion lands
            // at roughly `(k² · ideal)^(1/3)`, which is ≈ `ideal` when the
            // two cards are average-sized and scales up for larger cards.
            for spring in springs {
                let i = spring.i
                let j = spring.j
                let dx = Double(working[i].x) - Double(working[j].x)
                let dy = Double(working[i].y) - Double(working[j].y)
                let dist = max(sqrt(dx * dx + dy * dy), 0.01)
                let ux = dx / dist
                let uy = dy / dist
                let force = (dist * dist) / spring.ideal
                dispX[i] -= ux * force
                dispY[i] -= uy * force
                dispX[j] += ux * force
                dispY[j] += uy * force
            }

            // Intra-group pseudo-springs: same FR attractive law as real
            // edges, but scaled by `perPairStrength` so the total per-card
            // pseudo-force normalises to ≈ one real edge regardless of
            // group size. Real edges are already covered by `springs`
            // above; `groupSprings` only contains same-group pairs that do
            // not share an edge.
            for spring in groupSprings {
                let i = spring.i
                let j = spring.j
                let dx = Double(working[i].x) - Double(working[j].x)
                let dy = Double(working[i].y) - Double(working[j].y)
                let dist = max(sqrt(dx * dx + dy * dy), 0.01)
                let ux = dx / dist
                let uy = dy / dist
                let force = spring.strength * (dist * dist) / spring.ideal
                dispX[i] -= ux * force
                dispY[i] -= uy * force
                dispX[j] += ux * force
                dispY[j] += uy * force
            }

            // Per-edge axis snap. For every spring (real + intra-group),
            // pull the *perpendicular* coordinate to its midpoint so the
            // edge tips toward the nearer cardinal axis. Edges already
            // axis-aligned (zero perpendicular delta) experience no force.
            for spring in springs {
                let i = spring.i
                let j = spring.j
                let xi = Double(working[i].x)
                let yi = Double(working[i].y)
                let xj = Double(working[j].x)
                let yj = Double(working[j].y)
                let dx = xj - xi
                let dy = yj - yi
                if abs(dx) >= abs(dy) {
                    let midY = (yi + yj) * 0.5
                    dispY[i] += (midY - yi) * axisAlignBias
                    dispY[j] += (midY - yj) * axisAlignBias
                } else {
                    let midX = (xi + xj) * 0.5
                    dispX[i] += (midX - xi) * axisAlignBias
                    dispX[j] += (midX - xj) * axisAlignBias
                }
            }
            for spring in groupSprings {
                let i = spring.i
                let j = spring.j
                let xi = Double(working[i].x)
                let yi = Double(working[i].y)
                let xj = Double(working[j].x)
                let yj = Double(working[j].y)
                let dx = xj - xi
                let dy = yj - yi
                if abs(dx) >= abs(dy) {
                    let midY = (yi + yj) * 0.5
                    dispY[i] += (midY - yi) * axisAlignBias
                    dispY[j] += (midY - yj) * axisAlignBias
                } else {
                    let midX = (xi + xj) * 0.5
                    dispX[i] += (midX - xi) * axisAlignBias
                    dispX[j] += (midX - xj) * axisAlignBias
                }
            }

            // Global gravity. Computing centroid every iteration is O(n) and
            // fast — no need to amortise across iterations because the
            // centroid drifts as the layout settles.
            var globalCX = 0.0
            var globalCY = 0.0
            for idx in 0..<n {
                globalCX += Double(working[idx].x)
                globalCY += Double(working[idx].y)
            }
            globalCX /= Double(n)
            globalCY /= Double(n)
            for idx in 0..<n {
                dispX[idx] += (globalCX - Double(working[idx].x)) * gravityStrength
                dispY[idx] += (globalCY - Double(working[idx].y)) * gravityStrength
            }

            // Compute group centroids once per iteration. They feed two
            // forces: linear cohesion (pulls every member toward the
            // centroid) and inter-group axis snap (translates the group
            // as a rigid body toward a shared row or column with its
            // neighbours).
            var groupCX = [Double](repeating: 0, count: groupForces.count)
            var groupCY = [Double](repeating: 0, count: groupForces.count)
            for (gi, group) in groupForces.enumerated() {
                var cx = 0.0
                var cy = 0.0
                for idx in group.indices {
                    cx += Double(working[idx].x)
                    cy += Double(working[idx].y)
                }
                let invCount = 1.0 / Double(group.indices.count)
                groupCX[gi] = cx * invCount
                groupCY[gi] = cy * invCount
            }

            // Group cohesion: linear Hookean pull toward the group centroid.
            //   `F = strength · (centroid − position)`.
            // With `strength = 0.05` a card 200 pt off centroid feels a 10 pt
            // pull while the FR spring at the same distance is ≈ 200 pt — so
            // cohesion is a few-percent bias, not a dominant force, which is
            // what we want for a *grouping hint*. Multi-member groups only —
            // singletons would have `centroid == position` and contribute
            // nothing.
            for (gi, group) in groupForces.enumerated() {
                let cx = groupCX[gi]
                let cy = groupCY[gi]
                let weight = group.strength
                for idx in group.indices {
                    let dx = cx - Double(working[idx].x)
                    let dy = cy - Double(working[idx].y)
                    dispX[idx] += dx * weight
                    dispY[idx] += dy * weight
                }
            }

            // Cool the temperature so movement shrinks as we approach the
            // final iteration. Polynomial decay outperforms linear here
            // because it preserves more freedom in the early passes when the
            // spiral seed is still far from equilibrium.
            let progress = Double(step) / Double(iterations)
            let temperature = initialTemp * pow(max(1.0 - progress, 0.0), coolingExponent)

            for i in 0..<n {
                let magnitude = sqrt(dispX[i] * dispX[i] + dispY[i] * dispY[i])
                if magnitude < 0.0001 { continue }
                let limited = min(magnitude, temperature)
                let scale = limited / magnitude
                working[i].x += CGFloat(dispX[i] * scale)
                working[i].y += CGFloat(dispY[i] * scale)
            }
        }

        positions = working
    }

    // MARK: - Edge length constraints

    private struct EdgeLengthConstraint: Sendable {
        let i: Int
        let j: Int
        let length: Double
    }

    /// Capture the current centre-to-centre length for each unique card pair.
    /// Later group-separation passes may rotate or translate local structures,
    /// but they should project back to these lengths instead of stretching an
    /// edge just to create more whitespace between groups.
    private static func edgeLengthConstraints(
        positions: [CGPoint],
        edges: [CompoundGraph.CardEdge],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> [EdgeLengthConstraint] {
        var constraints: [EdgeLengthConstraint] = []
        constraints.reserveCapacity(edges.count)
        var seenPairs: Set<UInt64> = []
        for edge in edges {
            guard
                let i = indexByID[edge.source],
                let j = indexByID[edge.target],
                i != j
            else { continue }
            let lo = UInt64(min(i, j))
            let hi = UInt64(max(i, j))
            let key = (lo << 32) | hi
            guard seenPairs.insert(key).inserted else { continue }
            let dx = Double(positions[j].x - positions[i].x)
            let dy = Double(positions[j].y - positions[i].y)
            constraints.append(EdgeLengthConstraint(
                i: i,
                j: j,
                length: max(sqrt(dx * dx + dy * dy), 0.001)
            ))
        }
        return constraints
    }

    /// Restore captured edge lengths with a simple pairwise projection. Each
    /// pass preserves the midpoint of the edge and moves the endpoints
    /// symmetrically, so the correction changes distance but not the edge's
    /// chosen orientation.
    private static func projectEdgeLengths(
        positions: inout [CGPoint],
        constraints: [EdgeLengthConstraint],
        iterations: Int
    ) {
        guard !constraints.isEmpty, iterations > 0 else { return }
        let epsilon = 0.001
        for _ in 0..<iterations {
            var moved = false
            for constraint in constraints {
                let i = constraint.i
                let j = constraint.j
                let dx = Double(positions[j].x - positions[i].x)
                let dy = Double(positions[j].y - positions[i].y)
                let distance = sqrt(dx * dx + dy * dy)
                guard distance > epsilon else { continue }
                let error = distance - constraint.length
                if abs(error) <= epsilon { continue }
                let ux = dx / distance
                let uy = dy / distance
                let correction = error * 0.5
                positions[i].x += CGFloat(ux * correction)
                positions[i].y += CGFloat(uy * correction)
                positions[j].x -= CGFloat(ux * correction)
                positions[j].y -= CGFloat(uy * correction)
                moved = true
            }
            if !moved { break }
        }
    }

    // MARK: - Group axis snap

    /// Project every disjoint pair of group bounding boxes toward a shared
    /// row or column, and try to increase / reduce their alignment-axis gap
    /// toward the visual target without permanently stretching edges.
    ///
    /// FR alone settles disjoint groups at whatever diagonal minimises
    /// pairwise energy, and FR + repulsion-cutoff alone tends to leave
    /// them further apart than reads as a unified diagram. After FR has
    /// converged we run this rigid-body projection. For each pair we:
    ///
    /// 1. Identify the dominant axis (`|Δx| ≥ |Δy|` means the pair is more
    ///    horizontally than vertically separated) and average the
    ///    perpendicular bbox-center coordinate. This snaps the pair onto
    ///    a shared row or column.
    /// 2. Measure the empty space between the bboxes along the alignment axis
    ///    and shift both groups symmetrically toward the target gap. This is a
    ///    proposal, not an absolute command: each snap iteration immediately
    ///    projects all direct edge lengths back to their captured values. The
    ///    final result therefore uses only angular / rotational freedom to
    ///    create group separation; it does not buy separation by lengthening
    ///    the connecting edges.
    ///
    /// Bbox-center (not centroid) makes the projection robust to
    /// asymmetric vertical distributions — e.g. a group with one card up
    /// top and two at the bottom has centroid below bbox center, so
    /// centroid-snap leaves the bboxes visually offset even after centroid
    /// alignment.
    ///
    /// The shift is applied uniformly to every member so the group
    /// translates rigidly, preserving its internal shape. Multiple passes
    /// converge multi-group configurations where pair-wise snaps interact
    /// (e.g. three groups settle to a row, a column, or an L-shape).
    ///
    /// Overlapping or nested groups (where one group's members are a
    /// subset of another's) are skipped — translating both would shift
    /// the shared cards twice in conflicting directions, deforming the
    /// inner group. Overlap resolution after this pass corrects any
    /// residual collisions caused by the rigid translation.
    private static func snapGroupCentroidsToAxes(
        positions: inout [CGPoint],
        sizes: [CGSize],
        edges: [CompoundGraph.CardEdge],
        edgeLengthConstraints: [EdgeLengthConstraint],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) {
        struct GroupView {
            let indices: [Int]
            let memberSet: Set<Int>
            let padding: Double
            var minX: Double
            var minY: Double
            var maxX: Double
            var maxY: Double
            var cx: Double { (minX + maxX) * 0.5 }
            var cy: Double { (minY + maxY) * 0.5 }
        }
        var views: [GroupView] = []
        views.reserveCapacity(groups.count)
        for group in groups where group.cohesionStrength > 0 {
            var indices: [Int] = []
            indices.reserveCapacity(group.members.count)
            for member in group.members {
                if let idx = indexByID[member] {
                    indices.append(idx)
                }
            }
            guard indices.count > 1 else { continue }
            // positions hold card *centers*; the rendered group bbox is
            // the union of card *rectangles* plus padding, so we extend
            // each center by ±halfSize to match the bbox the renderer
            // will actually draw.
            var minX = Double.infinity
            var minY = Double.infinity
            var maxX = -Double.infinity
            var maxY = -Double.infinity
            for idx in indices {
                let cx = Double(positions[idx].x)
                let cy = Double(positions[idx].y)
                let halfW = Double(sizes[idx].width) * 0.5
                let halfH = Double(sizes[idx].height) * 0.5
                let cardMinX = cx - halfW
                let cardMaxX = cx + halfW
                let cardMinY = cy - halfH
                let cardMaxY = cy + halfH
                if cardMinX < minX { minX = cardMinX }
                if cardMinY < minY { minY = cardMinY }
                if cardMaxX > maxX { maxX = cardMaxX }
                if cardMaxY > maxY { maxY = cardMaxY }
            }
            views.append(GroupView(
                indices: indices,
                memberSet: Set(indices),
                padding: Double(group.style.padding),
                minX: minX,
                minY: minY,
                maxX: maxX,
                maxY: maxY
            ))
        }
        guard views.count > 1 else { return }
        func refreshViews() {
            for viewIndex in views.indices {
                var minX = Double.infinity
                var minY = Double.infinity
                var maxX = -Double.infinity
                var maxY = -Double.infinity
                for idx in views[viewIndex].indices {
                    let cx = Double(positions[idx].x)
                    let cy = Double(positions[idx].y)
                    let halfW = Double(sizes[idx].width) * 0.5
                    let halfH = Double(sizes[idx].height) * 0.5
                    if cx - halfW < minX { minX = cx - halfW }
                    if cy - halfH < minY { minY = cy - halfH }
                    if cx + halfW > maxX { maxX = cx + halfW }
                    if cy + halfH > maxY { maxY = cy + halfH }
                }
                views[viewIndex].minX = minX
                views[viewIndex].minY = minY
                views[viewIndex].maxX = maxX
                views[viewIndex].maxY = maxY
            }
        }

        // Detect which member-disjoint group pairs are joined by at least
        // one cross-edge. FR pulls those pairs together via the cross-edge
        // spring; without a larger target gap they would settle with their
        // padded bboxes touching (or overlapping) once the snap aligns
        // them on a shared row/column. Pairs with no cross-edge are truly
        // isolated and can sit tight.
        var memberToViews: [Int: [Int]] = [:]
        memberToViews.reserveCapacity(views.reduce(0) { $0 + $1.indices.count })
        for (vi, view) in views.enumerated() {
            for member in view.indices {
                memberToViews[member, default: []].append(vi)
            }
        }
        var linkedPairs: Set<UInt64> = []
        for edge in edges {
            guard
                let s = indexByID[edge.source],
                let t = indexByID[edge.target],
                s != t
            else { continue }
            let sViews = memberToViews[s] ?? []
            let tViews = memberToViews[t] ?? []
            // If both endpoints already share a group, this edge belongs to
            // that shared group. Do not also treat it as a direct link between
            // the endpoints' other groups; otherwise a bridge group edge such
            // as `carol -> dave` (where `carol ∈ left+bridge` and
            // `dave ∈ right+bridge`) incorrectly inflates the left/right gap
            // and makes the bridge edge much longer than its siblings.
            if !Set(sViews).isDisjoint(with: Set(tViews)) {
                continue
            }
            for sv in sViews {
                for tv in tViews where sv != tv {
                    // Only record pairs we'll actually snap — i.e. the
                    // two views are member-disjoint.
                    if !views[sv].memberSet.isDisjoint(with: views[tv].memberSet) {
                        continue
                    }
                    let lo = UInt64(min(sv, tv))
                    let hi = UInt64(max(sv, tv))
                    linkedPairs.insert((lo << 32) | hi)
                }
            }
        }

        // Two independent strengths:
        //
        //   - `perpSnapStrength`: pulls the off-axis (perpendicular)
        //     centers of each pair toward their midpoint. Kept *gentle*
        //     so groups tend toward shared rows / columns without
        //     locking in. With 0.2 × 10 the residual perpendicular
        //     offset is `(1 − 0.2)^10 ≈ 11%` — enough alignment to
        //     read as orthogonal, but not so tight that a 1-member
        //     group sandwiched between larger groups gets forcibly
        //     stacked into the same column. Earlier we used 0.5 × 18
        //     which converged to ~0% residual and visually read as
        //     "rigid stacking", obscuring genuine asymmetries.
        //
        //   - `gapSnapStrength`: pulls the on-axis gap between padded
        //     bboxes toward the per-pair target gap. Kept *stronger*
        //     because the target gap is what enforces "linked groups
        //     sit at distance 220, isolated groups at distance 72" —
        //     a weak strength would leave linked pairs much closer
        //     than 100 and unrelated pairs much farther than 40.
        //     0.45 × 10 ≈ 0.25% residual, so the gap reaches its
        //     target reliably.
        //
        // Both run for the same `snapIterations` pass count; only
        // the per-iteration strength differs.
        let perpSnapStrength: Double = 0.2
        let gapSnapStrength: Double = 0.45
        let snapIterations = 10
        // Target empty gap between *padded* bboxes along the alignment
        // axis. `groupBoundingBoxes` adds each group's `style.padding` to
        // its inner card bbox, so the per-pair target gap on the inner
        // card bboxes is `padA + padB + extraGap`.
        //   - Isolated pairs: 72 pt — enough repulsion that adjacent group
        //     bboxes do not visually merge, while still keeping disconnected
        //     islands within the same viewport.
        //   - Linked pairs: 220 pt — a member of group A connected to a
        //     member of group B is a strong visual statement ("these
        //     groups *interact*"). To make that interaction legible
        //     the two groups must be clearly apart, otherwise the
        //     cross-edge label gets crammed against the bboxes and
        //     the diagram reads as one merged region. 180 pt gives
        //     room for the edge plus its label between the padded
        //     bboxes, and is large enough that FR's cross-group
        //     spring (rest length ≈ radii + 1.5 × gap ≈ 280 centre-to-
        //     centre for average cards) cannot collapse the gap back
        //     to zero — the snap pass adds the remaining push.
        let isolatedPaddedGap: Double = 72
        let linkedPaddedGap: Double = 220
        for _ in 0..<snapIterations {
            for a in 0..<(views.count - 1) {
                for b in (a + 1)..<views.count {
                    // Skip overlapping or nested pairs — rigid translation
                    // of both groups would double-shift the shared cards.
                    if !views[a].memberSet.isDisjoint(with: views[b].memberSet) {
                        continue
                    }
                    let pairKey = (UInt64(a) << 32) | UInt64(b)
                    let isLinked = linkedPairs.contains(pairKey)
                    let extraGap = isLinked ? linkedPaddedGap : isolatedPaddedGap
                    let targetGap = views[a].padding + views[b].padding + extraGap

                    let dx = views[b].cx - views[a].cx
                    let dy = views[b].cy - views[a].cy
                    if abs(dx) >= abs(dy) {
                        // Horizontal alignment: snap y centers, then move
                        // along x until the bbox gap matches targetGap.
                        let mid = (views[a].cy + views[b].cy) * 0.5
                        let shiftAy = (mid - views[a].cy) * perpSnapStrength
                        let shiftBy = (mid - views[b].cy) * perpSnapStrength
                        views[a].minY += shiftAy
                        views[a].maxY += shiftAy
                        views[b].minY += shiftBy
                        views[b].maxY += shiftBy
                        for idx in views[a].indices {
                            positions[idx].y += CGFloat(shiftAy)
                        }
                        for idx in views[b].indices {
                            positions[idx].y += CGFloat(shiftBy)
                        }
                        // Bidirectional pull/push: if xGap > targetGap pull
                        // together, if xGap < targetGap push apart. This is
                        // necessary because FR's cross-edge spring leaves
                        // linked pairs *closer* than targetGap, so a
                        // one-way pull would never separate them.
                        let xGap: Double
                        let direction: Double
                        if dx > 0 {
                            xGap = views[b].minX - views[a].maxX
                            direction = 1
                        } else {
                            xGap = views[a].minX - views[b].maxX
                            direction = -1
                        }
                        let delta = (xGap - targetGap) * gapSnapStrength * 0.5
                        let shiftAx = direction * delta
                        let shiftBx = -direction * delta
                        views[a].minX += shiftAx
                        views[a].maxX += shiftAx
                        views[b].minX += shiftBx
                        views[b].maxX += shiftBx
                        for idx in views[a].indices {
                            positions[idx].x += CGFloat(shiftAx)
                        }
                        for idx in views[b].indices {
                            positions[idx].x += CGFloat(shiftBx)
                        }
                    } else {
                        // Vertical alignment: snap x centers, then move
                        // along y to reach targetGap.
                        let mid = (views[a].cx + views[b].cx) * 0.5
                        let shiftAx = (mid - views[a].cx) * perpSnapStrength
                        let shiftBx = (mid - views[b].cx) * perpSnapStrength
                        views[a].minX += shiftAx
                        views[a].maxX += shiftAx
                        views[b].minX += shiftBx
                        views[b].maxX += shiftBx
                        for idx in views[a].indices {
                            positions[idx].x += CGFloat(shiftAx)
                        }
                        for idx in views[b].indices {
                            positions[idx].x += CGFloat(shiftBx)
                        }
                        let yGap: Double
                        let direction: Double
                        if dy > 0 {
                            yGap = views[b].minY - views[a].maxY
                            direction = 1
                        } else {
                            yGap = views[a].minY - views[b].maxY
                            direction = -1
                        }
                        let delta = (yGap - targetGap) * gapSnapStrength * 0.5
                        let shiftAy = direction * delta
                        let shiftBy = -direction * delta
                        views[a].minY += shiftAy
                        views[a].maxY += shiftAy
                        views[b].minY += shiftBy
                        views[b].maxY += shiftBy
                        for idx in views[a].indices {
                            positions[idx].y += CGFloat(shiftAy)
                        }
                        for idx in views[b].indices {
                            positions[idx].y += CGFloat(shiftBy)
                        }
                    }
                }
            }
            projectEdgeLengths(
                positions: &positions,
                constraints: edgeLengthConstraints,
                iterations: 4
            )
            refreshViews()
        }
    }

    // MARK: - Non-member ejection

    /// Project every non-member card out of every group's rendered bbox.
    ///
    /// `groupBoundingBoxes` draws each group as the rectangular union of
    /// its member cards plus `style.padding`. FR alone has no notion of
    /// "stay outside the rectangle of groups I do not belong to" — a
    /// card connected to multiple groups can settle at the centroid of
    /// its connections, which may fall inside one of those groups'
    /// bboxes. The rendered diagram then shows the group enclosing a
    /// node that is not a member, which reads as the node being part
    /// of the group.
    ///
    /// This pass detects every (non-member, group) pair where the card
    /// center is inside the group's padded bbox (plus a small visual
    /// gap so the card sits clearly outside the drawn outline), and
    /// projects the card outward along the axis-aligned shortest exit
    /// vector. Cards inside multiple groups receive accumulated exit
    /// vectors from each containing group so a single pass usually
    /// escapes the intersection region; a few iterations handle the
    /// rare cascades where ejecting from group A lands inside group B.
    ///
    /// Members of the affected groups do not move, so the per-group
    /// bbox is invariant across the passes — we compute it once and
    /// reuse it. The subsequent `resolveOverlaps` pass corrects any
    /// card-card collisions the ejection introduces.
    private static func ejectNonMembersFromGroups(
        positions: inout [CGPoint],
        sizes: [CGSize],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) {
        struct GroupSpec {
            let indices: [Int]
            let memberSet: Set<Int>
            let pad: Double
        }
        // Clearance added beyond the rendered bbox edge. The renderer
        // insets the bbox by `group.style.padding`; `visualGap` is the
        // extra empty band a non-member must clear after ejection so
        // its rectangle sits visibly *outside* the drawn outline. The
        // value must exceed the largest typical `style.padding`,
        // otherwise an ejected non-member positioned at +visualGap
        // from group A's border can still fall inside the padding
        // zone of an adjacent group B that lists it as a member, and
        // B's rendered bbox would then touch (or overlap) A's. 32 pt
        // covers the common padding range of 12-24 pt with a clear
        // gap on top.
        let visualGap = Double(LayoutSpacing.groupNode)
        // Push past the bbox edge by `escapeSlack` so floating-point
        // error doesn't re-detect the card as inside on the next pass.
        let escapeSlack: Double = 4
        let iterations = 16

        var specs: [GroupSpec] = []
        specs.reserveCapacity(groups.count)
        for group in groups where group.cohesionStrength > 0 {
            var indices: [Int] = []
            indices.reserveCapacity(group.members.count)
            for member in group.members {
                if let idx = indexByID[member] {
                    indices.append(idx)
                }
            }
            guard indices.count > 1 else { continue }
            specs.append(GroupSpec(
                indices: indices,
                memberSet: Set(indices),
                pad: Double(group.style.padding) + visualGap
            ))
        }
        guard !specs.isEmpty else { return }

        let n = positions.count
        var bboxes = [(Double, Double, Double, Double)](
            repeating: (0, 0, 0, 0),
            count: specs.count
        )
        for _ in 0..<iterations {
            // Recompute each bbox from current positions. Ejecting a
            // non-member of group A may move a card that is *also* a
            // member of group B (cards can be members of one group and
            // non-members of another); without recomputing, group B's
            // bbox stays stale and a subsequent pass against B uses
            // wrong geometry.
            for (sIdx, spec) in specs.enumerated() {
                var minX = Double.infinity
                var minY = Double.infinity
                var maxX = -Double.infinity
                var maxY = -Double.infinity
                for idx in spec.indices {
                    let cx = Double(positions[idx].x)
                    let cy = Double(positions[idx].y)
                    let halfW = Double(sizes[idx].width) * 0.5
                    let halfH = Double(sizes[idx].height) * 0.5
                    if cx - halfW < minX { minX = cx - halfW }
                    if cy - halfH < minY { minY = cy - halfH }
                    if cx + halfW > maxX { maxX = cx + halfW }
                    if cy + halfH > maxY { maxY = cy + halfH }
                }
                bboxes[sIdx] = (
                    minX - spec.pad,
                    minY - spec.pad,
                    maxX + spec.pad,
                    maxY + spec.pad
                )
            }

            var moved = false
            for idx in 0..<n {
                let cx = Double(positions[idx].x)
                let cy = Double(positions[idx].y)
                let halfW = Double(sizes[idx].width) * 0.5
                let halfH = Double(sizes[idx].height) * 0.5
                let cardMinX = cx - halfW
                let cardMinY = cy - halfH
                let cardMaxX = cx + halfW
                let cardMaxY = cy + halfH
                var fx: Double = 0
                var fy: Double = 0
                var anyOverlap = false
                for (sIdx, spec) in specs.enumerated() {
                    if spec.memberSet.contains(idx) { continue }
                    let (gMinX, gMinY, gMaxX, gMaxY) = bboxes[sIdx]
                    // Rect-vs-rect intersection. Center-in-bbox is not
                    // enough — the user requires that no card *edge*
                    // overlap the group boundary, so we must check the
                    // full card rectangle against the inflated bbox.
                    if cardMaxX <= gMinX { continue }
                    if cardMinX >= gMaxX { continue }
                    if cardMaxY <= gMinY { continue }
                    if cardMinY >= gMaxY { continue }
                    // Axis-aligned penetration depth for each side.
                    // penLeft = distance to push the card *left* so
                    // its right edge meets the bbox's left edge, etc.
                    let penLeft = cardMaxX - gMinX
                    let penRight = gMaxX - cardMinX
                    let penTop = cardMaxY - gMinY
                    let penBottom = gMaxY - cardMinY
                    let minPen = min(min(penLeft, penRight), min(penTop, penBottom))
                    if minPen == penLeft {
                        fx -= minPen + escapeSlack
                    } else if minPen == penRight {
                        fx += minPen + escapeSlack
                    } else if minPen == penTop {
                        fy -= minPen + escapeSlack
                    } else {
                        fy += minPen + escapeSlack
                    }
                    anyOverlap = true
                }
                if anyOverlap {
                    positions[idx].x += CGFloat(fx)
                    positions[idx].y += CGFloat(fy)
                    moved = true
                }
            }
            if !moved { break }
        }
    }

    // MARK: - Edge angle relaxation

    /// Rotate edge directions toward cardinal axes without changing the
    /// distance target. For each unique card pair, the local proposal keeps the
    /// edge midpoint fixed and reuses the edge's current centre-to-centre
    /// length; only the angle changes. Proposals are averaged per card so hubs
    /// with several incident edges settle into a compromise instead of letting
    /// the last processed edge dominate.
    private static func relaxEdgeAngles(
        positions: inout [CGPoint],
        edges: [CompoundGraph.CardEdge],
        indexByID: [CompoundGraph.Card.ID: Int],
        iterations: Int,
        strength: Double
    ) {
        struct Pair {
            let i: Int
            let j: Int
        }

        let n = positions.count
        guard n > 1, iterations > 0, strength > 0 else { return }

        var pairs: [Pair] = []
        pairs.reserveCapacity(edges.count)
        var seenPairs: Set<UInt64> = []
        for edge in edges {
            guard
                let i = indexByID[edge.source],
                let j = indexByID[edge.target],
                i != j
            else { continue }
            let lo = UInt64(min(i, j))
            let hi = UInt64(max(i, j))
            let key = (lo << 32) | hi
            if seenPairs.insert(key).inserted {
                pairs.append(Pair(i: i, j: j))
            }
        }
        guard !pairs.isEmpty else { return }

        var deltaX = [Double](repeating: 0, count: n)
        var deltaY = [Double](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: n)
        let maxStep: Double = 36
        let epsilon: Double = 0.001

        for _ in 0..<iterations {
            for i in 0..<n {
                deltaX[i] = 0
                deltaY[i] = 0
                counts[i] = 0
            }

            for pair in pairs {
                let a = pair.i
                let b = pair.j
                let ax = Double(positions[a].x)
                let ay = Double(positions[a].y)
                let bx = Double(positions[b].x)
                let by = Double(positions[b].y)
                let vx = bx - ax
                let vy = by - ay
                let length = sqrt(vx * vx + vy * vy)
                guard length > epsilon else { continue }

                let theta = atan2(vy, vx)
                let target = nearestCardinalAngle(to: theta)
                let angleDelta = shortestAngleDelta(from: theta, to: target)
                guard abs(angleDelta) > 0.002 else { continue }

                let nextTheta = theta + angleDelta * strength
                let nextX = cos(nextTheta) * length
                let nextY = sin(nextTheta) * length
                let midX = (ax + bx) * 0.5
                let midY = (ay + by) * 0.5

                let desiredAX = midX - nextX * 0.5
                let desiredAY = midY - nextY * 0.5
                let desiredBX = midX + nextX * 0.5
                let desiredBY = midY + nextY * 0.5

                deltaX[a] += desiredAX - ax
                deltaY[a] += desiredAY - ay
                deltaX[b] += desiredBX - bx
                deltaY[b] += desiredBY - by
                counts[a] += 1
                counts[b] += 1
            }

            var moved = false
            for i in 0..<n where counts[i] > 0 {
                var dx = deltaX[i] / Double(counts[i])
                var dy = deltaY[i] / Double(counts[i])
                let magnitude = sqrt(dx * dx + dy * dy)
                if magnitude > maxStep {
                    let scale = maxStep / magnitude
                    dx *= scale
                    dy *= scale
                }
                if abs(dx) > epsilon || abs(dy) > epsilon {
                    positions[i].x += CGFloat(dx)
                    positions[i].y += CGFloat(dy)
                    moved = true
                }
            }
            if !moved { break }
        }
    }

    private static func nearestCardinalAngle(to angle: Double) -> Double {
        let quarterTurn = Double.pi / 2
        return (angle / quarterTurn).rounded() * quarterTurn
    }

    private static func shortestAngleDelta(from angle: Double, to target: Double) -> Double {
        var delta = target - angle
        while delta <= -Double.pi {
            delta += Double.pi * 2
        }
        while delta > Double.pi {
            delta -= Double.pi * 2
        }
        return delta
    }

    /// Allocate angular slots around high-degree cards while preserving each
    /// incident edge's current centre-to-centre length. FR decides the
    /// distance budget; this pass spends that budget by distributing a hub's
    /// neighbours around a full circle instead of leaving them in one arc.
    private static func spreadHubIncidentEdges(
        positions: inout [CGPoint],
        edges: [CompoundGraph.CardEdge],
        indexByID: [CompoundGraph.Card.ID: Int],
        iterations: Int,
        strength: Double
    ) {
        let n = positions.count
        guard n > 2, iterations > 0, strength > 0 else { return }

        var neighbours = Array(repeating: [Int](), count: n)
        var seenPairs: Set<UInt64> = []
        seenPairs.reserveCapacity(edges.count)
        for edge in edges {
            guard
                let i = indexByID[edge.source],
                let j = indexByID[edge.target],
                i != j
            else { continue }
            let lo = UInt64(min(i, j))
            let hi = UInt64(max(i, j))
            let key = (lo << 32) | hi
            guard seenPairs.insert(key).inserted else { continue }
            neighbours[i].append(j)
            neighbours[j].append(i)
        }

        let degrees = neighbours.map(\.count)
        let hubs = (0..<n).filter { degrees[$0] >= 4 }
        guard !hubs.isEmpty else { return }

        var deltaX = [Double](repeating: 0, count: n)
        var deltaY = [Double](repeating: 0, count: n)
        var counts = [Double](repeating: 0, count: n)
        let fullTurn = Double.pi * 2
        let epsilon: Double = 0.001
        let maxStep: Double = 72

        for _ in 0..<iterations {
            for index in 0..<n {
                deltaX[index] = 0
                deltaY[index] = 0
                counts[index] = 0
            }

            for hub in hubs {
                let hubX = Double(positions[hub].x)
                let hubY = Double(positions[hub].y)
                let ordered = neighbours[hub].sorted()
                guard ordered.count >= 4 else { continue }

                let slot = fullTurn / Double(ordered.count)
                let phase = Double((hub % 11) - 5) * 0.07
                let startAngle = -Double.pi + phase

                for (slotIndex, neighbour) in ordered.enumerated() {
                    let vx = Double(positions[neighbour].x) - hubX
                    let vy = Double(positions[neighbour].y) - hubY
                    let length = max(sqrt(vx * vx + vy * vy), epsilon)
                    let targetAngle = startAngle + slot * Double(slotIndex)
                    let desiredX = hubX + cos(targetAngle) * length
                    let desiredY = hubY + sin(targetAngle) * length
                    let neighbourWeight = degrees[neighbour] >= 4 ? 0.35 : 1.0
                    deltaX[neighbour] += (desiredX - Double(positions[neighbour].x))
                        * neighbourWeight
                    deltaY[neighbour] += (desiredY - Double(positions[neighbour].y))
                        * neighbourWeight
                    counts[neighbour] += neighbourWeight
                }
            }

            var moved = false
            for index in 0..<n where counts[index] > 0 {
                var dx = deltaX[index] / counts[index] * strength
                var dy = deltaY[index] / counts[index] * strength
                let magnitude = sqrt(dx * dx + dy * dy)
                if magnitude > maxStep {
                    let scale = maxStep / magnitude
                    dx *= scale
                    dy *= scale
                }
                if abs(dx) > epsilon || abs(dy) > epsilon {
                    positions[index].x += CGFloat(dx)
                    positions[index].y += CGFloat(dy)
                    moved = true
                }
            }
            if !moved { break }
        }
    }

    // MARK: - Bridge fan-out

    private struct GroupMembershipIndex {
        let memberToGroups: [Int: Set<Int>]
        let groupMembers: [[Int]]
    }

    private static func groupMembershipIndex(
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> GroupMembershipIndex {
        var memberToGroups: [Int: Set<Int>] = [:]
        var groupMembers: [[Int]] = []
        groupMembers.reserveCapacity(groups.count)
        for group in groups {
            var indices: [Int] = []
            indices.reserveCapacity(group.members.count)
            for member in group.members {
                if let idx = indexByID[member] {
                    indices.append(idx)
                    memberToGroups[idx, default: []].insert(groupMembers.count)
                }
            }
            groupMembers.append(indices)
        }
        return GroupMembershipIndex(
            memberToGroups: memberToGroups,
            groupMembers: groupMembers
        )
    }

    private static func sameGroupPairKeys(
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> Set<UInt64> {
        var result: Set<UInt64> = []
        for group in groups where group.cohesionStrength > 0 {
            let indices = group.members.compactMap { indexByID[$0] }
            guard indices.count > 1 else { continue }
            for a in 0..<(indices.count - 1) {
                for b in (a + 1)..<indices.count {
                    result.insert(pairKey(indices[a], indices[b]))
                }
            }
        }
        return result
    }

    /// For a bridge-owned edge (`source` and `target` share a bridge group, and
    /// each endpoint also belongs to a different outer group), orient the edge
    /// horizontally according to outer-group order. This keeps the bridge edge
    /// length fixed while preventing the two outer groups from stacking on the
    /// same vertical line.
    private static func orientBridgeEdgesByGroupOrder(
        positions: inout [CGPoint],
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) {
        let membership = groupMembershipIndex(groups: groups, indexByID: indexByID)
        let epsilon = 0.001
        for edge in edges {
            guard
                let source = indexByID[edge.source],
                let target = indexByID[edge.target],
                source != target,
                let sourceGroups = membership.memberToGroups[source],
                let targetGroups = membership.memberToGroups[target]
            else { continue }
            let shared = sourceGroups.intersection(targetGroups)
            guard !shared.isEmpty else { continue }
            let sourceOuter = sourceGroups.subtracting(shared).min()
            let targetOuter = targetGroups.subtracting(shared).min()
            guard let sourceOuter, let targetOuter, sourceOuter != targetOuter else { continue }

            let sx = Double(positions[source].x)
            let sy = Double(positions[source].y)
            let tx = Double(positions[target].x)
            let ty = Double(positions[target].y)
            let dx = tx - sx
            let dy = ty - sy
            let length = max(sqrt(dx * dx + dy * dy), epsilon)
            let midX = (sx + tx) * 0.5
            let midY = (sy + ty) * 0.5
            let sign = sourceOuter < targetOuter ? 1.0 : -1.0
            positions[source] = CGPoint(
                x: midX - sign * length * 0.5,
                y: midY
            )
            positions[target] = CGPoint(
                x: midX + sign * length * 0.5,
                y: midY
            )
        }
    }

    /// Push the non-anchor members of the outer groups away from a bridge-owned
    /// edge. The bridge endpoints stay as the short shared boundary, while each
    /// outer group opens to its side. This is the missing degree of freedom when
    /// edge lengths are fixed: separation must come from rotating / fanning the
    /// groups, not from moving the bridge endpoints farther apart.
    private static func fanOutGroupsAroundBridgeEdges(
        positions: inout [CGPoint],
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) {
        let membership = groupMembershipIndex(groups: groups, indexByID: indexByID)
        let horizontalGap: Double = 145
        let verticalGap: Double = 34
        let strength: Double = 0.75

        for edge in edges {
            guard
                let source = indexByID[edge.source],
                let target = indexByID[edge.target],
                source != target,
                let sourceGroups = membership.memberToGroups[source],
                let targetGroups = membership.memberToGroups[target]
            else { continue }
            let shared = sourceGroups.intersection(targetGroups)
            guard !shared.isEmpty else { continue }
            let sourceOuter = sourceGroups.subtracting(shared).min()
            let targetOuter = targetGroups.subtracting(shared).min()
            guard let sourceOuter, let targetOuter, sourceOuter != targetOuter else { continue }

            let sourceSign = sourceOuter < targetOuter ? -1.0 : 1.0
            let targetSign = -sourceSign
            fanOutGroupMembers(
                positions: &positions,
                members: membership.groupMembers[sourceOuter],
                anchor: source,
                horizontalSign: sourceSign,
                horizontalGap: horizontalGap,
                verticalGap: verticalGap,
                strength: strength
            )
            fanOutGroupMembers(
                positions: &positions,
                members: membership.groupMembers[targetOuter],
                anchor: target,
                horizontalSign: targetSign,
                horizontalGap: horizontalGap,
                verticalGap: verticalGap,
                strength: strength
            )
        }
    }

    private static func fanOutGroupMembers(
        positions: inout [CGPoint],
        members: [Int],
        anchor: Int,
        horizontalSign: Double,
        horizontalGap: Double,
        verticalGap: Double,
        strength: Double
    ) {
        let movable = members.filter { $0 != anchor }
        guard !movable.isEmpty else { return }
        let anchorX = Double(positions[anchor].x)
        let anchorY = Double(positions[anchor].y)
        let sorted = movable.sorted { lhs, rhs in
            if positions[lhs].y != positions[rhs].y {
                return positions[lhs].y < positions[rhs].y
            }
            return lhs < rhs
        }
        let centerOffset = Double(sorted.count - 1) * 0.5
        for (offset, member) in sorted.enumerated() {
            let targetX = anchorX + horizontalSign * horizontalGap
            let targetY = anchorY + (Double(offset) - centerOffset) * verticalGap
            positions[member].x += CGFloat((targetX - Double(positions[member].x)) * strength)
            positions[member].y += CGFloat((targetY - Double(positions[member].y)) * strength)
        }
    }

    // MARK: - Separation constraints

    /// Project overlapping (or insufficiently-spaced) card rectangles apart
    /// along the axis of smaller penetration. Every pair must clear `margin`
    /// of empty space on the dominant axis; otherwise the pair is pushed
    /// symmetrically away from each other.
    private static func resolveOverlaps(
        positions: inout [CGPoint],
        sizes: [CGSize],
        margin: CGFloat,
        iterations: Int
    ) {
        resolveOverlaps(
            positions: &positions,
            sizes: sizes,
            horizontalMargin: margin,
            verticalMargin: margin,
            sameGroupPairs: [],
            iterations: iterations
        )
    }

    private static func resolveOverlaps(
        positions: inout [CGPoint],
        sizes: [CGSize],
        horizontalMargin: CGFloat,
        verticalMargin: CGFloat,
        sameGroupPairs: Set<UInt64>,
        iterations: Int
    ) {
        let n = positions.count
        guard n > 1 else { return }

        for _ in 0..<iterations {
            var moved = false
            for i in 0..<n {
                let iRect = CGRect(
                    x: positions[i].x - sizes[i].width / 2,
                    y: positions[i].y - sizes[i].height / 2,
                    width: sizes[i].width,
                    height: sizes[i].height
                )
                for j in (i + 1)..<n {
                    let isSameGroup = sameGroupPairs.contains(pairKey(i, j))
                    let pairHorizontalMargin = isSameGroup
                        ? LayoutSpacing.groupInternalNodeNodeHorizontal
                        : horizontalMargin
                    let pairVerticalMargin = isSameGroup
                        ? LayoutSpacing.groupInternalNodeNodeVertical
                        : verticalMargin
                    let rjBase = CGRect(
                        x: positions[j].x - sizes[j].width / 2,
                        y: positions[j].y - sizes[j].height / 2,
                        width: sizes[j].width,
                        height: sizes[j].height
                    )
                    let expandedI = iRect.insetBy(
                        dx: -pairHorizontalMargin / 2,
                        dy: -pairVerticalMargin / 2
                    )
                    let expandedJ = rjBase.insetBy(
                        dx: -pairHorizontalMargin / 2,
                        dy: -pairVerticalMargin / 2
                    )
                    let inter = expandedI.intersection(expandedJ)
                    guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
                    moved = true
                    if inter.width < inter.height {
                        let push = inter.width / 2
                        if positions[i].x < positions[j].x {
                            positions[i].x -= push
                            positions[j].x += push
                        } else {
                            positions[i].x += push
                            positions[j].x -= push
                        }
                    } else {
                        let push = inter.height / 2
                        if positions[i].y < positions[j].y {
                            positions[i].y -= push
                            positions[j].y += push
                        } else {
                            positions[i].y += push
                            positions[j].y -= push
                        }
                    }
                }
            }
            if !moved { break }
        }
    }

    /// Project disjoint group bounding boxes apart after card-level collision
    /// resolution. Groups that share members are intentionally skipped because
    /// a shared card makes fully disjoint bboxes impossible without duplicating
    /// the card; disjoint groups should never visually merge.
    private static func resolveGroupOverlaps(
        positions: inout [CGPoint],
        sizes: [CGSize],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int],
        margin: CGFloat,
        iterations: Int
    ) {
        struct GroupBox {
            let indices: [Int]
            let memberSet: Set<Int>
            var rect: CGRect
        }

        guard groups.count > 1, iterations > 0 else { return }

        func makeBoxes() -> [GroupBox] {
            var boxes: [GroupBox] = []
            boxes.reserveCapacity(groups.count)
            for group in groups where group.cohesionStrength > 0 {
                var indices: [Int] = []
                indices.reserveCapacity(group.members.count)
                for member in group.members {
                    if let idx = indexByID[member] {
                        indices.append(idx)
                    }
                }
                guard !indices.isEmpty else { continue }
                var rect: CGRect = .null
                for idx in indices {
                    let center = positions[idx]
                    let size = sizes[idx]
                    let cardRect = CGRect(
                        x: center.x - size.width / 2,
                        y: center.y - size.height / 2,
                        width: size.width,
                        height: size.height
                    )
                    rect = rect.isNull ? cardRect : rect.union(cardRect)
                }
                let padded = rect.insetBy(
                    dx: -(group.style.padding + margin / 2),
                    dy: -(group.style.padding + margin / 2)
                )
                boxes.append(GroupBox(
                    indices: indices,
                    memberSet: Set(indices),
                    rect: padded
                ))
            }
            return boxes
        }

        func translate(_ indices: [Int], dx: CGFloat, dy: CGFloat) {
            for idx in indices {
                positions[idx].x += dx
                positions[idx].y += dy
            }
        }

        for _ in 0..<iterations {
            var boxes = makeBoxes()
            var moved = false
            guard boxes.count > 1 else { return }
            for a in 0..<(boxes.count - 1) {
                for b in (a + 1)..<boxes.count {
                    if !boxes[a].memberSet.isDisjoint(with: boxes[b].memberSet) {
                        continue
                    }
                    let intersection = boxes[a].rect.intersection(boxes[b].rect)
                    guard
                        !intersection.isNull,
                        intersection.width > 0,
                        intersection.height > 0
                    else { continue }

                    moved = true
                    if intersection.width < intersection.height {
                        let push = intersection.width / 2
                        if boxes[a].rect.midX <= boxes[b].rect.midX {
                            translate(boxes[a].indices, dx: -push, dy: 0)
                            translate(boxes[b].indices, dx: push, dy: 0)
                            boxes[a].rect.origin.x -= push
                            boxes[b].rect.origin.x += push
                        } else {
                            translate(boxes[a].indices, dx: push, dy: 0)
                            translate(boxes[b].indices, dx: -push, dy: 0)
                            boxes[a].rect.origin.x += push
                            boxes[b].rect.origin.x -= push
                        }
                    } else {
                        let push = intersection.height / 2
                        if boxes[a].rect.midY <= boxes[b].rect.midY {
                            translate(boxes[a].indices, dx: 0, dy: -push)
                            translate(boxes[b].indices, dx: 0, dy: push)
                            boxes[a].rect.origin.y -= push
                            boxes[b].rect.origin.y += push
                        } else {
                            translate(boxes[a].indices, dx: 0, dy: push)
                            translate(boxes[b].indices, dx: 0, dy: -push)
                            boxes[a].rect.origin.y += push
                            boxes[b].rect.origin.y -= push
                        }
                    }
                }
            }
            if !moved { break }
        }
    }

    /// Tighten groups whose members were stretched apart by external edges.
    /// The pass is deliberately late in the pipeline: edge-length projection
    /// has already done its work, so the final visual priority becomes using
    /// group interiors efficiently without letting cards collide.
    private static func compactSparseGroups(
        positions: inout [CGPoint],
        radii: [Double],
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int],
        cardCount: Int,
        iterations: Int
    ) {
        guard groups.count > 0, iterations > 0 else { return }

        let effectiveGap = adaptiveEdgeGap(cardCount: cardCount)
        let targetGap = effectiveGap * 0.55
        let strength: Double = 0.32
        let epsilon: Double = 0.001

        struct GroupSpec {
            let indices: [Int]
        }

        var connectedPairs: Set<UInt64> = []
        connectedPairs.reserveCapacity(edges.count)
        for edge in edges {
            guard
                let source = indexByID[edge.source],
                let target = indexByID[edge.target],
                source != target
            else { continue }
            let lo = UInt64(min(source, target))
            let hi = UInt64(max(source, target))
            connectedPairs.insert((lo << 32) | hi)
        }

        var specs: [GroupSpec] = []
        specs.reserveCapacity(groups.count)
        for group in groups where group.cohesionStrength > 0 {
            var seen: Set<Int> = []
            var indices: [Int] = []
            indices.reserveCapacity(group.members.count)
            for member in group.members {
                guard let idx = indexByID[member] else { continue }
                if seen.insert(idx).inserted {
                    indices.append(idx)
                }
            }
            if indices.count > 1 {
                var hasInternalEdge = false
                for aOffset in 0..<(indices.count - 1) where !hasInternalEdge {
                    let a = indices[aOffset]
                    for b in indices[(aOffset + 1)...] {
                        let lo = UInt64(min(a, b))
                        let hi = UInt64(max(a, b))
                        if connectedPairs.contains((lo << 32) | hi) {
                            hasInternalEdge = true
                            break
                        }
                    }
                }
                if hasInternalEdge {
                    continue
                }
                specs.append(GroupSpec(indices: indices))
            }
        }
        guard !specs.isEmpty else { return }

        for _ in 0..<iterations {
            var moved = false
            for spec in specs {
                for aOffset in 0..<(spec.indices.count - 1) {
                    let a = spec.indices[aOffset]
                    for b in spec.indices[(aOffset + 1)...] {
                        let dx = Double(positions[b].x - positions[a].x)
                        let dy = Double(positions[b].y - positions[a].y)
                        let distance = sqrt(dx * dx + dy * dy)
                        guard distance > epsilon else { continue }
                        let desired = radii[a] + radii[b] + targetGap
                        guard distance > desired else { continue }

                        let correction = (distance - desired) * strength * 0.5
                        let ux = dx / distance
                        let uy = dy / distance
                        positions[a].x += CGFloat(ux * correction)
                        positions[a].y += CGFloat(uy * correction)
                        positions[b].x -= CGFloat(ux * correction)
                        positions[b].y -= CGFloat(uy * correction)
                        moved = true
                    }
                }
            }
            if !moved { break }
        }
    }

    // MARK: - Distance constraints and area compaction

    private enum LayoutCompactionAxis: Hashable {
        case horizontal
        case vertical
    }

    private struct LayoutCompactionUnit {
        let groupIndices: Set<Int>
        let indices: [Int]
        let memberSet: Set<Int>
        let rect: CGRect
    }

    private struct UnitSeparationConstraint {
        let before: Int
        let after: Int
        let gap: CGFloat
    }

    private struct NodeNodeGap {
        let horizontal: CGFloat
        let vertical: CGFloat
    }

    private static func enforceLayoutDistanceConstraints(
        positions: inout [CGPoint],
        sizes: [CGSize],
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int],
        iterations: Int
    ) {
        guard iterations > 0 else { return }
        let edgeMultiplicity = edgeMultiplicityByCardPair(edges: edges, indexByID: indexByID)
        let sameGroupPairs = sameGroupPairKeys(groups: groups, indexByID: indexByID)
        let groupEdgeCounts = disjointGroupEdgeCounts(edges: edges, groups: groups, indexByID: indexByID)

        for _ in 0..<iterations {
            var moved = false
            moved = resolveNodeDistances(
                positions: &positions,
                sizes: sizes,
                edgeMultiplicity: edgeMultiplicity,
                sameGroupPairs: sameGroupPairs,
                iterations: 1
            ) || moved
            moved = resolveGroupDistances(
                positions: &positions,
                sizes: sizes,
                groups: groups,
                indexByID: indexByID,
                groupEdgeCounts: groupEdgeCounts,
                iterations: 1
            ) || moved
            moved = ejectNonMembersFromGroupsOnce(
                positions: &positions,
                sizes: sizes,
                groups: groups,
                indexByID: indexByID
            ) || moved
            if !moved { break }
        }
    }

    private static func minimizeConstrainedOutlineArea(
        positions: inout [CGPoint],
        sizes: [CGSize],
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) {
        guard positions.count > 1 else { return }
        let edgeMultiplicity = edgeMultiplicityByCardPair(edges: edges, indexByID: indexByID)
        let groupEdgeCounts = disjointGroupEdgeCounts(edges: edges, groups: groups, indexByID: indexByID)

        for _ in 0..<4 {
            let units = layoutCompactionUnits(
                positions: positions,
                sizes: sizes,
                groups: groups,
                indexByID: indexByID
            )
            guard units.count > 1 else { return }
            let oldArea = layoutArea(
                layoutOutlineRect(positions: positions, sizes: sizes, groups: groups, indexByID: indexByID)
            )
            let constraints = unitSeparationConstraints(
                units: units,
                edgeMultiplicity: edgeMultiplicity,
                groupEdgeCounts: groupEdgeCounts
            )
            let compacted = compactedPositions(
                positions: positions,
                units: units,
                constraints: constraints
            )
            var candidate = compacted
            enforceLayoutDistanceConstraints(
                positions: &candidate,
                sizes: sizes,
                edges: edges,
                groups: groups,
                indexByID: indexByID,
                iterations: 6
            )
            let newArea = layoutArea(
                layoutOutlineRect(positions: candidate, sizes: sizes, groups: groups, indexByID: indexByID)
            )
            guard newArea <= oldArea + 0.5 else { break }
            positions = candidate
        }
    }

    private static func resolveNodeDistances(
        positions: inout [CGPoint],
        sizes: [CGSize],
        edgeMultiplicity: [UInt64: Int],
        sameGroupPairs: Set<UInt64>,
        iterations: Int
    ) -> Bool {
        guard positions.count > 1, iterations > 0 else { return false }
        var movedAny = false
        for _ in 0..<iterations {
            var moved = false
            var rects = cardRects(positions: positions, sizes: sizes)
            for a in 0..<(rects.count - 1) {
                for b in (a + 1)..<rects.count {
                    let key = pairKey(a, b)
                    let gap = minimumNodeNodeGap(
                        edgeMultiplicity: edgeMultiplicity[key] ?? 0,
                        sameGroup: sameGroupPairs.contains(key)
                    )
                    let expandedA = rects[a].insetBy(dx: -gap.horizontal / 2, dy: -gap.vertical / 2)
                    let expandedB = rects[b].insetBy(dx: -gap.horizontal / 2, dy: -gap.vertical / 2)
                    let intersection = expandedA.intersection(expandedB)
                    guard
                        !intersection.isNull,
                        intersection.width > 0,
                        intersection.height > 0
                    else { continue }
                    moved = true
                    movedAny = true
                    if intersection.width <= intersection.height {
                        let direction: CGFloat
                        if abs(rects[a].midX - rects[b].midX) < 0.001 {
                            direction = a < b ? 1 : -1
                        } else {
                            direction = rects[a].midX < rects[b].midX ? 1 : -1
                        }
                        let shift = intersection.width / 2
                        positions[a].x -= direction * shift
                        positions[b].x += direction * shift
                        rects[a].origin.x -= direction * shift
                        rects[b].origin.x += direction * shift
                    } else {
                        let direction: CGFloat
                        if abs(rects[a].midY - rects[b].midY) < 0.001 {
                            direction = a < b ? 1 : -1
                        } else {
                            direction = rects[a].midY < rects[b].midY ? 1 : -1
                        }
                        let shift = intersection.height / 2
                        positions[a].y -= direction * shift
                        positions[b].y += direction * shift
                        rects[a].origin.y -= direction * shift
                        rects[b].origin.y += direction * shift
                    }
                }
            }
            if !moved { break }
        }
        return movedAny
    }

    private static func resolveGroupDistances(
        positions: inout [CGPoint],
        sizes: [CGSize],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int],
        groupEdgeCounts: [UInt64: Int],
        iterations: Int
    ) -> Bool {
        guard groups.count > 1, iterations > 0 else { return false }
        var movedAny = false
        for _ in 0..<iterations {
            var boxes = layeredGroupBoxes(
                positions: positions,
                sizes: sizes,
                groups: groups,
                indexByID: indexByID
            )
            guard boxes.count > 1 else { return movedAny }
            var moved = false
            for a in 0..<(boxes.count - 1) {
                for b in (a + 1)..<boxes.count {
                    guard boxes[a].memberSet.isDisjoint(with: boxes[b].memberSet) else {
                        continue
                    }
                    let pair = pairKey(boxes[a].groupIndex, boxes[b].groupIndex)
                    let gap = minimumGroupGroupGap(edgeCount: groupEdgeCounts[pair] ?? 0)
                    let expandedA = boxes[a].rect.insetBy(dx: -gap / 2, dy: -gap / 2)
                    let expandedB = boxes[b].rect.insetBy(dx: -gap / 2, dy: -gap / 2)
                    let intersection = expandedA.intersection(expandedB)
                    guard
                        !intersection.isNull,
                        intersection.width > 0,
                        intersection.height > 0
                    else { continue }
                    moved = true
                    movedAny = true
                    if intersection.width <= intersection.height {
                        let direction: CGFloat
                        if abs(boxes[a].rect.midX - boxes[b].rect.midX) < 0.001 {
                            direction = boxes[a].groupIndex < boxes[b].groupIndex ? 1 : -1
                        } else {
                            direction = boxes[a].rect.midX < boxes[b].rect.midX ? 1 : -1
                        }
                        let shift = intersection.width / 2
                        translate(indices: boxes[a].indices, dx: -direction * shift, dy: 0, positions: &positions)
                        translate(indices: boxes[b].indices, dx: direction * shift, dy: 0, positions: &positions)
                        boxes[a].rect.origin.x -= direction * shift
                        boxes[b].rect.origin.x += direction * shift
                    } else {
                        let direction: CGFloat
                        if abs(boxes[a].rect.midY - boxes[b].rect.midY) < 0.001 {
                            direction = boxes[a].groupIndex < boxes[b].groupIndex ? 1 : -1
                        } else {
                            direction = boxes[a].rect.midY < boxes[b].rect.midY ? 1 : -1
                        }
                        let shift = intersection.height / 2
                        translate(indices: boxes[a].indices, dx: 0, dy: -direction * shift, positions: &positions)
                        translate(indices: boxes[b].indices, dx: 0, dy: direction * shift, positions: &positions)
                        boxes[a].rect.origin.y -= direction * shift
                        boxes[b].rect.origin.y += direction * shift
                    }
                }
            }
            if !moved { break }
        }
        return movedAny
    }

    private static func ejectNonMembersFromGroupsOnce(
        positions: inout [CGPoint],
        sizes: [CGSize],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> Bool {
        struct GroupSpec {
            let indices: [Int]
            let memberSet: Set<Int>
            let rect: CGRect
        }

        var specs: [GroupSpec] = []
        specs.reserveCapacity(groups.count)
        for group in groups where group.cohesionStrength > 0 {
            let indices = group.members.compactMap { indexByID[$0] }
            guard !indices.isEmpty else { continue }
            let rect = rectForIndices(indices, positions: positions, sizes: sizes)
                .insetBy(
                    dx: -(group.style.padding + LayoutSpacing.groupNode),
                    dy: -(group.style.padding + LayoutSpacing.groupNode)
                )
            specs.append(GroupSpec(indices: indices, memberSet: Set(indices), rect: rect))
        }
        guard !specs.isEmpty else { return false }

        var moved = false
        var rects = cardRects(positions: positions, sizes: sizes)
        for index in rects.indices {
            for spec in specs where !spec.memberSet.contains(index) {
                let rect = rects[index]
                let intersection = rect.intersection(spec.rect)
                guard
                    !intersection.isNull,
                    intersection.width > 0,
                    intersection.height > 0
                else { continue }
                moved = true
                let penLeft = rect.maxX - spec.rect.minX
                let penRight = spec.rect.maxX - rect.minX
                let penTop = rect.maxY - spec.rect.minY
                let penBottom = spec.rect.maxY - rect.minY
                let minPen = min(min(penLeft, penRight), min(penTop, penBottom))
                if minPen == penLeft {
                    let shift = penLeft + 0.5
                    positions[index].x -= shift
                    rects[index].origin.x -= shift
                } else if minPen == penRight {
                    let shift = penRight + 0.5
                    positions[index].x += shift
                    rects[index].origin.x += shift
                } else if minPen == penTop {
                    let shift = penTop + 0.5
                    positions[index].y -= shift
                    rects[index].origin.y -= shift
                } else {
                    let shift = penBottom + 0.5
                    positions[index].y += shift
                    rects[index].origin.y += shift
                }
            }
        }
        return moved
    }

    private static func layoutCompactionUnits(
        positions: [CGPoint],
        sizes: [CGSize],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> [LayoutCompactionUnit] {
        var units: [LayoutCompactionUnit] = []
        units.reserveCapacity(groups.count + positions.count)
        var assigned: Set<Int> = []
        let membership = groupMembershipIndex(groups: groups, indexByID: indexByID)
        let groupComponents = overlappingGroupComponents(membership: membership, groupCount: groups.count)
        for component in groupComponents {
            let indices = component
                .flatMap { membership.groupMembers[$0] }
                .reduce(into: Set<Int>()) { result, index in
                    result.insert(index)
                }
                .sorted()
            guard !indices.isEmpty else { continue }
            var rect = CGRect.null
            for groupIndex in component {
                let groupMembers = membership.groupMembers[groupIndex]
                guard !groupMembers.isEmpty else { continue }
                let groupRect = rectForIndices(groupMembers, positions: positions, sizes: sizes)
                    .insetBy(
                        dx: -groups[groupIndex].style.padding,
                        dy: -groups[groupIndex].style.padding
                    )
                rect = rect.isNull ? groupRect : rect.union(groupRect)
            }
            units.append(LayoutCompactionUnit(
                groupIndices: Set(component),
                indices: indices,
                memberSet: Set(indices),
                rect: rect
            ))
            assigned.formUnion(indices)
        }

        for index in positions.indices where !assigned.contains(index) {
            let rect = CGRect(
                x: positions[index].x - sizes[index].width / 2,
                y: positions[index].y - sizes[index].height / 2,
                width: sizes[index].width,
                height: sizes[index].height
            )
            units.append(LayoutCompactionUnit(
                groupIndices: [],
                indices: [index],
                memberSet: [index],
                rect: rect
            ))
        }
        return units
    }

    private static func overlappingGroupComponents(
        membership: GroupMembershipIndex,
        groupCount: Int
    ) -> [[Int]] {
        guard groupCount > 0 else { return [] }
        var disjointSet = DisjointSet(count: groupCount)
        var ownerByMember: [Int: Int] = [:]
        for groupIndex in 0..<groupCount {
            for member in membership.groupMembers[groupIndex] {
                if let owner = ownerByMember[member] {
                    disjointSet.union(owner, groupIndex)
                } else {
                    ownerByMember[member] = groupIndex
                }
            }
        }

        var components: [Int: [Int]] = [:]
        for groupIndex in 0..<groupCount {
            components[disjointSet.find(groupIndex), default: []].append(groupIndex)
        }
        return components.values
            .map { $0.sorted() }
            .sorted { lhs, rhs in
                (lhs.first ?? 0) < (rhs.first ?? 0)
            }
    }

    private static func unitSeparationConstraints(
        units: [LayoutCompactionUnit],
        edgeMultiplicity: [UInt64: Int],
        groupEdgeCounts: [UInt64: Int]
    ) -> [LayoutCompactionAxis: [UnitSeparationConstraint]] {
        var result: [LayoutCompactionAxis: [UnitSeparationConstraint]] = [
            .horizontal: [],
            .vertical: []
        ]
        guard units.count > 1 else { return result }

        for a in 0..<(units.count - 1) {
            for b in (a + 1)..<units.count {
                guard units[a].memberSet.isDisjoint(with: units[b].memberSet) else {
                    continue
                }
                let gap = minimumUnitGap(
                    lhs: units[a],
                    rhs: units[b],
                    edgeMultiplicity: edgeMultiplicity,
                    groupEdgeCounts: groupEdgeCounts
                )
                let axis = separationAxis(lhs: units[a].rect, rhs: units[b].rect, gap: gap)
                let resolvedGap = axis == .horizontal ? gap.horizontal : gap.vertical
                let before: Int
                let after: Int
                switch axis {
                case .horizontal:
                    if units[a].rect.midX <= units[b].rect.midX {
                        before = a
                        after = b
                    } else {
                        before = b
                        after = a
                    }
                case .vertical:
                    if units[a].rect.midY <= units[b].rect.midY {
                        before = a
                        after = b
                    } else {
                        before = b
                        after = a
                    }
                }
                result[axis, default: []].append(UnitSeparationConstraint(
                    before: before,
                    after: after,
                    gap: resolvedGap
                ))
            }
        }
        return result
    }

    private static func compactedPositions(
        positions: [CGPoint],
        units: [LayoutCompactionUnit],
        constraints: [LayoutCompactionAxis: [UnitSeparationConstraint]]
    ) -> [CGPoint] {
        let xOrigins = compactedUnitOrigins(
            units: units,
            axis: .horizontal,
            constraints: constraints[.horizontal] ?? []
        )
        let yOrigins = compactedUnitOrigins(
            units: units,
            axis: .vertical,
            constraints: constraints[.vertical] ?? []
        )
        var result = positions
        for (unitIndex, unit) in units.enumerated() {
            let dx = xOrigins[unitIndex] - unit.rect.minX
            let dy = yOrigins[unitIndex] - unit.rect.minY
            for index in unit.indices {
                result[index].x += dx
                result[index].y += dy
            }
        }
        return result
    }

    private static func compactedUnitOrigins(
        units: [LayoutCompactionUnit],
        axis: LayoutCompactionAxis,
        constraints: [UnitSeparationConstraint]
    ) -> [CGFloat] {
        let order = units.indices.sorted { lhs, rhs in
            let left = axis == .horizontal ? units[lhs].rect.minX : units[lhs].rect.minY
            let right = axis == .horizontal ? units[rhs].rect.minX : units[rhs].rect.minY
            if abs(left - right) > 0.001 {
                return left < right
            }
            return lhs < rhs
        }
        var incoming: [Int: [UnitSeparationConstraint]] = [:]
        for constraint in constraints {
            incoming[constraint.after, default: []].append(constraint)
        }
        var origins = Array(repeating: CGFloat(0), count: units.count)
        for unitIndex in order {
            var origin: CGFloat = 0
            for constraint in incoming[unitIndex] ?? [] {
                let size = axis == .horizontal
                    ? units[constraint.before].rect.width
                    : units[constraint.before].rect.height
                origin = max(origin, origins[constraint.before] + size + constraint.gap)
            }
            origins[unitIndex] = origin
        }
        return origins
    }

    private static func separationAxis(
        lhs: CGRect,
        rhs: CGRect,
        gap: NodeNodeGap
    ) -> LayoutCompactionAxis {
        let dx = abs(rhs.midX - lhs.midX)
        let dy = abs(rhs.midY - lhs.midY)
        let requiredX = (lhs.width + rhs.width) / 2 + gap.horizontal
        let requiredY = (lhs.height + rhs.height) / 2 + gap.vertical
        let xRatio = requiredX > 0 ? dx / requiredX : 0
        let yRatio = requiredY > 0 ? dy / requiredY : 0
        return xRatio >= yRatio ? .horizontal : .vertical
    }

    private static func minimumUnitGap(
        lhs: LayoutCompactionUnit,
        rhs: LayoutCompactionUnit,
        edgeMultiplicity: [UInt64: Int],
        groupEdgeCounts: [UInt64: Int]
    ) -> NodeNodeGap {
        let edgeCount = edgeCountBetweenUnits(lhs, rhs, edgeMultiplicity: edgeMultiplicity)
        if !lhs.groupIndices.isEmpty, !rhs.groupIndices.isEmpty {
            var groupEdgeCount = 0
            for left in lhs.groupIndices {
                for right in rhs.groupIndices where left != right {
                    groupEdgeCount += groupEdgeCounts[pairKey(left, right)] ?? 0
                }
            }
            let gap = minimumGroupGroupGap(edgeCount: max(groupEdgeCount, edgeCount))
            return NodeNodeGap(horizontal: gap, vertical: gap)
        }
        if !lhs.groupIndices.isEmpty || !rhs.groupIndices.isEmpty {
            let gap = LayoutSpacing.groupNode + CGFloat(min(edgeCount, 4)) * LayoutSpacing.edgeEdge
            return NodeNodeGap(horizontal: gap, vertical: gap)
        }
        return minimumNodeNodeGap(edgeMultiplicity: edgeCount, sameGroup: false)
    }

    private static func edgeCountBetweenUnits(
        _ lhs: LayoutCompactionUnit,
        _ rhs: LayoutCompactionUnit,
        edgeMultiplicity: [UInt64: Int]
    ) -> Int {
        var count = 0
        for left in lhs.memberSet {
            for right in rhs.memberSet where left != right {
                count += edgeMultiplicity[pairKey(left, right)] ?? 0
            }
        }
        return count
    }

    private static func minimumNodeNodeGap(edgeMultiplicity: Int, sameGroup: Bool) -> NodeNodeGap {
        let baseHorizontal = sameGroup
            ? LayoutSpacing.groupInternalNodeNodeHorizontal
            : LayoutSpacing.nodeNodeHorizontal
        let baseVertical = sameGroup
            ? LayoutSpacing.groupInternalNodeNodeVertical
            : LayoutSpacing.nodeNodeVertical
        guard edgeMultiplicity > 0 else {
            return NodeNodeGap(horizontal: baseHorizontal, vertical: baseVertical)
        }
        let parallelReserve = CGFloat(max(edgeMultiplicity - 1, 0)) * LayoutSpacing.edgeEdge
        let connectedHorizontal = sameGroup
            ? LayoutSpacing.groupInternalConnectedNodeNodeHorizontal
            : LayoutSpacing.connectedNodeNode
        let connectedVertical = sameGroup
            ? LayoutSpacing.groupInternalConnectedNodeNodeVertical
            : LayoutSpacing.connectedNodeNode
        return NodeNodeGap(
            horizontal: max(baseHorizontal, connectedHorizontal + parallelReserve),
            vertical: max(baseVertical, connectedVertical + parallelReserve)
        )
    }

    private static func minimumGroupGroupGap(edgeCount: Int) -> CGFloat {
        LayoutSpacing.groupGroup + CGFloat(min(max(edgeCount, 0), 6)) * LayoutSpacing.edgeEdge
    }

    private static func edgeMultiplicityByCardPair(
        edges: [CompoundGraph.CardEdge],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> [UInt64: Int] {
        var result: [UInt64: Int] = [:]
        result.reserveCapacity(edges.count)
        for edge in edges {
            guard
                let source = indexByID[edge.source],
                let target = indexByID[edge.target],
                source != target
            else { continue }
            result[pairKey(source, target), default: 0] += 1
        }
        return result
    }

    private static func disjointGroupEdgeCounts(
        edges: [CompoundGraph.CardEdge],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> [UInt64: Int] {
        let membership = groupMembershipIndex(groups: groups, indexByID: indexByID)
        var result: [UInt64: Int] = [:]
        result.reserveCapacity(edges.count)
        for edge in edges {
            guard
                let source = indexByID[edge.source],
                let target = indexByID[edge.target],
                source != target,
                let sourceGroups = membership.memberToGroups[source],
                let targetGroups = membership.memberToGroups[target]
            else { continue }
            for sourceGroup in sourceGroups {
                for targetGroup in targetGroups where sourceGroup != targetGroup {
                    guard
                        groups.indices.contains(sourceGroup),
                        groups.indices.contains(targetGroup)
                    else { continue }
                    if Set(membership.groupMembers[sourceGroup]).isDisjoint(
                        with: Set(membership.groupMembers[targetGroup])
                    ) {
                        result[pairKey(sourceGroup, targetGroup), default: 0] += 1
                    }
                }
            }
        }
        return result
    }

    private static func cardRects(
        positions: [CGPoint],
        sizes: [CGSize]
    ) -> [CGRect] {
        positions.indices.map { index in
            CGRect(
                x: positions[index].x - sizes[index].width / 2,
                y: positions[index].y - sizes[index].height / 2,
                width: sizes[index].width,
                height: sizes[index].height
            )
        }
    }

    private static func rectForIndices(
        _ indices: [Int],
        positions: [CGPoint],
        sizes: [CGSize]
    ) -> CGRect {
        var rect = CGRect.null
        for index in indices {
            let cardRect = CGRect(
                x: positions[index].x - sizes[index].width / 2,
                y: positions[index].y - sizes[index].height / 2,
                width: sizes[index].width,
                height: sizes[index].height
            )
            rect = rect.isNull ? cardRect : rect.union(cardRect)
        }
        return rect
    }

    private static func layoutOutlineRect(
        positions: [CGPoint],
        sizes: [CGSize],
        groups: [CompoundGraph.Group],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> CGRect {
        var rect = CGRect.null
        for cardRect in cardRects(positions: positions, sizes: sizes) {
            rect = rect.isNull ? cardRect : rect.union(cardRect)
        }
        for group in groups where group.cohesionStrength > 0 {
            let indices = group.members.compactMap { indexByID[$0] }
            guard !indices.isEmpty else { continue }
            let groupRect = rectForIndices(indices, positions: positions, sizes: sizes)
                .insetBy(dx: -group.style.padding, dy: -group.style.padding)
            rect = rect.isNull ? groupRect : rect.union(groupRect)
        }
        return rect
    }

    private static func layoutArea(_ rect: CGRect) -> CGFloat {
        guard !rect.isNull else { return 0 }
        return max(rect.width, 0) * max(rect.height, 0)
    }

    // MARK: - Canvas anchoring

    /// Convert the centred positions to top-left card origins and compute
    /// the canvas bounding box that contains every card with `padding` slack.
    private static func anchorAndCanvas(
        cards: [CompoundGraph.Card],
        centerPositions: [CGPoint],
        padding: CGFloat
    ) -> ([CompoundGraph.Card.ID: CGPoint], CGSize) {
        var minX: CGFloat = .infinity
        var minY: CGFloat = .infinity
        var maxX: CGFloat = -.infinity
        var maxY: CGFloat = -.infinity
        for (index, card) in cards.enumerated() {
            let center = centerPositions[index]
            let halfW = card.size.width / 2
            let halfH = card.size.height / 2
            minX = min(minX, center.x - halfW)
            minY = min(minY, center.y - halfH)
            maxX = max(maxX, center.x + halfW)
            maxY = max(maxY, center.y + halfH)
        }
        let offsetX = padding - minX
        let offsetY = padding - minY
        let width = (maxX - minX) + padding * 2
        let height = (maxY - minY) + padding * 2

        var origins: [CompoundGraph.Card.ID: CGPoint] = [:]
        origins.reserveCapacity(cards.count)
        for (index, card) in cards.enumerated() {
            let center = centerPositions[index]
            origins[card.id] = CGPoint(
                x: center.x - card.size.width / 2 + offsetX,
                y: center.y - card.size.height / 2 + offsetY
            )
        }
        return (origins, CGSize(width: max(width, 320), height: max(height, 240)))
    }

    private static func normalizeFinalGeometry(
        cards: [CompoundGraph.Card],
        edges: [CompoundGraph.CardEdge],
        cardPositions: inout [CompoundGraph.Card.ID: CGPoint],
        edgeRoutes: inout [EdgeIdentifier: EdgeRoute],
        edgeLabelPositions: inout [EdgeIdentifier: CGPoint],
        groupBoundingBoxes: inout [CompoundGraph.Group.ID: CGRect],
        canvasSize: inout CGSize,
        padding: CGFloat
    ) {
        var bounds = CGRect(origin: .zero, size: canvasSize)
        for card in cards {
            guard let origin = cardPositions[card.id] else { continue }
            bounds = bounds.union(CGRect(origin: origin, size: card.size))
        }
        for route in edgeRoutes.values {
            let points = route.points.isEmpty ? [route.start, route.end] : route.points
            for point in points {
                bounds = bounds.union(CGRect(x: point.x, y: point.y, width: 1, height: 1))
            }
        }
        for edge in edges {
            guard let center = edgeLabelPositions[edge.id] else { continue }
            bounds = bounds.union(edgeLabelRect(center: center, size: edgeLabelSize(edge)))
        }
        for box in groupBoundingBoxes.values {
            bounds = bounds.union(box)
        }
        bounds = bounds.insetBy(dx: -padding, dy: -padding)

        let dx = bounds.minX < 0 ? -bounds.minX : 0
        let dy = bounds.minY < 0 ? -bounds.minY : 0
        if dx > 0 || dy > 0 {
            translateGeometry(
                dx: dx,
                dy: dy,
                cardPositions: &cardPositions,
                edgeRoutes: &edgeRoutes,
                edgeLabelPositions: &edgeLabelPositions,
                groupBoundingBoxes: &groupBoundingBoxes
            )
            bounds = bounds.offsetBy(dx: dx, dy: dy)
        }
        canvasSize = CGSize(
            width: max(canvasSize.width + dx, bounds.maxX, 320),
            height: max(canvasSize.height + dy, bounds.maxY, 240)
        )
    }

    private static func translateGeometry(
        dx: CGFloat,
        dy: CGFloat,
        cardPositions: inout [CompoundGraph.Card.ID: CGPoint],
        edgeRoutes: inout [EdgeIdentifier: EdgeRoute],
        edgeLabelPositions: inout [EdgeIdentifier: CGPoint],
        groupBoundingBoxes: inout [CompoundGraph.Group.ID: CGRect]
    ) {
        for key in cardPositions.keys {
            guard let point = cardPositions[key] else { continue }
            cardPositions[key] = CGPoint(x: point.x + dx, y: point.y + dy)
        }
        for key in edgeRoutes.keys {
            guard let route = edgeRoutes[key] else { continue }
            edgeRoutes[key] = route.translatedBy(dx: dx, dy: dy)
        }
        for key in edgeLabelPositions.keys {
            guard let point = edgeLabelPositions[key] else { continue }
            edgeLabelPositions[key] = CGPoint(x: point.x + dx, y: point.y + dy)
        }
        for key in groupBoundingBoxes.keys {
            guard let rect = groupBoundingBoxes[key] else { continue }
            groupBoundingBoxes[key] = rect.offsetBy(dx: dx, dy: dy)
        }
    }

    // MARK: - Edge routing

    private struct RoutedEdge {
        let edge: CompoundGraph.CardEdge
        let points: [CGPoint]
    }

    private static func computeEdgeRoutes(
        edges: [CompoundGraph.CardEdge],
        cards: [CompoundGraph.Card],
        indexByID: [CompoundGraph.Card.ID: Int],
        cardPositions: [CompoundGraph.Card.ID: CGPoint],
        groups: [CompoundGraph.Group]
    ) -> [EdgeIdentifier: EdgeRoute] {
        var routes: [EdgeIdentifier: EdgeRoute] = [:]
        routes.reserveCapacity(edges.count)
        var routedEdges: [RoutedEdge] = []
        routedEdges.reserveCapacity(edges.count)
        let cardRects = cards.map { card -> CGRect in
            guard let origin = cardPositions[card.id] else {
                preconditionFailure("Card \(card.id) missing from cardPositions")
            }
            return CGRect(origin: origin, size: card.size)
        }
        let ports = edgePortAnchors(
            edges: edges,
            cards: cards,
            indexByID: indexByID,
            cardRects: cardRects
        )
        for edge in edges {
            guard
                let srcIndex = indexByID[edge.source],
                let tgtIndex = indexByID[edge.target],
                let srcOrigin = cardPositions[edge.source],
                let tgtOrigin = cardPositions[edge.target]
            else { continue }
            let srcSize = cards[srcIndex].size
            let tgtSize = cards[tgtIndex].size
            let srcRect = CGRect(origin: srcOrigin, size: srcSize)
            let tgtRect = CGRect(origin: tgtOrigin, size: tgtSize)
            let srcCenter = CGPoint(x: srcRect.midX, y: srcRect.midY)
            let tgtCenter = CGPoint(x: tgtRect.midX, y: tgtRect.midY)

            if edge.source == edge.target {
                let route = selfLoopRoute(center: srcCenter, size: srcSize, parallelIndex: edge.parallelIndex)
                routes[edge.id] = route
                continue
            }

            let preferredSourcePort = ports[EdgeEndpointKey(edgeID: edge.id, isSource: true)]
                ?? fallbackEdgePort(rect: srcRect, toward: tgtCenter)
            let preferredTargetPort = ports[EdgeEndpointKey(edgeID: edge.id, isSource: false)]
                ?? fallbackEdgePort(rect: tgtRect, toward: srcCenter)
            let excluded = Set([srcIndex, tgtIndex])
            if
                edge.parallelCount <= 1,
                let directPoints = directOrthogonalRoute(
                    sourceRect: srcRect,
                    targetRect: tgtRect,
                    preferredSourcePort: preferredSourcePort,
                    preferredTargetPort: preferredTargetPort
                ),
                routeClearsNodes(directPoints, cardRects: cardRects, excluding: excluded)
            {
                let route = edgeRoute(points: directPoints)
                routes[edge.id] = route
                routedEdges.append(RoutedEdge(edge: edge, points: route.points.isEmpty ? [route.start, route.end] : route.points))
                continue
            }

            let points = orthogonalEdgePoints(
                edge: edge,
                sourceRect: srcRect,
                targetRect: tgtRect,
                preferredSourcePort: preferredSourcePort,
                preferredTargetPort: preferredTargetPort,
                sourceIndex: srcIndex,
                targetIndex: tgtIndex,
                cardRects: cardRects,
                routedEdges: routedEdges,
                currentEdge: edge
            )
            let midpoint = routePathMidpoint(points).point

            let route = EdgeRoute(
                start: points.first ?? preferredSourcePort.point,
                end: points.last ?? preferredTargetPort.point,
                control: midpoint,
                isCurved: false,
                points: points
            )
            routes[edge.id] = route
            routedEdges.append(RoutedEdge(edge: edge, points: route.points.isEmpty ? [route.start, route.end] : route.points))
        }
        return recenterSingletonPorts(
            routes: routes,
            edges: edges,
            cards: cards,
            indexByID: indexByID,
            cardRects: cardRects
        )
    }

    private static func directOrthogonalRoute(
        sourceRect: CGRect,
        targetRect: CGRect,
        preferredSourcePort: EdgePort,
        preferredTargetPort: EdgePort
    ) -> [CGPoint]? {
        if sourceRect.maxX <= targetRect.minX {
            return directRoute(
                sourceRect: sourceRect,
                targetRect: targetRect,
                sourceSide: .right,
                targetSide: .left,
                preferredSourcePort: preferredSourcePort,
                preferredTargetPort: preferredTargetPort
            )
        }
        if targetRect.maxX <= sourceRect.minX {
            return directRoute(
                sourceRect: sourceRect,
                targetRect: targetRect,
                sourceSide: .left,
                targetSide: .right,
                preferredSourcePort: preferredSourcePort,
                preferredTargetPort: preferredTargetPort
            )
        }
        if sourceRect.maxY <= targetRect.minY {
            return directRoute(
                sourceRect: sourceRect,
                targetRect: targetRect,
                sourceSide: .bottom,
                targetSide: .top,
                preferredSourcePort: preferredSourcePort,
                preferredTargetPort: preferredTargetPort
            )
        }
        if targetRect.maxY <= sourceRect.minY {
            return directRoute(
                sourceRect: sourceRect,
                targetRect: targetRect,
                sourceSide: .top,
                targetSide: .bottom,
                preferredSourcePort: preferredSourcePort,
                preferredTargetPort: preferredTargetPort
            )
        }
        return nil
    }

    private static func directRoute(
        sourceRect: CGRect,
        targetRect: CGRect,
        sourceSide: EdgePortSide,
        targetSide: EdgePortSide,
        preferredSourcePort: EdgePort,
        preferredTargetPort: EdgePort
    ) -> [CGPoint]? {
        for coordinate in directRouteAxisCandidates(
            sourceRect: sourceRect,
            targetRect: targetRect,
            sourceSide: sourceSide,
            targetSide: targetSide,
            preferredSourcePort: preferredSourcePort,
            preferredTargetPort: preferredTargetPort
        ) {
            guard
                portCoordinateIsAvailable(coordinate, side: sourceSide, rect: sourceRect),
                portCoordinateIsAvailable(coordinate, side: targetSide, rect: targetRect)
            else { continue }
            return [
                directRoutePoint(rect: sourceRect, side: sourceSide, coordinate: coordinate),
                directRoutePoint(rect: targetRect, side: targetSide, coordinate: coordinate)
            ]
        }
        return nil
    }

    private static func directRouteAxisCandidates(
        sourceRect: CGRect,
        targetRect: CGRect,
        sourceSide: EdgePortSide,
        targetSide: EdgePortSide,
        preferredSourcePort: EdgePort,
        preferredTargetPort: EdgePort
    ) -> [CGFloat] {
        var candidates: [CGFloat] = []
        let sourceIsDistributed = preferredSourcePort.side == sourceSide && preferredSourcePort.bucketCount > 1
        let targetIsDistributed = preferredTargetPort.side == targetSide && preferredTargetPort.bucketCount > 1
        if preferredSourcePort.bucketCount > 1 || preferredTargetPort.bucketCount > 1 {
            guard
                preferredSourcePort.bucketCount <= 1 || sourceIsDistributed,
                preferredTargetPort.bucketCount <= 1 || targetIsDistributed
            else {
                return []
            }
            if sourceIsDistributed && targetIsDistributed {
                let sourceCoordinate = portAxisCoordinate(preferredSourcePort)
                let targetCoordinate = portAxisCoordinate(preferredTargetPort)
                return abs(sourceCoordinate - targetCoordinate) < 0.5 ? [sourceCoordinate] : []
            }
            if sourceIsDistributed {
                return [portAxisCoordinate(preferredSourcePort)]
            }
            if targetIsDistributed {
                return [portAxisCoordinate(preferredTargetPort)]
            }
        }
        if sourceIsDistributed {
            candidates.append(portAxisCoordinate(preferredSourcePort))
        }
        if targetIsDistributed {
            candidates.append(portAxisCoordinate(preferredTargetPort))
        }
        if preferredTargetPort.side == targetSide {
            candidates.append(portAxisCoordinate(preferredTargetPort))
        }
        if preferredSourcePort.side == sourceSide {
            candidates.append(portAxisCoordinate(preferredSourcePort))
        }
        candidates.append(overlapCenterCoordinate(
            sourceRect: sourceRect,
            targetRect: targetRect,
            side: sourceSide
        ))
        return uniqueCGFloatValues(candidates)
    }

    private static func overlapCenterCoordinate(
        sourceRect: CGRect,
        targetRect: CGRect,
        side: EdgePortSide
    ) -> CGFloat {
        switch side {
        case .left, .right:
            return (max(sourceRect.minY, targetRect.minY) + min(sourceRect.maxY, targetRect.maxY)) * 0.5
        case .top, .bottom:
            return (max(sourceRect.minX, targetRect.minX) + min(sourceRect.maxX, targetRect.maxX)) * 0.5
        }
    }

    private static func portAxisCoordinate(_ port: EdgePort) -> CGFloat {
        switch port.side {
        case .top, .bottom:
            return port.point.x
        case .left, .right:
            return port.point.y
        }
    }

    private static func portCoordinateIsAvailable(
        _ coordinate: CGFloat,
        side: EdgePortSide,
        rect: CGRect
    ) -> Bool {
        let guardDistance = min(LayoutSpacing.portCornerGuard, max(portRawAxisLength(side: side, rect: rect) / 2, 0))
        let minimum = portAxisMinimum(side: side, rect: rect) + guardDistance
        let maximum = portAxisMaximum(side: side, rect: rect) - guardDistance
        return coordinate >= minimum - 0.5 && coordinate <= maximum + 0.5
    }

    private static func directRoutePoint(
        rect: CGRect,
        side: EdgePortSide,
        coordinate: CGFloat
    ) -> CGPoint {
        switch side {
        case .top:
            return CGPoint(x: coordinate, y: rect.minY)
        case .right:
            return CGPoint(x: rect.maxX, y: coordinate)
        case .bottom:
            return CGPoint(x: coordinate, y: rect.maxY)
        case .left:
            return CGPoint(x: rect.minX, y: coordinate)
        }
    }

    private static func portRawAxisLength(side: EdgePortSide, rect: CGRect) -> CGFloat {
        switch side {
        case .top, .bottom:
            return rect.width
        case .left, .right:
            return rect.height
        }
    }

    private static func portAxisMinimum(side: EdgePortSide, rect: CGRect) -> CGFloat {
        switch side {
        case .top, .bottom:
            return rect.minX
        case .left, .right:
            return rect.minY
        }
    }

    private static func portAxisMaximum(side: EdgePortSide, rect: CGRect) -> CGFloat {
        switch side {
        case .top, .bottom:
            return rect.maxX
        case .left, .right:
            return rect.maxY
        }
    }

    private static func boundarySide(of point: CGPoint, in rect: CGRect) -> EdgePortSide? {
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

    private static func edgeRoute(points: [CGPoint]) -> EdgeRoute {
        let simplified = simplifyRoutePoints(points)
        let start = simplified.first ?? .zero
        let end = simplified.last ?? start
        let midpoint = routePathMidpoint(simplified).point
        return EdgeRoute(
            start: start,
            end: end,
            control: midpoint,
            isCurved: false,
            points: simplified
        )
    }

    private static func recenterSingletonPorts(
        routes: [EdgeIdentifier: EdgeRoute],
        edges: [CompoundGraph.CardEdge],
        cards: [CompoundGraph.Card],
        indexByID: [CompoundGraph.Card.ID: Int],
        cardRects: [CGRect]
    ) -> [EdgeIdentifier: EdgeRoute] {
        var endpointCounts: [EdgePortBucket: Int] = [:]
        var endpointSides: [EdgeEndpointKey: EdgePortSide] = [:]

        for edge in edges where edge.source != edge.target {
            guard
                let route = routes[edge.id],
                let sourceIndex = indexByID[edge.source],
                let targetIndex = indexByID[edge.target],
                let sourceSide = boundarySide(of: route.start, in: cardRects[sourceIndex]),
                let targetSide = boundarySide(of: route.end, in: cardRects[targetIndex])
            else { continue }
            endpointCounts[EdgePortBucket(cardIndex: sourceIndex, side: sourceSide), default: 0] += 1
            endpointCounts[EdgePortBucket(cardIndex: targetIndex, side: targetSide), default: 0] += 1
            endpointSides[EdgeEndpointKey(edgeID: edge.id, isSource: true)] = sourceSide
            endpointSides[EdgeEndpointKey(edgeID: edge.id, isSource: false)] = targetSide
        }

        var updated = routes
        for edge in edges where edge.source != edge.target {
            guard
                let route = updated[edge.id],
                let sourceIndex = indexByID[edge.source],
                let targetIndex = indexByID[edge.target],
                let sourceSide = endpointSides[EdgeEndpointKey(edgeID: edge.id, isSource: true)],
                let targetSide = endpointSides[EdgeEndpointKey(edgeID: edge.id, isSource: false)]
            else { continue }

            let sourceBucket = EdgePortBucket(cardIndex: sourceIndex, side: sourceSide)
            let targetBucket = EdgePortBucket(cardIndex: targetIndex, side: targetSide)
            let sourceCount = endpointCounts[sourceBucket, default: 0]
            let targetCount = endpointCounts[targetBucket, default: 0]
            let sourceRect = cardRects[sourceIndex]
            let targetRect = cardRects[targetIndex]
            let sourcePoint = sourceCount == 1
                ? portPoint(side: sourceSide, rect: sourceRect, index: 0, count: 1)
                : route.start
            let targetPoint = targetCount == 1
                ? portPoint(side: targetSide, rect: targetRect, index: 0, count: 1)
                : route.end

            guard !pointsAreClose(sourcePoint, route.start) || !pointsAreClose(targetPoint, route.end) else {
                continue
            }

            let routedEdges = edges.compactMap { otherEdge -> RoutedEdge? in
                guard otherEdge.id != edge.id, let otherRoute = updated[otherEdge.id] else { return nil }
                return RoutedEdge(
                    edge: otherEdge,
                    points: otherRoute.points.isEmpty ? [otherRoute.start, otherRoute.end] : otherRoute.points
                )
            }
            let centeredSourcePort = EdgePort(point: sourcePoint, side: sourceSide, bucketCount: max(sourceCount, 1))
            let centeredTargetPort = EdgePort(point: targetPoint, side: targetSide, bucketCount: max(targetCount, 1))
            let centeredParallel = edge.parallelCount > 1
                ? CGFloat(edge.parallelIndex) - CGFloat(edge.parallelCount - 1) / 2
                : 0
            guard let centeredPoints = shortestFixedEndpointRoute(
                edge: edge,
                sourcePort: centeredSourcePort,
                targetPort: centeredTargetPort,
                laneOffset: centeredParallel * LayoutSpacing.edgeEdge,
                sourceIndex: sourceIndex,
                targetIndex: targetIndex,
                cardRects: cardRects,
                routedEdges: routedEdges
            ) else { continue }
            updated[edge.id] = edgeRoute(points: centeredPoints)
        }

        return updated
    }

    private static func routingGroupRects(
        groups: [CompoundGraph.Group],
        cardRects: [CGRect],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        result.reserveCapacity(groups.count)
        for (groupIndex, group) in groups.enumerated() {
            var rect = CGRect.null
            for member in group.members {
                guard let index = indexByID[member] else { continue }
                let cardRect = cardRects[index]
                rect = rect.isNull ? cardRect : rect.union(cardRect)
            }
            if !rect.isNull {
                result[groupIndex] = rect
            }
        }
        return result
    }

    private static func sharedRoutingGroup(
        source: Int,
        target: Int,
        membership: GroupMembershipIndex,
        groups: [CompoundGraph.Group]
    ) -> Int? {
        guard
            let sourceGroups = membership.memberToGroups[source],
            let targetGroups = membership.memberToGroups[target]
        else { return nil }
        let shared = sourceGroups.intersection(targetGroups)
        return shared.min { lhs, rhs in
            let leftCount = groups.indices.contains(lhs) ? groups[lhs].members.count : Int.max
            let rightCount = groups.indices.contains(rhs) ? groups[rhs].members.count : Int.max
            if leftCount != rightCount {
                return leftCount < rightCount
            }
            return lhs < rhs
        }
    }

    private static func shouldUseVerticalGroupRoute(
        sourceRect: CGRect,
        targetRect: CGRect
    ) -> Bool {
        let horizontalOverlap = min(sourceRect.maxX, targetRect.maxX) - max(sourceRect.minX, targetRect.minX)
        let centerDX = abs(sourceRect.midX - targetRect.midX)
        let centerDY = abs(sourceRect.midY - targetRect.midY)
        return horizontalOverlap > min(sourceRect.width, targetRect.width) * 0.35
            && centerDY > centerDX * 1.35
    }

    private static func verticalGroupEdgeRoute(
        edge: CompoundGraph.CardEdge,
        order: Int,
        sourceRect: CGRect,
        targetRect: CGRect,
        groupRect: CGRect,
        graphRect: CGRect
    ) -> EdgeRoute {
        let groupIsLeftOfGraph = groupRect.midX <= graphRect.midX
        let side: EdgePortSide = groupIsLeftOfGraph ? .right : .left
        let downward = targetRect.midY >= sourceRect.midY
        let sourceAnchor = verticalGroupSideAnchor(
            rect: sourceRect,
            side: side,
            isSource: true,
            downward: downward
        )
        let targetAnchor = verticalGroupSideAnchor(
            rect: targetRect,
            side: side,
            isSource: false,
            downward: downward
        )
        let labelReserve = min(max(edgeLabelSize(edge).width * 0.5 + 18, 44), 104)
        let laneStep = CGFloat(order % 3) * LayoutSpacing.edgeEdge
        let laneDistance = labelReserve + laneStep
        let laneX = side == .right
            ? max(sourceRect.maxX, targetRect.maxX) + laneDistance
            : min(sourceRect.minX, targetRect.minX) - laneDistance
        let points = simplifyRoutePoints([
            sourceAnchor,
            CGPoint(x: laneX, y: sourceAnchor.y),
            CGPoint(x: laneX, y: targetAnchor.y),
            targetAnchor
        ])
        let midpoint = routePathMidpoint(points).point
        return EdgeRoute(
            start: sourceAnchor,
            end: targetAnchor,
            control: midpoint,
            isCurved: false,
            points: points
        )
    }

    private static func verticalGroupSideAnchor(
        rect: CGRect,
        side: EdgePortSide,
        isSource: Bool,
        downward: Bool
    ) -> CGPoint {
        let direction: CGFloat = downward == isSource ? 1 : -1
        let y = rect.midY + direction * min(rect.height * 0.26, 10)
        let x = side == .right ? rect.maxX : rect.minX
        return CGPoint(x: x, y: y)
    }

    private enum EdgePortSide: Hashable {
        case top
        case right
        case bottom
        case left
    }

    private struct EdgeEndpointKey: Hashable {
        let edgeID: EdgeIdentifier
        let isSource: Bool
    }

    private struct EdgePortBucket: Hashable {
        let cardIndex: Int
        let side: EdgePortSide
    }

    private struct EdgePortEntry {
        let edgeID: EdgeIdentifier
        let isSource: Bool
        let cardIndex: Int
        let side: EdgePortSide
        let order: CGFloat
    }

    private struct EdgePort {
        let point: CGPoint
        let side: EdgePortSide
        let bucketCount: Int
    }

    private struct OrthogonalRouteScore {
        let edgeConflict: Int
        let edgeClearance: CGFloat
        let length: CGFloat
        let corners: Int
        let portPreference: CGFloat

        func isBetter(than other: OrthogonalRouteScore) -> Bool {
            if abs(length - other.length) > 0.001 {
                return length < other.length
            }
            if corners != other.corners {
                return corners < other.corners
            }
            if edgeConflict != other.edgeConflict {
                return edgeConflict < other.edgeConflict
            }
            if abs(edgeClearance - other.edgeClearance) > 0.001 {
                return edgeClearance < other.edgeClearance
            }
            return portPreference < other.portPreference
        }
    }

    private static func edgePortAnchors(
        edges: [CompoundGraph.CardEdge],
        cards: [CompoundGraph.Card],
        indexByID: [CompoundGraph.Card.ID: Int],
        cardRects: [CGRect]
    ) -> [EdgeEndpointKey: EdgePort] {
        var buckets: [EdgePortBucket: [EdgePortEntry]] = [:]
        buckets.reserveCapacity(cards.count * 2)

        for edge in edges where edge.source != edge.target {
            guard
                let sourceIndex = indexByID[edge.source],
                let targetIndex = indexByID[edge.target]
            else { continue }

            let sourceRect = cardRects[sourceIndex]
            let targetRect = cardRects[targetIndex]
            let sourceCenter = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
            let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
            let sides = preferredPortSides(sourceRect: sourceRect, targetRect: targetRect)
            let sourceSide = sides.source
            let targetSide = sides.target

            let sourceEntry = EdgePortEntry(
                edgeID: edge.id,
                isSource: true,
                cardIndex: sourceIndex,
                side: sourceSide,
                order: portOrder(side: sourceSide, neighborCenter: targetCenter)
            )
            let targetEntry = EdgePortEntry(
                edgeID: edge.id,
                isSource: false,
                cardIndex: targetIndex,
                side: targetSide,
                order: portOrder(side: targetSide, neighborCenter: sourceCenter)
            )
            buckets[
                EdgePortBucket(cardIndex: sourceIndex, side: sourceSide),
                default: []
            ].append(sourceEntry)
            buckets[
                EdgePortBucket(cardIndex: targetIndex, side: targetSide),
                default: []
            ].append(targetEntry)
        }

        var anchors: [EdgeEndpointKey: EdgePort] = [:]
        anchors.reserveCapacity(edges.count * 2)
        for (bucket, entries) in buckets {
            let rect = cardRects[bucket.cardIndex]
            let sorted = entries.sorted { lhs, rhs in
                if lhs.order == rhs.order {
                    return edgeSortKey(lhs.edgeID) < edgeSortKey(rhs.edgeID)
                }
                return lhs.order < rhs.order
            }
            for (index, entry) in sorted.enumerated() {
                let point = portPoint(
                    side: bucket.side,
                    rect: rect,
                    index: index,
                    count: sorted.count
                )
                anchors[EdgeEndpointKey(edgeID: entry.edgeID, isSource: entry.isSource)] = EdgePort(
                    point: point,
                    side: bucket.side,
                    bucketCount: sorted.count
                )
            }
        }
        return anchors
    }

    private static func preferredPortSides(
        sourceRect: CGRect,
        targetRect: CGRect
    ) -> (source: EdgePortSide, target: EdgePortSide) {
        if sourceRect.maxX <= targetRect.minX {
            return (.right, .left)
        }
        if targetRect.maxX <= sourceRect.minX {
            return (.left, .right)
        }
        if sourceRect.maxY <= targetRect.minY {
            return (.bottom, .top)
        }
        if targetRect.maxY <= sourceRect.minY {
            return (.top, .bottom)
        }
        let sourceCenter = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
        let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
        return (
            portSide(from: sourceCenter, toward: targetCenter),
            portSide(from: targetCenter, toward: sourceCenter)
        )
    }

    private static func fallbackEdgePort(rect: CGRect, toward target: CGPoint) -> EdgePort {
        let side = portSide(
            from: CGPoint(x: rect.midX, y: rect.midY),
            toward: target
        )
        let point = portPoint(side: side, rect: rect, index: 0, count: 1)
        return EdgePort(point: point, side: side, bucketCount: 1)
    }

    private static func portSide(from center: CGPoint, toward target: CGPoint) -> EdgePortSide {
        let dx = target.x - center.x
        let dy = target.y - center.y
        if abs(dx) >= abs(dy) {
            return dx >= 0 ? .right : .left
        }
        return dy >= 0 ? .bottom : .top
    }

    private static func portOrder(side: EdgePortSide, neighborCenter: CGPoint) -> CGFloat {
        switch side {
        case .top, .bottom:
            return neighborCenter.x
        case .left, .right:
            return neighborCenter.y
        }
    }

    private static func portPoint(
        side: EdgePortSide,
        rect: CGRect,
        index: Int,
        count: Int
    ) -> CGPoint {
        let safeCount = max(count, 1)
        let clampedIndex = min(max(index, 0), safeCount - 1)
        let availableLength = portAvailableLength(side: side, rect: rect)
        let step: CGFloat
        if safeCount <= 1 {
            step = 0
        } else {
            let desiredSpan = LayoutSpacing.edgeEdge * CGFloat(safeCount - 1)
            step = desiredSpan <= availableLength
                ? LayoutSpacing.edgeEdge
                : availableLength / CGFloat(safeCount - 1)
        }
        let offset = (CGFloat(clampedIndex) - CGFloat(safeCount - 1) / 2) * step
        switch side {
        case .top:
            return CGPoint(
                x: clampPortCoordinate(rect.midX + offset, min: rect.minX, max: rect.maxX),
                y: rect.minY
            )
        case .right:
            return CGPoint(
                x: rect.maxX,
                y: clampPortCoordinate(rect.midY + offset, min: rect.minY, max: rect.maxY)
            )
        case .bottom:
            return CGPoint(
                x: clampPortCoordinate(rect.midX + offset, min: rect.minX, max: rect.maxX),
                y: rect.maxY
            )
        case .left:
            return CGPoint(
                x: rect.minX,
                y: clampPortCoordinate(rect.midY + offset, min: rect.minY, max: rect.maxY)
            )
        }
    }

    private static func portAvailableLength(side: EdgePortSide, rect: CGRect) -> CGFloat {
        let rawLength: CGFloat
        switch side {
        case .top, .bottom:
            rawLength = rect.width
        case .left, .right:
            rawLength = rect.height
        }
        let guardDistance = min(LayoutSpacing.portCornerGuard, max(rawLength / 2, 0))
        return max(rawLength - guardDistance * 2, 0)
    }

    private static func clampPortCoordinate(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        let rawLength = max - min
        let guardDistance = Swift.min(LayoutSpacing.portCornerGuard, Swift.max(rawLength / 2, 0))
        return Swift.min(max - guardDistance, Swift.max(min + guardDistance, value))
    }

    private static func edgePortCandidates(
        rect: CGRect,
        otherRect: CGRect,
        preferred: EdgePort,
        parallelIndex: Int,
        parallelCount: Int
    ) -> [EdgePort] {
        _ = otherRect
        _ = parallelIndex
        _ = parallelCount
        var candidates: [EdgePort] = []
        var seen: Set<String> = []

        func append(_ port: EdgePort) {
            let key = "\(port.side):\(Int(port.point.x.rounded())):\(Int(port.point.y.rounded()))"
            guard seen.insert(key).inserted else { return }
            candidates.append(port)
        }

        append(preferred)
        for side in allPortSides {
            append(EdgePort(
                point: portPoint(side: side, rect: rect, index: 0, count: 1),
                side: side,
                bucketCount: 1
            ))
        }
        return candidates
    }

    private static var allPortSides: [EdgePortSide] {
        [.right, .bottom, .left, .top]
    }

    private static func portNormal(_ side: EdgePortSide) -> CGVector {
        switch side {
        case .top:
            return CGVector(dx: 0, dy: -1)
        case .right:
            return CGVector(dx: 1, dy: 0)
        case .bottom:
            return CGVector(dx: 0, dy: 1)
        case .left:
            return CGVector(dx: -1, dy: 0)
        }
    }

    private static func vectorFollowsNormal(_ vector: CGVector, side: EdgePortSide) -> Bool {
        let normal = portNormal(side)
        let cross = abs(vector.dx * normal.dy - vector.dy * normal.dx)
        let dot = vector.dx * normal.dx + vector.dy * normal.dy
        return cross < 0.5 && dot > 0
    }

    private struct RoutePathSample {
        let point: CGPoint
        let tangent: CGVector
    }

    private static func orthogonalEdgePoints(
        edge: CompoundGraph.CardEdge,
        sourceRect: CGRect,
        targetRect: CGRect,
        preferredSourcePort: EdgePort,
        preferredTargetPort: EdgePort,
        sourceIndex: Int,
        targetIndex: Int,
        cardRects: [CGRect],
        routedEdges: [RoutedEdge],
        currentEdge: CompoundGraph.CardEdge
    ) -> [CGPoint] {
        let centeredParallel = edge.parallelCount > 1
            ? CGFloat(edge.parallelIndex) - CGFloat(edge.parallelCount - 1) / 2
            : 0
        let laneOffset = centeredParallel * LayoutSpacing.edgeEdge
        let excluded = Set([sourceIndex, targetIndex])
        let sourcePorts = edgePortCandidates(
            rect: sourceRect,
            otherRect: targetRect,
            preferred: preferredSourcePort,
            parallelIndex: edge.parallelIndex,
            parallelCount: edge.parallelCount
        )
        let targetPorts = edgePortCandidates(
            rect: targetRect,
            otherRect: sourceRect,
            preferred: preferredTargetPort,
            parallelIndex: edge.parallelIndex,
            parallelCount: edge.parallelCount
        )
        var best: [CGPoint]?
        var bestScore: OrthogonalRouteScore?
        for sourcePort in sourcePorts {
            for targetPort in targetPorts {
                let candidates = orthogonalRouteCandidates(
                    sourcePort: sourcePort,
                    targetPort: targetPort,
                    laneOffset: laneOffset,
                    cardRects: cardRects,
                    excludedIndices: excluded
                )
                for candidate in candidates {
                    let points = simplifyRoutePoints(candidate)
                    guard points.count > 1 else { continue }
                    guard routeIsOrthogonal(points) else { continue }
                    guard routeUsesPerpendicularPorts(
                        points,
                        sourcePort: sourcePort,
                        targetPort: targetPort
                    ) else { continue }
                    guard routeClearsNodes(
                        points,
                        cardRects: cardRects,
                        excluding: excluded
                    ) else { continue }

                    let edgeClearance = edgeRouteClearanceScore(
                        points,
                        currentEdge: currentEdge,
                        routedEdges: routedEdges
                    )
                    let score = OrthogonalRouteScore(
                        edgeConflict: edgeClearance == 0 ? 0 : 1,
                        edgeClearance: edgeClearance,
                        length: routeLength(points),
                        corners: routeCornerCount(points),
                        portPreference: hypot(
                            sourcePort.point.x - preferredSourcePort.point.x,
                            sourcePort.point.y - preferredSourcePort.point.y
                        ) + hypot(
                            targetPort.point.x - preferredTargetPort.point.x,
                            targetPort.point.y - preferredTargetPort.point.y
                        )
                    )
                    if bestScore.map({ score.isBetter(than: $0) }) ?? true {
                        bestScore = score
                        best = points
                    }
                }
            }
        }
        return best ?? [
            preferredSourcePort.point,
            preferredTargetPort.point
        ]
    }

    private static func shortestFixedEndpointRoute(
        edge: CompoundGraph.CardEdge,
        sourcePort: EdgePort,
        targetPort: EdgePort,
        laneOffset: CGFloat,
        sourceIndex: Int,
        targetIndex: Int,
        cardRects: [CGRect],
        routedEdges: [RoutedEdge]
    ) -> [CGPoint]? {
        let excluded = Set([sourceIndex, targetIndex])
        let candidates = orthogonalRouteCandidates(
            sourcePort: sourcePort,
            targetPort: targetPort,
            laneOffset: laneOffset,
            cardRects: cardRects,
            excludedIndices: excluded
        )
        var best: [CGPoint]?
        var bestScore: OrthogonalRouteScore?
        for candidate in candidates {
            let points = simplifyRoutePoints(candidate)
            guard points.count > 1 else { continue }
            guard routeIsOrthogonal(points) else { continue }
            guard routeUsesPerpendicularPorts(points, sourcePort: sourcePort, targetPort: targetPort) else { continue }
            guard routeClearsNodes(points, cardRects: cardRects, excluding: excluded) else { continue }
            let edgeClearance = edgeRouteClearanceScore(
                points,
                currentEdge: edge,
                routedEdges: routedEdges
            )
            let score = OrthogonalRouteScore(
                edgeConflict: edgeClearance == 0 ? 0 : 1,
                edgeClearance: edgeClearance,
                length: routeLength(points),
                corners: routeCornerCount(points),
                portPreference: 0
            )
            if bestScore.map({ score.isBetter(than: $0) }) ?? true {
                bestScore = score
                best = points
            }
        }
        return best
    }

    private static func orthogonalRouteCandidates(
        sourcePort: EdgePort,
        targetPort: EdgePort,
        laneOffset: CGFloat,
        cardRects: [CGRect],
        excludedIndices: Set<Int>
    ) -> [[CGPoint]] {
        let laneMagnitude = abs(laneOffset)
        let stubDistances = uniqueCGFloatValues([
            0,
            laneMagnitude,
            LayoutSpacing.edgeNode + laneMagnitude
        ])
        let laneOffsets = uniqueCGFloatValues([
            laneOffset,
            0,
            -laneOffset,
            LayoutSpacing.edgeEdge,
            -LayoutSpacing.edgeEdge,
            LayoutSpacing.edgeEdge * 2,
            -LayoutSpacing.edgeEdge * 2,
            LayoutSpacing.edgeEdge * 3,
            -LayoutSpacing.edgeEdge * 3
        ])

        var candidates: [[CGPoint]] = []
        var seen: Set<String> = []
        for sourceDistance in stubDistances {
            for targetDistance in stubDistances {
                let sourceOut = offsetPoint(sourcePort.point, side: sourcePort.side, distance: sourceDistance)
                let targetOut = offsetPoint(targetPort.point, side: targetPort.side, distance: targetDistance)
                let dx = targetOut.x - sourceOut.x
                let dy = targetOut.y - sourceOut.y
                let horizontalFirst = abs(dx) >= abs(dy)

                for offset in laneOffsets {
                    appendRouteCandidate(
                        routeWithEndpointStubs(
                            sourcePoint: sourcePort.point,
                            sourceOut: sourceOut,
                            core: orthogonalCandidate(
                                start: sourceOut,
                                end: targetOut,
                                horizontalFirst: horizontalFirst,
                                laneOffset: offset
                            ),
                            targetOut: targetOut,
                            targetPoint: targetPort.point
                        ),
                        to: &candidates,
                        seen: &seen
                    )
                    appendRouteCandidate(
                        routeWithEndpointStubs(
                            sourcePoint: sourcePort.point,
                            sourceOut: sourceOut,
                            core: orthogonalCandidate(
                                start: sourceOut,
                                end: targetOut,
                                horizontalFirst: !horizontalFirst,
                                laneOffset: offset == 0 ? 0 : -offset
                            ),
                            targetOut: targetOut,
                            targetPoint: targetPort.point
                        ),
                        to: &candidates,
                        seen: &seen
                    )
                }

                appendRouteCandidate(
                    routeWithEndpointStubs(
                        sourcePoint: sourcePort.point,
                        sourceOut: sourceOut,
                        core: [
                            sourceOut,
                            CGPoint(x: targetOut.x, y: sourceOut.y),
                            targetOut
                        ],
                        targetOut: targetOut,
                        targetPoint: targetPort.point
                    ),
                    to: &candidates,
                    seen: &seen
                )
                appendRouteCandidate(
                    routeWithEndpointStubs(
                        sourcePoint: sourcePort.point,
                        sourceOut: sourceOut,
                        core: [
                            sourceOut,
                            CGPoint(x: sourceOut.x, y: targetOut.y),
                            targetOut
                        ],
                        targetOut: targetOut,
                        targetPoint: targetPort.point
                    ),
                    to: &candidates,
                    seen: &seen
                )

                if let obstacleAvoidingCore = obstacleAvoidingOrthogonalRoute(
                    start: sourceOut,
                    end: targetOut,
                    laneOffset: laneOffset,
                    cardRects: cardRects,
                    excludedIndices: excludedIndices
                ) {
                    appendRouteCandidate(
                        routeWithEndpointStubs(
                            sourcePoint: sourcePort.point,
                            sourceOut: sourceOut,
                            core: obstacleAvoidingCore,
                            targetOut: targetOut,
                            targetPoint: targetPort.point
                        ),
                        to: &candidates,
                        seen: &seen
                    )
                }
            }
        }
        return candidates
    }

    private enum RouteAxis: Hashable {
        case horizontal
        case vertical
    }

    private struct RouteSearchState: Hashable {
        let pointIndex: Int
        let axis: RouteAxis?
    }

    private struct RouteSearchCost {
        let length: CGFloat
        let corners: Int

        func adding(length addedLength: CGFloat, turns: Int) -> RouteSearchCost {
            RouteSearchCost(length: length + addedLength, corners: corners + turns)
        }

        func isBetter(than other: RouteSearchCost) -> Bool {
            if abs(length - other.length) > 0.001 {
                return length < other.length
            }
            return corners < other.corners
        }
    }

    private static func obstacleAvoidingOrthogonalRoute(
        start: CGPoint,
        end: CGPoint,
        laneOffset: CGFloat,
        cardRects: [CGRect],
        excludedIndices: Set<Int>
    ) -> [CGPoint]? {
        let obstacles = cardRects.enumerated().compactMap { index, rect -> CGRect? in
            guard !excludedIndices.contains(index) else { return nil }
            return rect.insetBy(dx: -LayoutSpacing.edgeNode, dy: -LayoutSpacing.edgeNode)
        }
        guard !obstacles.isEmpty else { return nil }

        let lanePadding = LayoutSpacing.edgeEdge + abs(laneOffset)
        var xValues: [CGFloat] = [
            start.x,
            end.x,
            (start.x + end.x) * 0.5 + laneOffset
        ]
        var yValues: [CGFloat] = [
            start.y,
            end.y,
            (start.y + end.y) * 0.5 + laneOffset
        ]
        for obstacle in obstacles {
            xValues.append(obstacle.minX - lanePadding)
            xValues.append(obstacle.maxX + lanePadding)
            yValues.append(obstacle.minY - lanePadding)
            yValues.append(obstacle.maxY + lanePadding)
        }
        xValues = sortedUniqueCGFloatValues(xValues)
        yValues = sortedUniqueCGFloatValues(yValues)
        guard
            let startX = xValues.firstIndex(where: { abs($0 - start.x) < 0.5 }),
            let startY = yValues.firstIndex(where: { abs($0 - start.y) < 0.5 }),
            let endX = xValues.firstIndex(where: { abs($0 - end.x) < 0.5 }),
            let endY = yValues.firstIndex(where: { abs($0 - end.y) < 0.5 })
        else { return nil }

        let width = xValues.count
        let height = yValues.count
        func pointIndex(x: Int, y: Int) -> Int {
            y * width + x
        }
        func gridPoint(_ index: Int) -> CGPoint {
            let x = index % width
            let y = index / width
            return CGPoint(x: xValues[x], y: yValues[y])
        }
        let startIndex = pointIndex(x: startX, y: startY)
        let endIndex = pointIndex(x: endX, y: endY)
        let startState = RouteSearchState(pointIndex: startIndex, axis: nil)
        var distances: [RouteSearchState: RouteSearchCost] = [
            startState: RouteSearchCost(length: 0, corners: 0)
        ]
        var previous: [RouteSearchState: RouteSearchState] = [:]
        var visited: Set<RouteSearchState> = []

        while true {
            guard let current = distances
                .filter({ !visited.contains($0.key) })
                .min(by: { $0.value.isBetter(than: $1.value) })?
                .key
            else { break }
            if current.pointIndex == endIndex {
                return reconstructRoute(
                    endingAt: current,
                    previous: previous,
                    pointForIndex: gridPoint
                )
            }
            visited.insert(current)
            guard let currentDistance = distances[current] else { continue }
            for (neighborIndex, axis) in orthogonalGridNeighbors(
                pointIndex: current.pointIndex,
                width: width,
                height: height
            ) {
                let currentPoint = gridPoint(current.pointIndex)
                let neighborPoint = gridPoint(neighborIndex)
                guard segmentClearsObstacles(currentPoint, neighborPoint, obstacles: obstacles) else {
                    continue
                }
                let turns = current.axis == nil || current.axis == axis ? 0 : 1
                let stepLength = hypot(neighborPoint.x - currentPoint.x, neighborPoint.y - currentPoint.y)
                let neighborState = RouteSearchState(pointIndex: neighborIndex, axis: axis)
                let nextCost = currentDistance.adding(length: stepLength, turns: turns)
                if distances[neighborState].map({ nextCost.isBetter(than: $0) }) ?? true {
                    distances[neighborState] = nextCost
                    previous[neighborState] = current
                }
            }
        }
        return nil
    }

    private static func sortedUniqueCGFloatValues(_ values: [CGFloat]) -> [CGFloat] {
        uniqueCGFloatValues(values).sorted()
    }

    private static func orthogonalGridNeighbors(
        pointIndex: Int,
        width: Int,
        height: Int
    ) -> [(Int, RouteAxis)] {
        let x = pointIndex % width
        let y = pointIndex / width
        var neighbors: [(Int, RouteAxis)] = []
        if x > 0 {
            neighbors.append((y * width + x - 1, .horizontal))
        }
        if x + 1 < width {
            neighbors.append((y * width + x + 1, .horizontal))
        }
        if y > 0 {
            neighbors.append(((y - 1) * width + x, .vertical))
        }
        if y + 1 < height {
            neighbors.append(((y + 1) * width + x, .vertical))
        }
        return neighbors
    }

    private static func reconstructRoute(
        endingAt end: RouteSearchState,
        previous: [RouteSearchState: RouteSearchState],
        pointForIndex: (Int) -> CGPoint
    ) -> [CGPoint] {
        var states: [RouteSearchState] = [end]
        var current = end
        while let prior = previous[current] {
            states.append(prior)
            current = prior
        }
        return simplifyRoutePoints(states.reversed().map { pointForIndex($0.pointIndex) })
    }

    private static func segmentClearsObstacles(
        _ start: CGPoint,
        _ end: CGPoint,
        obstacles: [CGRect]
    ) -> Bool {
        for obstacle in obstacles {
            if segmentIntersectsRect(start, end, obstacle) {
                return false
            }
        }
        return true
    }

    private static func uniqueCGFloatValues(_ values: [CGFloat]) -> [CGFloat] {
        var result: [CGFloat] = []
        for value in values {
            if !result.contains(where: { abs($0 - value) < 0.5 }) {
                result.append(value)
            }
        }
        return result
    }

    private static func appendRouteCandidate(
        _ points: [CGPoint],
        to candidates: inout [[CGPoint]],
        seen: inout Set<String>
    ) {
        let simplified = simplifyRoutePoints(points)
        let key = simplified
            .map { "\(Int($0.x.rounded())):\(Int($0.y.rounded()))" }
            .joined(separator: "|")
        guard seen.insert(key).inserted else { return }
        candidates.append(simplified)
    }

    private static func routeIsOrthogonal(_ points: [CGPoint]) -> Bool {
        let simplified = simplifyRoutePoints(points)
        guard simplified.count > 1 else { return false }
        for offset in 1..<simplified.count {
            let previous = simplified[offset - 1]
            let current = simplified[offset]
            let sameX = abs(previous.x - current.x) < 0.5
            let sameY = abs(previous.y - current.y) < 0.5
            if !sameX && !sameY {
                return false
            }
        }
        return true
    }

    private static func routeCornerCount(_ points: [CGPoint]) -> Int {
        let simplified = simplifyRoutePoints(points)
        guard simplified.count > 2 else { return 0 }
        var count = 0
        for index in 1..<(simplified.count - 1) {
            let previous = simplified[index - 1]
            let current = simplified[index]
            let next = simplified[index + 1]
            let enteringHorizontal = abs(previous.y - current.y) < 0.5
            let leavingHorizontal = abs(current.y - next.y) < 0.5
            if enteringHorizontal != leavingHorizontal {
                count += 1
            }
        }
        return count
    }

    private static func routeLength(_ points: [CGPoint]) -> CGFloat {
        let simplified = simplifyRoutePoints(points)
        guard simplified.count > 1 else { return 0 }
        var length: CGFloat = 0
        for offset in 1..<simplified.count {
            length += hypot(
                simplified[offset].x - simplified[offset - 1].x,
                simplified[offset].y - simplified[offset - 1].y
            )
        }
        return length
    }

    private static func offsetPoint(
        _ point: CGPoint,
        side: EdgePortSide,
        distance: CGFloat
    ) -> CGPoint {
        let normal = portNormal(side)
        return CGPoint(
            x: point.x + normal.dx * distance,
            y: point.y + normal.dy * distance
        )
    }

    private static func routeWithEndpointStubs(
        sourcePoint: CGPoint,
        sourceOut: CGPoint,
        core: [CGPoint],
        targetOut: CGPoint,
        targetPoint: CGPoint
    ) -> [CGPoint] {
        var points: [CGPoint] = [sourcePoint, sourceOut]
        points.append(contentsOf: core.dropFirst().dropLast())
        points.append(targetOut)
        points.append(targetPoint)
        return simplifyRoutePoints(points)
    }

    private static func routeUsesPerpendicularPorts(
        _ points: [CGPoint],
        sourcePort: EdgePort,
        targetPort: EdgePort
    ) -> Bool {
        let simplified = simplifyRoutePoints(points)
        guard simplified.count > 1 else { return false }
        let sourceVector = CGVector(
            dx: simplified[1].x - simplified[0].x,
            dy: simplified[1].y - simplified[0].y
        )
        let targetVector = CGVector(
            dx: simplified[simplified.count - 2].x - simplified[simplified.count - 1].x,
            dy: simplified[simplified.count - 2].y - simplified[simplified.count - 1].y
        )
        return vectorFollowsNormal(sourceVector, side: sourcePort.side)
            && vectorFollowsNormal(targetVector, side: targetPort.side)
    }

    private static func orthogonalCandidate(
        start: CGPoint,
        end: CGPoint,
        horizontalFirst: Bool,
        laneOffset: CGFloat
    ) -> [CGPoint] {
        if horizontalFirst {
            let midX = (start.x + end.x) * 0.5 + laneOffset
            return [
                start,
                CGPoint(x: midX, y: start.y),
                CGPoint(x: midX, y: end.y),
                end
            ]
        } else {
            let midY = (start.y + end.y) * 0.5 + laneOffset
            return [
                start,
                CGPoint(x: start.x, y: midY),
                CGPoint(x: end.x, y: midY),
                end
            ]
        }
    }

    private static func simplifyRoutePoints(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        for point in points {
            if let last = result.last, hypot(point.x - last.x, point.y - last.y) < 0.5 {
                continue
            }
            if result.count >= 2 {
                let previous = result[result.count - 2]
                let current = result[result.count - 1]
                let sameVertical = abs(previous.x - current.x) < 0.5 && abs(current.x - point.x) < 0.5
                let sameHorizontal = abs(previous.y - current.y) < 0.5 && abs(current.y - point.y) < 0.5
                if sameVertical || sameHorizontal {
                    result[result.count - 1] = point
                    continue
                }
            }
            result.append(point)
        }
        return result
    }

    private static func routeClearsNodes(
        _ points: [CGPoint],
        cardRects: [CGRect],
        excluding excludedIndices: Set<Int>
    ) -> Bool {
        guard points.count > 1 else { return true }
        for offset in 1..<points.count {
            let start = points[offset - 1]
            let end = points[offset]
            for (index, rect) in cardRects.enumerated() where !excludedIndices.contains(index) {
                if segmentIntersectsRect(
                    start,
                    end,
                    rect.insetBy(dx: -LayoutSpacing.edgeNode, dy: -LayoutSpacing.edgeNode)
                ) {
                    return false
                }
            }
        }
        return true
    }

    private static func routeClearsExistingEdges(
        _ points: [CGPoint],
        currentEdge: CompoundGraph.CardEdge,
        routedEdges: [RoutedEdge]
    ) -> Bool {
        edgeRouteClearanceScore(
            points,
            currentEdge: currentEdge,
            routedEdges: routedEdges
        ) == 0
    }

    private static func edgeRouteClearanceScore(
        _ points: [CGPoint],
        currentEdge: CompoundGraph.CardEdge,
        routedEdges: [RoutedEdge]
    ) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var score: CGFloat = 0
        for routedEdge in routedEdges {
            let otherPoints = routedEdge.points
            guard otherPoints.count > 1 else { continue }
            let sharedEndpoints = sharedEndpoints(currentEdge, routedEdge.edge)
            let currentSharedPoints = sharedEndpointPoints(
                edge: currentEdge,
                points: points,
                sharedEndpoints: sharedEndpoints
            )
            let otherSharedPoints = sharedEndpointPoints(
                edge: routedEdge.edge,
                points: otherPoints,
                sharedEndpoints: sharedEndpoints
            )
            for currentOffset in 1..<points.count {
                let currentStart = points[currentOffset - 1]
                let currentEnd = points[currentOffset]
                guard let currentSegment = edgeClearanceSegment(
                    start: currentStart,
                    end: currentEnd,
                    sharedEndpointPoints: currentSharedPoints
                ) else { continue }
                for otherOffset in 1..<otherPoints.count {
                    let otherStart = otherPoints[otherOffset - 1]
                    let otherEnd = otherPoints[otherOffset]
                    guard let otherSegment = edgeClearanceSegment(
                        start: otherStart,
                        end: otherEnd,
                        sharedEndpointPoints: otherSharedPoints
                    ) else { continue }
                    let distance = segmentDistance(
                        currentSegment.start,
                        currentSegment.end,
                        otherSegment.start,
                        otherSegment.end
                    )
                    if !sharedEndpoints.isEmpty && distance >= 0.5 {
                        continue
                    }
                    guard distance < LayoutSpacing.edgeEdge else { continue }
                    score += (LayoutSpacing.edgeEdge - distance) * 120
                    if distance < 0.5 {
                        score += 10_000
                    }
                }
            }
        }
        return score
    }

    private static func sharedEndpoints(
        _ lhs: CompoundGraph.CardEdge,
        _ rhs: CompoundGraph.CardEdge
    ) -> Set<CompoundGraph.Card.ID> {
        Set([lhs.source, lhs.target]).intersection(Set([rhs.source, rhs.target]))
    }

    private static func sharedEndpointPoints(
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

    private static func edgeClearanceSegment(
        start: CGPoint,
        end: CGPoint,
        sharedEndpointPoints: [CGPoint]
    ) -> (start: CGPoint, end: CGPoint)? {
        var trimmedStart = start
        var trimmedEnd = end
        for endpoint in sharedEndpointPoints {
            if pointsAreClose(trimmedStart, endpoint) {
                trimmedStart = pointAlongSegment(
                    from: trimmedStart,
                    to: trimmedEnd,
                    distance: LayoutSpacing.edgeEdge
                )
            }
            if pointsAreClose(trimmedEnd, endpoint) {
                trimmedEnd = pointAlongSegment(
                    from: trimmedEnd,
                    to: trimmedStart,
                    distance: LayoutSpacing.edgeEdge
                )
            }
        }
        guard hypot(trimmedEnd.x - trimmedStart.x, trimmedEnd.y - trimmedStart.y) > 0.5 else {
            return nil
        }
        return (trimmedStart, trimmedEnd)
    }

    private static func pointAlongSegment(
        from start: CGPoint,
        to end: CGPoint,
        distance: CGFloat
    ) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return start }
        let clampedDistance = min(distance, length)
        return CGPoint(
            x: start.x + dx / length * clampedDistance,
            y: start.y + dy / length * clampedDistance
        )
    }

    private static func pointsAreClose(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y) < 0.5
    }

    private static func segmentDistance(
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

    private static func pointSegmentDistance(
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

    private static func routePathSample(_ points: [CGPoint], fraction: CGFloat) -> RoutePathSample {
        guard let first = points.first else {
            return RoutePathSample(point: .zero, tangent: CGVector(dx: 1, dy: 0))
        }
        guard points.count > 1 else {
            return RoutePathSample(point: first, tangent: CGVector(dx: 1, dy: 0))
        }

        var totalLength: CGFloat = 0
        for offset in 1..<points.count {
            totalLength += hypot(
                points[offset].x - points[offset - 1].x,
                points[offset].y - points[offset - 1].y
            )
        }
        let clampedFraction = min(1, max(0, fraction))
        let target = totalLength * clampedFraction
        var accumulated: CGFloat = 0
        for offset in 1..<points.count {
            let start = points[offset - 1]
            let end = points[offset]
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0.001 else { continue }
            if accumulated + length >= target {
                let t = (target - accumulated) / length
                return RoutePathSample(
                    point: CGPoint(
                        x: start.x + (end.x - start.x) * t,
                        y: start.y + (end.y - start.y) * t
                    ),
                    tangent: CGVector(dx: end.x - start.x, dy: end.y - start.y)
                )
            }
            accumulated += length
        }
        let previous = points[points.count - 2]
        let last = points[points.count - 1]
        return RoutePathSample(
            point: last,
            tangent: CGVector(dx: last.x - previous.x, dy: last.y - previous.y)
        )
    }

    private static func routePathMidpoint(_ points: [CGPoint]) -> RoutePathSample {
        routePathSample(points, fraction: 0.5)
    }

    private static func segmentIntersectsRect(
        _ start: CGPoint,
        _ end: CGPoint,
        _ rect: CGRect
    ) -> Bool {
        if rect.contains(start) || rect.contains(end) { return true }
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
        return segmentsIntersect(start, end, topLeft, topRight)
            || segmentsIntersect(start, end, topRight, bottomRight)
            || segmentsIntersect(start, end, bottomRight, bottomLeft)
            || segmentsIntersect(start, end, bottomLeft, topLeft)
    }

    private static func segmentsIntersect(
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

    private static func edgeSortKey(_ id: EdgeIdentifier) -> String {
        "\(id.source.kind):\(id.source.key)|\(id.predicate)|\(id.target.kind):\(id.target.key)|\(id.namedGraph ?? "")"
    }

    /// Self-loop: emit an orthogonal loop from the top edge back to the top
    /// edge. The parallel index moves successive loops higher so they do not
    /// stack.
    private static func selfLoopRoute(
        center: CGPoint,
        size: CGSize,
        parallelIndex: Int
    ) -> EdgeRoute {
        let yOffset = CGFloat(parallelIndex) * LayoutSpacing.edgeEdge
        let topY = center.y - size.height / 2
        let xOffset = min(size.width * 0.28, 24)
        let start = CGPoint(x: center.x - xOffset, y: topY)
        let end = CGPoint(x: center.x + xOffset, y: topY)
        let laneY = topY - 42 - yOffset
        let points = simplifyRoutePoints([
            start,
            CGPoint(x: start.x, y: laneY),
            CGPoint(x: end.x, y: laneY),
            end
        ])
        let midpoint = routePathMidpoint(points).point
        return EdgeRoute(
            start: start,
            end: end,
            control: midpoint,
            isCurved: false,
            points: points
        )
    }

    // MARK: - Edge labels

    private struct EdgeLabelPlacementScore {
        let cardCollision: CGFloat
        let labelCollision: CGFloat
        let cardMarginCollision: CGFloat
        let routeCollision: CGFloat
        let sampleIndex: Int

        func isBetter(than other: EdgeLabelPlacementScore) -> Bool {
            if abs(cardCollision - other.cardCollision) > 0.001 {
                return cardCollision < other.cardCollision
            }
            if abs(labelCollision - other.labelCollision) > 0.001 {
                return labelCollision < other.labelCollision
            }
            if abs(cardMarginCollision - other.cardMarginCollision) > 0.001 {
                return cardMarginCollision < other.cardMarginCollision
            }
            if abs(routeCollision - other.routeCollision) > 0.001 {
                return routeCollision < other.routeCollision
            }
            return sampleIndex < other.sampleIndex
        }
    }

    private struct EdgeLabelCollisionMetrics {
        var card: CGFloat = 0
        var cardMargin: CGFloat = 0
        var label: CGFloat = 0
        var route: CGFloat = 0
    }

    private struct EdgeLabelCandidateSet {
        let edge: CompoundGraph.CardEdge
        let size: CGSize
        let samples: [RoutePathSample]
    }

    private struct EdgeRouteSegment {
        let start: CGPoint
        let end: CGPoint
    }

    /// Place each edge label on the rendered route itself. Collision handling
    /// may only choose another point along the route; it must never move the
    /// label centre perpendicular to the edge.
    private static func placeEdgeLabels(
        edges: [CompoundGraph.CardEdge],
        routes: [EdgeIdentifier: EdgeRoute],
        cardRects: [CGRect]
    ) -> [EdgeIdentifier: CGPoint] {
        let placementEdges = edges.sorted { lhs, rhs in
            let leftSize = edgeLabelSize(lhs)
            let rightSize = edgeLabelSize(rhs)
            if abs(leftSize.width - rightSize.width) > 0.5 {
                return leftSize.width > rightSize.width
            }
            return edgeSortKey(lhs.id) < edgeSortKey(rhs.id)
        }
        let candidateSets = placementEdges.compactMap { edge -> EdgeLabelCandidateSet? in
            guard let route = routes[edge.id] else { return nil }
            let size = edgeLabelSize(edge)
            let samples = edgeLabelAnchorSamples(route, labelSize: size)
            return EdgeLabelCandidateSet(
                edge: edge,
                size: size,
                samples: samples
            )
        }

        var placed: [EdgeIdentifier: CGPoint] = [:]
        placed.reserveCapacity(candidateSets.count)
        for candidateSet in candidateSets {
            placed[candidateSet.edge.id] = candidateSet.samples.first?.point ?? .zero
        }

        for _ in 0..<4 {
            for candidateSet in candidateSets {
                let occupiedLabelRects = candidateSets.compactMap { otherSet -> CGRect? in
                    guard
                        otherSet.edge.id != candidateSet.edge.id,
                        let center = placed[otherSet.edge.id]
                    else { return nil }
                    return edgeLabelRect(center: center, size: otherSet.size).insetBy(
                        dx: -LayoutSpacing.edgeLabelLabel,
                        dy: -LayoutSpacing.edgeLabelLabel
                    )
                }
                placed[candidateSet.edge.id] = bestEdgeLabelPosition(
                    samples: candidateSet.samples,
                    size: candidateSet.size,
                    cardRects: cardRects,
                    occupiedLabelRects: occupiedLabelRects,
                    blockingRouteSegments: edgeLabelBlockingRouteSegments(
                        routes: routes,
                        excluding: candidateSet.edge.id
                    )
                )
            }
        }
        return placed
    }

    private static func bestEdgeLabelPosition(
        samples: [RoutePathSample],
        size: CGSize,
        cardRects: [CGRect],
        occupiedLabelRects: [CGRect],
        blockingRouteSegments: [EdgeRouteSegment]
    ) -> CGPoint {
        let fallback = samples.first?.point ?? .zero
        var chosen = fallback
        var chosenScore: EdgeLabelPlacementScore?
        for (sampleIndex, sample) in samples.enumerated() {
            let candidate = sample.point
            let rect = edgeLabelRect(center: candidate, size: size)
            let collision = edgeLabelCollisionMetrics(
                rect,
                cardRects: cardRects,
                occupiedLabelRects: occupiedLabelRects,
                blockingRouteSegments: blockingRouteSegments
            )
            let placementScore = EdgeLabelPlacementScore(
                cardCollision: collision.card,
                labelCollision: collision.label,
                cardMarginCollision: collision.cardMargin,
                routeCollision: collision.route,
                sampleIndex: sampleIndex
            )
            if chosenScore.map({ placementScore.isBetter(than: $0) }) ?? true {
                chosen = candidate
                chosenScore = placementScore
            }
        }
        return chosen
    }

    private static func edgeLabelBlockingRouteSegments(
        routes: [EdgeIdentifier: EdgeRoute],
        excluding excludedID: EdgeIdentifier
    ) -> [EdgeRouteSegment] {
        var segments: [EdgeRouteSegment] = []
        for (edgeID, route) in routes where edgeID != excludedID {
            let points = route.points.isEmpty ? [route.start, route.end] : route.points
            guard points.count > 1 else { continue }
            for offset in 1..<points.count {
                segments.append(EdgeRouteSegment(
                    start: points[offset - 1],
                    end: points[offset]
                ))
            }
        }
        return segments
    }

    private static func edgeLabelAnchorSamples(_ route: EdgeRoute, labelSize: CGSize) -> [RoutePathSample] {
        let fractions: [CGFloat] = [
            0.38, 0.62,
            0.30, 0.70,
            0.50,
            0.24, 0.76,
            0.44, 0.56,
            0.18, 0.82,
            0.12, 0.88,
            0.33, 0.67,
            0.27, 0.73,
            0.06, 0.94,
            0.03, 0.97,
            0.48, 0.52,
            0.01, 0.99
        ]
        if route.isCurved {
            return fractions.map { curvedRouteSample(route, fraction: $0) }
        }
        let points = route.points.isEmpty ? [route.start, route.end] : route.points
        if points.count >= 4 {
            return edgeLabelSecondSegmentSamples(points, labelSize: labelSize)
        }
        var samples = fractions.map { routePathSample(points, fraction: $0) }
        samples.append(contentsOf: edgeLabelSegmentSamples(points, labelSize: labelSize))
        return samples
    }

    private static func edgeLabelSecondSegmentSamples(
        _ points: [CGPoint],
        labelSize: CGSize
    ) -> [RoutePathSample] {
        guard points.count >= 3 else { return [] }
        let start = points[1]
        let end = points[2]
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else {
            return [routeSegmentSample(start: start, end: end, fraction: 0.5)]
        }

        return edgeLabelSamplesOnSegment(start: start, end: end, labelSize: labelSize)
    }

    private static func edgeLabelSegmentSamples(_ points: [CGPoint], labelSize: CGSize) -> [RoutePathSample] {
        guard points.count > 1 else { return [] }
        var samples: [RoutePathSample] = []
        samples.reserveCapacity((points.count - 1) * 8)
        for offset in 1..<points.count {
            let start = points[offset - 1]
            let end = points[offset]
            samples.append(contentsOf: edgeLabelSamplesOnSegment(
                start: start,
                end: end,
                labelSize: labelSize
            ))
        }
        return samples
    }

    private static func edgeLabelSamplesOnSegment(
        start: CGPoint,
        end: CGPoint,
        labelSize: CGSize
    ) -> [RoutePathSample] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else {
            return [routeSegmentSample(start: start, end: end, fraction: 0.5)]
        }

        let axisLabelLength = abs(dx) >= abs(dy) ? labelSize.width : labelSize.height
        let endGuard = min(max(LayoutSpacing.edgeLabelLabel, 2), length * 0.5)
        let lower = endGuard / length
        let upper = 1 - lower
        let center = min(upper, max(lower, CGFloat(0.5)))
        var fractions: [CGFloat] = [center]
        let step = max(LayoutSpacing.edgeLabelLabel, min(axisLabelLength * 0.25, 10))
        var offset = step
        while offset <= length * 0.5 - endGuard + 0.5 {
            let delta = offset / length
            let left = center - delta
            let right = center + delta
            if left >= lower {
                fractions.append(left)
            }
            if right <= upper {
                fractions.append(right)
            }
            offset += step
        }
        if fractions.count == 1 {
            fractions.append(contentsOf: [lower, upper].filter { abs($0 - center) > 0.001 })
        }
        var uniqueFractions: [CGFloat] = []
        for fraction in fractions {
            guard !uniqueFractions.contains(where: { abs($0 - fraction) < 0.001 }) else {
                continue
            }
            uniqueFractions.append(fraction)
        }
        return uniqueFractions.map { fraction in
            routeSegmentSample(start: start, end: end, fraction: fraction)
        }
    }

    private static func routeSegmentSample(
        start: CGPoint,
        end: CGPoint,
        fraction: CGFloat
    ) -> RoutePathSample {
        let t = min(1, max(0, fraction))
        return RoutePathSample(
            point: CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            ),
            tangent: CGVector(dx: end.x - start.x, dy: end.y - start.y)
        )
    }

    private static func curvedRouteSample(_ route: EdgeRoute, fraction: CGFloat) -> RoutePathSample {
        let t = min(1, max(0, fraction))
        let inverseT = 1 - t
        let point = CGPoint(
            x: inverseT * inverseT * route.start.x
                + 2 * inverseT * t * route.control.x
                + t * t * route.end.x,
            y: inverseT * inverseT * route.start.y
                + 2 * inverseT * t * route.control.y
                + t * t * route.end.y
        )
        let tangent = CGVector(
            dx: 2 * inverseT * (route.control.x - route.start.x)
                + 2 * t * (route.end.x - route.control.x),
            dy: 2 * inverseT * (route.control.y - route.start.y)
                + 2 * t * (route.end.y - route.control.y)
        )
        return RoutePathSample(point: point, tangent: tangent)
    }

    private static func edgeLabelSize(_ edge: CompoundGraph.CardEdge) -> CGSize {
        CGSize(
            width: min(CGFloat(edge.predicate.count) * 7 + 20, 190),
            height: LayoutSpacing.labelHeight
        )
    }

    private static func edgeLabelRect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func edgeLabelCollisionMetrics(
        _ rect: CGRect,
        cardRects: [CGRect],
        occupiedLabelRects: [CGRect],
        blockingRouteSegments: [EdgeRouteSegment]
    ) -> EdgeLabelCollisionMetrics {
        var metrics = EdgeLabelCollisionMetrics()
        for card in cardRects {
            let cardIntersection = rect.intersection(card)
            if !cardIntersection.isNull {
                metrics.card += cardIntersection.width * cardIntersection.height
            }
            let marginIntersection = rect.intersection(card.insetBy(
                dx: -LayoutSpacing.edgeNode,
                dy: -LayoutSpacing.edgeNode
            ))
            if !marginIntersection.isNull {
                metrics.cardMargin += marginIntersection.width * marginIntersection.height
            }
        }
        for occupied in occupiedLabelRects {
            let intersection = rect.intersection(occupied)
            if !intersection.isNull {
                metrics.label += intersection.width * intersection.height
            }
        }
        let routeRect = rect.insetBy(
            dx: -LayoutSpacing.edgeEdge * 0.25,
            dy: -LayoutSpacing.edgeEdge * 0.25
        )
        for segment in blockingRouteSegments where segmentIntersectsRect(
            segment.start,
            segment.end,
            routeRect
        ) {
            metrics.route += rect.width * rect.height
        }
        return metrics
    }
}
