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

        // Step 2.5: intra-group pre-pass. For each group, run a localised
        // FR pass on its members alone — no external repulsion, no
        // cross-group springs, no other groups in scope. This packs the
        // group's members into a tight cluster around their seed centroid
        // *before* any cross-group force has a chance to pull them apart.
        // Without this pre-pass, a member whose only real edge crosses
        // the group boundary (e.g. `org:hr/payroll → carol`) starts the
        // global FR being pulled outward at full edge strength while the
        // weaker intra-group pseudo-spring loses the race — the member
        // ends up scattered to the far edge of the group's bbox. By
        // converging members locally first, the global FR begins with
        // members already adjacent; cross-group springs can then only
        // translate the cluster as a whole rather than tear it apart.
        intraGroupPrePass(
            positions: &positions,
            radii: radii,
            edges: compound.edges,
            indexByID: indexByID,
            groups: compound.groups
        )

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
        let edgeLengthConstraints = edgeLengthConstraints(
            positions: positions,
            edges: compound.edges,
            indexByID: indexByID
        )

        // Step 3.5: orthogonal alignment of group centroids. FR's repulsion
        // (gated to a 2.5k cutoff) keeps disjoint groups within force range
        // of each other but settles them at whatever diagonal minimises
        // pairwise energy — which visually reads as scattered. After FR has
        // converged we run a rigid-body snap pass that pulls each group pair's
        // centroids onto a shared row or column. Every snap iteration is
        // followed by an edge-length projection, so groups use the available
        // angular freedom without stretching the edges that connect them.
        snapGroupCentroidsToAxes(
            positions: &positions,
            sizes: sizes,
            edges: compound.edges,
            edgeLengthConstraints: edgeLengthConstraints,
            groups: compound.groups,
            indexByID: indexByID
        )

        // Step 3.6: eject non-member cards from group bboxes. FR's
        // equilibrium can place a card connected to members of multiple
        // groups at a position that falls inside one of those groups'
        // rendered bboxes — e.g. a shared `rdf:type` target whose
        // connection centroid lands inside one of the connected
        // groups. The rendered group bbox then visually encloses a
        // card that is not actually a member. Project any such card
        // outward to the nearest bbox edge before overlap resolution
        // so the rendered group reads as containing only its members.
        ejectNonMembersFromGroups(
            positions: &positions,
            sizes: sizes,
            groups: compound.groups,
            indexByID: indexByID
        )

        // Step 4: separation constraints (card-vs-card non-overlap). Runs
        // after the orthogonal snap so any residual overlaps caused by
        // rigid group translation are corrected here.
        resolveOverlaps(
            positions: &positions,
            sizes: sizes,
            margin: 48,
            iterations: 60
        )

        // Step 4.5: edge-angle relaxation. At this point edge lengths,
        // group spacing, and card separation are already acceptable. This
        // pass therefore works in the angular dimension only: every edge is
        // rotated toward its nearest cardinal direction while preserving its
        // current midpoint and centre-to-centre length for that edge's local
        // proposal. A short cleanup pass re-applies containment / overlap
        // constraints after the angular nudges.
        relaxEdgeAngles(
            positions: &positions,
            edges: compound.edges,
            indexByID: indexByID,
            iterations: 28,
            strength: 0.22
        )
        orientBridgeEdgesByGroupOrder(
            positions: &positions,
            edges: compound.edges,
            groups: compound.groups,
            indexByID: indexByID
        )
        fanOutGroupsAroundBridgeEdges(
            positions: &positions,
            edges: compound.edges,
            groups: compound.groups,
            indexByID: indexByID
        )
        projectEdgeLengths(
            positions: &positions,
            constraints: edgeLengthConstraints,
            iterations: 10
        )
        ejectNonMembersFromGroups(
            positions: &positions,
            sizes: sizes,
            groups: compound.groups,
            indexByID: indexByID
        )
        resolveOverlaps(
            positions: &positions,
            sizes: sizes,
            margin: 48,
            iterations: 24
        )
        projectEdgeLengths(
            positions: &positions,
            constraints: edgeLengthConstraints,
            iterations: 10
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
        // Tighter gap than the global default: members should nestle
        // close. 60 pt of empty space between adjacent member rectangles
        // is dense without touching for typical card sizes.
        let intraGap: Double = 60
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
        let effectiveGap = adaptiveEdgeGap(cardCount: n)
        let k0 = avgRadius * 2.0 + effectiveGap
        let k0Sq = k0 * k0
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
        // Intra-group rest length is tighter than the global gap so
        // unconnected members in the same group sit closer than
        // edge-connected cards in general. Empirically a 0.6× factor
        // produces a comfortable interior spacing without the cards
        // touching at typical sizes (radii ≈ 50, gap ≈ 140 → ideal ≈ 184).
        let intraGroupGapFactor: Double = 0.6
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
                    let ideal = radii[i] + radii[j] + effectiveGap * intraGroupGapFactor
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

            // Pairwise repulsion. Cutoff at `2.5k` keeps disconnected
            // components from pushing past their settle distance once gravity
            // becomes the dominant force. The 5k cutoff used originally let
            // disconnected clusters drift to the canvas corners; combined
            // with the new gravity term, 2.5k is enough to space adjacent
            // cards while remaining short-range.
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
        let visualGap: Double = 32
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

            // Canonical perpendicular direction. The bucket containing
            // this edge may include edges in either direction (the
            // unordered `PairKey` deliberately merges them), so to
            // render parallel siblings on consistent opposite sides
            // we anchor the perpendicular on a canonical ordering of
            // the two endpoints rather than the per-edge src→tgt
            // direction. Without this, two mutual edges `A→B` and
            // `B→A` compute perpendiculars that point in *opposite*
            // directions; applying signed `parallelIndex` offsets
            // then places both edges on the same physical side and
            // the curves still overlap. Anchoring on the smaller
            // card index gives both edges the same perp basis, so
            // their signed offsets land on opposite sides.
            let lowIndex = min(srcIndex, tgtIndex)
            let highIndex = max(srcIndex, tgtIndex)
            let lowCenter = (lowIndex == srcIndex) ? srcCenter : tgtCenter
            let highCenter = (lowIndex == srcIndex) ? tgtCenter : srcCenter
            _ = highIndex
            let canonDx = highCenter.x - lowCenter.x
            let canonDy = highCenter.y - lowCenter.y
            let canonLen = max(hypot(canonDx, canonDy), 0.001)
            let perp = CGVector(dx: -canonDy / canonLen, dy: canonDx / canonLen)
            let offsetMagnitude: CGFloat
            if edge.parallelCount > 1 {
                let centered = CGFloat(edge.parallelIndex) - CGFloat(edge.parallelCount - 1) / 2
                // 28 pt per parallel step, combined with the × 3
                // multiplier in the control offset below, yields a
                // curve midpoint deviation of ≈ 21 pt for a 2-edge
                // bundle (centered = ±0.5 → control offset = ±42 →
                // mid deviation = ±21). That puts the two parallel
                // labels comfortably apart instead of stacked.
                offsetMagnitude = centered * 28
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
                    x: midX + perp.dx * offsetMagnitude * 3,
                    y: midY + perp.dy * offsetMagnitude * 3
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
