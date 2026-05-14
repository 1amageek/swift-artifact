import Foundation
import CoreGraphics
import KnowledgeGraph

/// Constraint-aware layout for a `KnowledgeGraph`.
///
/// The pipeline is:
///
/// 1. **Decomposition** — `CompoundGraph.decompose` folds every leaf literal
///    into its owning subject's card. Layout therefore operates on cards
///    rather than raw nodes, which eliminates the foaf:name "Alice" pattern
///    as an independent vertex.
///
/// 2. **All-pairs shortest path** (Floyd-Warshall) over the card adjacency.
///    `n < 200` so the O(n³) cost is in the milliseconds. Disconnected pairs
///    receive a finite fallback distance so the components stay on the same
///    canvas without unbounded repulsion.
///
/// 3. **Stress majorization** (Gansner–Koren–North, "Graph drawing by stress
///    majorization", 2004). For each iteration and each card `i` we move
///    `p_i` toward the weighted mean of the contributions
///        `p_j + δ_ij · (p_i − p_j) / ‖p_i − p_j‖`
///    with weight `w_ij = 1 / d_ij²`. The objective is the global stress
///    `Σ w_ij (‖p_i − p_j‖ − δ_ij)²` where `δ_ij` is the desired Euclidean
///    distance. We make `δ_ij` *size-aware* —
///        `δ_ij = radius(i) + radius(j) + gap · graphDistance(i, j)`
///    so larger cards get proportionally more room and adjacent cards
///    always end up with a fixed empty space between their boundaries.
///
/// 4. **Separation constraints**. After stress converges we run a fixed
///    number of overlap-removal passes: any pair whose padded rectangles
///    overlap is projected apart along the axis of smaller penetration.
///
/// 5. **Edge routing**. Each edge anchors on the boundary of its source and
///    target rectangles, biased perpendicularly for parallel edges. Bezier
///    control points are derived from the same perpendicular offset.
///
/// 6. **Edge label slotting**. Labels start at the curve midpoint and slide
///    perpendicular through a small ladder of offsets until they no longer
///    overlap any card rectangle.
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
        let canvasSize: CGSize
    }

    /// Pre-computed geometry for a single rendered edge.
    struct EdgeRoute: Sendable {
        let start: CGPoint
        let end: CGPoint
        /// Quadratic Bezier control point. Equal to the midpoint of
        /// `start → end` for straight edges.
        let control: CGPoint
        /// `true` when this edge is one of multiple parallel edges between
        /// the same pair of cards (or its sibling pair `(t, s)`) and needs a
        /// curved render.
        let isCurved: Bool
    }

    static let defaultIterations = 80
    /// Desired empty space between adjacent card boundaries, scaled by graph
    /// distance. The actual centre-to-centre target adds the two cards'
    /// bounding radii on top of this, so cards never overlap regardless of
    /// their individual sizes.
    static let defaultEdgeGap: Double = 140

    /// Compute the layout for `graph`.
    ///
    /// - Parameters:
    ///   - graph: The graph to lay out.
    ///   - iterations: Number of stress-majorization iterations. 80 is
    ///     sufficient for `n < 200`.
    ///   - initial: Warm-restart positions keyed by `NodeIdentifier`. Cards
    ///     whose underlying node has a warm-start position use it; newcomers
    ///     are seeded around the centroid of warm positions.
    static func compute(
        graph: KnowledgeGraph,
        iterations: Int = defaultIterations,
        initial: [NodeIdentifier: CGPoint] = [:]
    ) -> Result {
        let compound = CompoundGraph.decompose(graph)
        guard !compound.cards.isEmpty else {
            return Result(
                compoundGraph: compound,
                cardPositions: [:],
                edgeRoutes: [:],
                edgeLabelPositions: [:],
                canvasSize: CGSize(width: 420, height: 280)
            )
        }

        let indexByID = Dictionary(uniqueKeysWithValues:
            compound.cards.enumerated().map { ($0.element.id, $0.offset) }
        )
        let n = compound.cards.count

        // Step 2: all-pairs shortest path on the undirected adjacency.
        let distances = allPairsShortestPaths(
            cardCount: n,
            edges: compound.edges,
            indexByID: indexByID
        )

        // Estimate canvas size from the diameter so the layout has room to
        // breathe before stress majorization runs.
        let totalAttrArea = compound.cards.reduce(0.0) { acc, card in
            acc + Double(card.size.width * card.size.height)
        }
        let canvasSeed = max(520.0, sqrt(totalAttrArea) * 3.0)

        var positions = seedPositions(
            cards: compound.cards,
            initial: initial,
            canvasSeed: canvasSeed
        )

        // Size-aware ideal distance matrix. The target centre-to-centre
        // distance for cards `i` and `j` is the sum of their bounding radii
        // plus `defaultEdgeGap × graphDistance(i, j)`. This guarantees a
        // visible gap between card boundaries regardless of card size.
        let sizes = compound.cards.map { $0.size }
        let radii = sizes.map { Double(hypot($0.width, $0.height)) / 2.0 }
        let idealDistances = buildIdealDistances(
            graphDistances: distances,
            radii: radii,
            edgeGap: defaultEdgeGap
        )

        // Step 3: stress majorization with size-aware targets.
        stressMajorize(
            positions: &positions,
            distances: distances,
            idealDistances: idealDistances,
            iterations: iterations
        )

        // Step 4: separation constraints (card-vs-card non-overlap).
        resolveOverlaps(
            positions: &positions,
            sizes: sizes,
            margin: 48,
            iterations: 40
        )

        // Translate to a non-negative coordinate space and finalise canvas.
        let (cardPositions, canvasSize) = anchorAndCanvas(
            cards: compound.cards,
            centerPositions: positions,
            padding: 36
        )

        // Step 5 & 6: edge routes and label slotting.
        let routes = computeEdgeRoutes(
            edges: compound.edges,
            cards: compound.cards,
            indexByID: indexByID,
            cardPositions: cardPositions
        )
        let cardRects = compound.cards.map { card in
            CGRect(
                origin: cardPositions[card.id] ?? .zero,
                size: card.size
            )
        }
        let labels = placeEdgeLabels(
            edges: compound.edges,
            routes: routes,
            cardRects: cardRects
        )

        return Result(
            compoundGraph: compound,
            cardPositions: cardPositions,
            edgeRoutes: routes,
            edgeLabelPositions: labels,
            canvasSize: canvasSize
        )
    }

    // MARK: - Shortest paths

    private static func allPairsShortestPaths(
        cardCount n: Int,
        edges: [CompoundGraph.CardEdge],
        indexByID: [CompoundGraph.Card.ID: Int]
    ) -> [[Double]] {
        var dist = Array(
            repeating: Array(repeating: Double.infinity, count: n),
            count: n
        )
        for i in 0..<n { dist[i][i] = 0 }
        for edge in edges {
            guard let i = indexByID[edge.source], let j = indexByID[edge.target] else { continue }
            dist[i][j] = min(dist[i][j], 1)
            dist[j][i] = min(dist[j][i], 1)
        }
        // Floyd-Warshall.
        for k in 0..<n {
            for i in 0..<n where dist[i][k].isFinite {
                let dik = dist[i][k]
                for j in 0..<n where dist[k][j].isFinite {
                    let candidate = dik + dist[k][j]
                    if candidate < dist[i][j] {
                        dist[i][j] = candidate
                    }
                }
            }
        }
        // Disconnected components: replace ∞ with a finite fallback so the
        // stress optimiser produces a stable layout. The fallback equals the
        // current diameter + 2, which pushes components apart without
        // exploding.
        var diameter: Double = 1
        for i in 0..<n {
            for j in 0..<n where dist[i][j].isFinite {
                if dist[i][j] > diameter { diameter = dist[i][j] }
            }
        }
        let fallback = diameter + 2
        for i in 0..<n {
            for j in 0..<n where !dist[i][j].isFinite {
                dist[i][j] = fallback
            }
        }
        return dist
    }

    // MARK: - Seeding

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
        let ringRadius = canvasSeed / 4
        var newcomerCounter = 0
        let newcomerTotal = cards.filter { initial[$0.id.nodeID] == nil }.count

        var seeded: [CGPoint] = []
        seeded.reserveCapacity(cards.count)
        for card in cards {
            if let warm = initial[card.id.nodeID] {
                seeded.append(warm)
            } else {
                let angle = 2 * .pi * Double(newcomerCounter) / Double(max(newcomerTotal, 1))
                let point = CGPoint(
                    x: centroid.x + CGFloat(ringRadius * cos(angle)),
                    y: centroid.y + CGFloat(ringRadius * sin(angle))
                )
                seeded.append(point)
                newcomerCounter += 1
            }
        }
        return seeded
    }

    // MARK: - Ideal distance matrix

    /// Build a centre-to-centre target distance matrix that accounts for card
    /// size. `radii[i]` is the bounding-circle radius of card `i`. Adjacent
    /// cards (`graphDistance == 1`) target `radii[i] + radii[j] + edgeGap`,
    /// which keeps the empty space between borders constant regardless of
    /// individual card sizes.
    private static func buildIdealDistances(
        graphDistances: [[Double]],
        radii: [Double],
        edgeGap: Double
    ) -> [[Double]] {
        let n = radii.count
        var matrix = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n where i != j {
                let dij = graphDistances[i][j]
                matrix[i][j] = radii[i] + radii[j] + edgeGap * dij
            }
        }
        return matrix
    }

    // MARK: - Stress majorization

    private static func stressMajorize(
        positions: inout [CGPoint],
        distances: [[Double]],
        idealDistances: [[Double]],
        iterations: Int
    ) {
        let n = positions.count
        guard n > 1 else { return }

        var working = positions
        for _ in 0..<iterations {
            var next = working
            for i in 0..<n {
                let pi = working[i]
                var sumX: Double = 0
                var sumY: Double = 0
                var sumW: Double = 0
                for j in 0..<n where j != i {
                    let dij = distances[i][j]
                    guard dij > 0 else { continue }
                    let delta = idealDistances[i][j]
                    let weight = 1.0 / (dij * dij)
                    let pj = working[j]
                    let dx = Double(pi.x - pj.x)
                    let dy = Double(pi.y - pj.y)
                    let dist = max(sqrt(dx * dx + dy * dy), 0.001)
                    sumX += weight * (Double(pj.x) + delta * dx / dist)
                    sumY += weight * (Double(pj.y) + delta * dy / dist)
                    sumW += weight
                }
                if sumW > 0 {
                    next[i] = CGPoint(x: CGFloat(sumX / sumW), y: CGFloat(sumY / sumW))
                }
            }
            working = next
        }
        positions = working
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
        let n = positions.count
        guard n > 1 else { return }
        let halfMargin = margin / 2

        for _ in 0..<iterations {
            var moved = false
            for i in 0..<n {
                let ri = CGRect(
                    x: positions[i].x - sizes[i].width / 2,
                    y: positions[i].y - sizes[i].height / 2,
                    width: sizes[i].width,
                    height: sizes[i].height
                ).insetBy(dx: -halfMargin, dy: -halfMargin)
                for j in (i + 1)..<n {
                    let rj = CGRect(
                        x: positions[j].x - sizes[j].width / 2,
                        y: positions[j].y - sizes[j].height / 2,
                        width: sizes[j].width,
                        height: sizes[j].height
                    ).insetBy(dx: -halfMargin, dy: -halfMargin)
                    let inter = ri.intersection(rj)
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

    // MARK: - Edge routing

    private static func computeEdgeRoutes(
        edges: [CompoundGraph.CardEdge],
        cards: [CompoundGraph.Card],
        indexByID: [CompoundGraph.Card.ID: Int],
        cardPositions: [CompoundGraph.Card.ID: CGPoint]
    ) -> [EdgeIdentifier: EdgeRoute] {
        var routes: [EdgeIdentifier: EdgeRoute] = [:]
        routes.reserveCapacity(edges.count)
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

            let dx = tgtCenter.x - srcCenter.x
            let dy = tgtCenter.y - srcCenter.y
            let length = max(hypot(dx, dy), 0.001)
            let perp = CGVector(dx: -dy / length, dy: dx / length)
            let offsetMagnitude: CGFloat
            if edge.parallelCount > 1 {
                let centered = CGFloat(edge.parallelIndex) - CGFloat(edge.parallelCount - 1) / 2
                offsetMagnitude = centered * 16
            } else {
                offsetMagnitude = 0
            }

            let control: CGPoint
            let isCurved: Bool
            if offsetMagnitude == 0 {
                control = CGPoint(x: (srcCenter.x + tgtCenter.x) / 2, y: (srcCenter.y + tgtCenter.y) / 2)
                isCurved = false
            } else {
                let midX = (srcCenter.x + tgtCenter.x) / 2
                let midY = (srcCenter.y + tgtCenter.y) / 2
                control = CGPoint(
                    x: midX + perp.dx * offsetMagnitude * 2,
                    y: midY + perp.dy * offsetMagnitude * 2
                )
                isCurved = true
            }

            // Anchor on the rect boundary by clipping the centre-to-control
            // line. For straight edges the "control" is the midpoint, which
            // gives an exit point along the rect edge that faces the target.
            let srcAnchor = clipFromCenter(rect: srcRect, toward: control)
            let tgtAnchor = clipFromCenter(rect: tgtRect, toward: control)

            routes[edge.id] = EdgeRoute(
                start: srcAnchor,
                end: tgtAnchor,
                control: control,
                isCurved: isCurved
            )
        }
        return routes
    }

    /// Self-loop: emit an arc tangent to the top edge of the rectangle. The
    /// parallel index moves successive loops higher so they do not stack.
    private static func selfLoopRoute(
        center: CGPoint,
        size: CGSize,
        parallelIndex: Int
    ) -> EdgeRoute {
        let yOffset = CGFloat(parallelIndex) * 16
        let top = CGPoint(x: center.x, y: center.y - size.height / 2)
        let left = CGPoint(x: top.x - 24, y: top.y - 8 - yOffset)
        let right = CGPoint(x: top.x + 24, y: top.y - 8 - yOffset)
        let control = CGPoint(x: top.x, y: top.y - 48 - yOffset)
        // Re-use the curved-edge model: start and end on the top edge with a
        // control above so the renderer draws a single quadratic arc.
        _ = right
        return EdgeRoute(start: left, end: right, control: control, isCurved: true)
    }

    /// Clip a ray from the centre of `rect` toward `target` to the rectangle
    /// boundary. `rect.midPoint` must be strictly inside the rect (true by
    /// construction).
    private static func clipFromCenter(rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        if abs(dx) < 0.001 && abs(dy) < 0.001 { return center }

        var tMin: CGFloat = .infinity
        if dx > 0 {
            tMin = min(tMin, (rect.maxX - center.x) / dx)
        } else if dx < 0 {
            tMin = min(tMin, (rect.minX - center.x) / dx)
        }
        if dy > 0 {
            tMin = min(tMin, (rect.maxY - center.y) / dy)
        } else if dy < 0 {
            tMin = min(tMin, (rect.minY - center.y) / dy)
        }
        guard tMin.isFinite, tMin > 0 else { return center }
        return CGPoint(x: center.x + dx * tMin, y: center.y + dy * tMin)
    }

    // MARK: - Edge labels

    /// Place each edge label at its curve midpoint, then nudge perpendicular
    /// through a ladder of offsets until it no longer overlaps any card.
    /// Pure local optimisation — we do not run a global solver because the
    /// graph sizes here do not justify it.
    private static func placeEdgeLabels(
        edges: [CompoundGraph.CardEdge],
        routes: [EdgeIdentifier: EdgeRoute],
        cardRects: [CGRect]
    ) -> [EdgeIdentifier: CGPoint] {
        var placed: [EdgeIdentifier: CGPoint] = [:]
        placed.reserveCapacity(edges.count)
        let estimatedLabelSize = CGSize(width: 80, height: 18)
        let offsets: [CGFloat] = [0, 14, -14, 28, -28, 42, -42]
        for edge in edges {
            guard let route = routes[edge.id] else { continue }
            let mid: CGPoint
            if route.isCurved {
                // Quadratic Bezier midpoint.
                mid = CGPoint(
                    x: 0.25 * route.start.x + 0.5 * route.control.x + 0.25 * route.end.x,
                    y: 0.25 * route.start.y + 0.5 * route.control.y + 0.25 * route.end.y
                )
            } else {
                mid = CGPoint(
                    x: (route.start.x + route.end.x) / 2,
                    y: (route.start.y + route.end.y) / 2
                )
            }
            let dx = route.end.x - route.start.x
            let dy = route.end.y - route.start.y
            let len = max(hypot(dx, dy), 0.001)
            let perpX = -dy / len
            let perpY = dx / len

            var chosen = mid
            for offset in offsets {
                let candidate = CGPoint(
                    x: mid.x + perpX * offset,
                    y: mid.y + perpY * offset
                )
                let rect = CGRect(
                    x: candidate.x - estimatedLabelSize.width / 2,
                    y: candidate.y - estimatedLabelSize.height / 2,
                    width: estimatedLabelSize.width,
                    height: estimatedLabelSize.height
                )
                if !cardRects.contains(where: { $0.intersects(rect) }) {
                    chosen = candidate
                    break
                }
            }
            placed[edge.id] = chosen
        }
        return placed
    }
}
