import Foundation
import CoreGraphics
import KnowledgeGraph

/// Force-directed layout for a `KnowledgeGraph`.
///
/// The pipeline is:
///
/// 1. **Decomposition** — `CompoundGraph.decompose` folds every leaf literal
///    into its owning subject's card. Layout therefore operates on cards
///    rather than raw nodes, which eliminates the foaf:name "Alice" pattern
///    as an independent vertex.
///
/// 2. **Golden-angle seeding** — newcomer cards are placed on a Vogel spiral
///    (`angle = i · 137.5°`, `radius ∝ √i`) around the warm-restart centroid.
///    Spiral seeding gives every card a roughly equal share of canvas area
///    at the start, which avoids the "all on one ring" collapse that
///    same-radius seeding produced when many cards shared an initial angle.
///
/// 3. **Fruchterman–Reingold** force-directed relaxation. Each iteration
///    accumulates two forces per card:
///      - **Coulomb repulsion** between every pair, magnitude `k² / d`
///        where `k = avgRadius·2 + gap`. A `5k` cutoff bounds the influence
///        of disconnected components so they do not drift to infinity.
///      - **Spring attraction** along each direct graph edge, magnitude
///        `d² / ideal_ij` where `ideal_ij = radius(i) + radius(j) + gap`.
///        Attraction is therefore *size-aware*: hubs with large children
///        anchor their orbit at a distance that matches the actual radii.
///    Per-iteration movement is capped by a temperature that cools as
///    `t₀ · (1 - i/N)^1.3`, so the layout settles smoothly without
///    oscillating across the final iterations.
///
/// 4. **Separation constraints**. After FR converges we run overlap-removal
///    passes: any pair whose padded rectangles overlap is projected apart
///    along the axis of smaller penetration. This corrects the residual
///    near-overlaps that a continuous force model alone cannot eliminate.
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
        /// `true` when this edge is one of multiple parallel edges between
        /// the same pair of cards (or its sibling pair `(t, s)`) and needs a
        /// curved render.
        let isCurved: Bool
    }

    static let defaultIterations = 200
    /// Desired empty space between adjacent card boundaries. The actual
    /// centre-to-centre target for a graph edge adds the two cards' bounding
    /// radii on top of this, so cards never overlap regardless of their
    /// individual sizes.
    static let defaultEdgeGap: Double = 140

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

        // Estimate canvas size from total card area so the spiral seed has
        // room to breathe before the relaxation runs.
        let totalAttrArea = compound.cards.reduce(0.0) { acc, card in
            acc + Double(card.size.width * card.size.height)
        }
        let canvasSeed = max(520.0, sqrt(totalAttrArea) * 3.0)

        var positions = seedPositions(
            cards: compound.cards,
            initial: initial,
            canvasSeed: canvasSeed
        )

        let sizes = compound.cards.map { $0.size }
        let radii = sizes.map { Double(hypot($0.width, $0.height)) / 2.0 }

        // Step 3: Fruchterman–Reingold relaxation with size-aware springs
        // and an optional cohesion pull toward the centroid of each card's
        // groups. Cohesion is per-group so a card in two groups feels both
        // pulls — visually they overlap, which matches the rendering model.
        fruchtermanReingold(
            positions: &positions,
            radii: radii,
            edges: compound.edges,
            indexByID: indexByID,
            groups: compound.groups,
            iterations: iterations
        )

        // Step 4: separation constraints (card-vs-card non-overlap).
        resolveOverlaps(
            positions: &positions,
            sizes: sizes,
            margin: 48,
            iterations: 60
        )

        // Translate to a non-negative coordinate space and finalise canvas.
        // Groups need extra slack so their padded bbox + outside-top label
        // fit inside the canvas without clipping.
        let canvasPadding: CGFloat = compound.groups.isEmpty ? 36 : 64
        let (cardPositions, canvasSize) = anchorAndCanvas(
            cards: compound.cards,
            centerPositions: positions,
            padding: canvasPadding
        )

        // Step 5 & 6: edge routes and label slotting.
        let routes = computeEdgeRoutes(
            edges: compound.edges,
            cards: compound.cards,
            indexByID: indexByID,
            cardPositions: cardPositions
        )
        let cardRects = compound.cards.map { card -> CGRect in
            // anchorAndCanvas produces an origin for every card, so a missing
            // lookup here would mean the pipeline desynced — fail loudly.
            guard let origin = cardPositions[card.id] else {
                preconditionFailure("Card \(card.id) missing from cardPositions")
            }
            return CGRect(origin: origin, size: card.size)
        }
        let labels = placeEdgeLabels(
            edges: compound.edges,
            routes: routes,
            cardRects: cardRects
        )

        let groupBoxes = computeGroupBoundingBoxes(
            groups: compound.groups,
            cards: compound.cards,
            indexByID: indexByID,
            cardPositions: cardPositions
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

    // MARK: - Fruchterman–Reingold

    /// Fruchterman–Reingold relaxation. Each iteration applies pairwise
    /// Coulomb-style repulsion plus per-edge spring attraction, then caps
    /// the net displacement by a cooling temperature.
    ///
    /// - The repulsion constant `k = avgRadius·2 + edgeGap` matches the
    ///   expected ideal distance between two average cards connected by an
    ///   edge. Squaring it (`k²`) gives the repulsion magnitude at unit
    ///   distance.
    /// - Repulsion is gated by `repelCutoff = 5k`; pairs farther apart
    ///   contribute zero force. This prevents disconnected components from
    ///   drifting to infinity while still letting connected hubs spread
    ///   freely within the cutoff radius.
    /// - Spring attraction uses per-edge ideal distance
    ///   `radii[i] + radii[j] + edgeGap`, so hubs whose children are large
    ///   anchor at a distance proportional to those children's radii.
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
        let k0 = avgRadius * 2.0 + defaultEdgeGap
        let k0Sq = k0 * k0
        let repelCutoff = k0 * 5.0
        let initialTemp = k0 * 1.6
        let coolingExponent: Double = 1.3

        // Pre-compute the unique neighbour list with per-edge ideal distance
        // so self-loops and parallel edges contribute a single spring each.
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
            let ideal = radii[i] + radii[j] + defaultEdgeGap
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
        }

        var working = positions
        var dispX = Array(repeating: 0.0, count: n)
        var dispY = Array(repeating: 0.0, count: n)

        for step in 0..<iterations {
            for k in 0..<n {
                dispX[k] = 0
                dispY[k] = 0
            }

            // Pairwise repulsion. Cutoff at `5k` keeps disconnected components
            // bounded; without it the FR model has no equilibrium for them.
            for i in 0..<(n - 1) {
                let pix = Double(working[i].x)
                let piy = Double(working[i].y)
                for j in (i + 1)..<n {
                    let dx = pix - Double(working[j].x)
                    let dy = piy - Double(working[j].y)
                    let distSq = dx * dx + dy * dy
                    let dist = max(sqrt(distSq), 0.01)
                    if dist > repelCutoff { continue }
                    let force = k0Sq / dist
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

            // Group cohesion: linear Hookean pull toward the group centroid.
            //   `F = strength · (centroid − position)`.
            // With `strength = 0.05` a card 200 pt off centroid feels a 10 pt
            // pull while the FR spring at the same distance is ≈ 200 pt — so
            // cohesion is a few-percent bias, not a dominant force, which is
            // what we want for a *grouping hint*. Multi-member groups only —
            // singletons would have `centroid == position` and contribute
            // nothing.
            for group in groupForces {
                var cx = 0.0
                var cy = 0.0
                for idx in group.indices {
                    cx += Double(working[idx].x)
                    cy += Double(working[idx].y)
                }
                let invCount = 1.0 / Double(group.indices.count)
                cx *= invCount
                cy *= invCount
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
