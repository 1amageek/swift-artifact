import CoreGraphics

struct KnowledgeGraphUnitPlacementPair {
    let lhs: Int
    let rhs: Int
    let gap: KnowledgeGraphNodeNodeGap
}

struct KnowledgeGraphUnitPlacementRouteEdge {
    let sourceUnit: Int
    let targetUnit: Int
    let multiplicity: Int
}

struct KnowledgeGraphPlacementCostSpacing {
    let edgeNode: CGFloat
    let edgeEdgeRoute: CGFloat
}

struct KnowledgeGraphPlacementCostModel {
    let basePositions: [CGPoint]
    let sizes: [CGSize]
    let units: [KnowledgeGraphLayoutCompactionUnit]
    let unitArea: CGFloat
    let unitPairs: [KnowledgeGraphUnitPlacementPair]
    let routeEdges: [KnowledgeGraphUnitPlacementRouteEdge]
    let spacing: KnowledgeGraphPlacementCostSpacing
    let maxEstimatedConflictRoutes: Int

    init(
        basePositions: [CGPoint],
        sizes: [CGSize],
        units: [KnowledgeGraphLayoutCompactionUnit],
        unitPairs: [KnowledgeGraphUnitPlacementPair],
        routeEdges: [KnowledgeGraphUnitPlacementRouteEdge],
        spacing: KnowledgeGraphPlacementCostSpacing,
        maxEstimatedConflictRoutes: Int
    ) {
        self.basePositions = basePositions
        self.sizes = sizes
        self.units = units
        self.unitPairs = unitPairs
        self.routeEdges = routeEdges
        self.spacing = spacing
        self.maxEstimatedConflictRoutes = maxEstimatedConflictRoutes
        self.unitArea = units.reduce(CGFloat.zero) { partial, unit in
            partial + Self.area(unit.rect)
        }
    }

    func cost(for positions: [CGPoint]) -> KnowledgeGraphLayoutCost {
        let rects = translatedUnitRects(for: positions)
        let cardRects = Self.cardRects(positions: positions, sizes: sizes)
        let outline = rects.reduce(CGRect.null) { partial, rect in
            partial.isNull ? rect : partial.union(rect)
        }
        let routeCost = estimatedRouteCost(unitRects: rects, cardRects: cardRects)
        let hardViolationCount = unitDistanceViolationCount(unitRects: rects)
        let clearancePenalty = routeCost.clearancePenalty
            + CGFloat(routeCost.hardViolationCount) * spacing.edgeNode
        let outlineArea = Self.area(outline)
        let aspect = outline.width > 0 && outline.height > 0
            ? outline.width / outline.height
            : CGFloat.greatestFiniteMagnitude
        return KnowledgeGraphLayoutCost(placement: KnowledgeGraphPlacementCost(
            hardViolationCount: hardViolationCount,
            estimatedCrossings: routeCost.crossings,
            estimatedClearancePenalty: clearancePenalty,
            estimatedRouteLength: routeCost.totalLength,
            estimatedMaxRouteLength: routeCost.maximumLength,
            outlineArea: outlineArea,
            aspectPenalty: abs(aspect - 1.5),
            whitespacePenalty: max(0, outlineArea - unitArea)
        ))
    }

    private func translatedUnitRects(for positions: [CGPoint]) -> [CGRect] {
        var rects: [CGRect] = []
        rects.reserveCapacity(units.count)
        for unit in units {
            guard let anchor = unit.indices.first,
                  anchor < positions.count,
                  anchor < basePositions.count
            else {
                rects.append(unit.rect)
                continue
            }
            rects.append(unit.rect.offsetBy(
                dx: positions[anchor].x - basePositions[anchor].x,
                dy: positions[anchor].y - basePositions[anchor].y
            ))
        }
        return rects
    }

    private func unitDistanceViolationCount(unitRects: [CGRect]) -> Int {
        var violations = 0
        for pair in unitPairs {
            let left = unitRects[pair.lhs].insetBy(
                dx: -pair.gap.horizontal / 2,
                dy: -pair.gap.vertical / 2
            )
            let right = unitRects[pair.rhs].insetBy(
                dx: -pair.gap.horizontal / 2,
                dy: -pair.gap.vertical / 2
            )
            if Self.rectsOverlap(left, right) {
                violations += 1
            }
        }
        return violations
    }

    private func estimatedRouteCost(
        unitRects: [CGRect],
        cardRects: [CGRect]
    ) -> KnowledgeGraphEstimatedPlacementRouteCost {
        guard !routeEdges.isEmpty else {
            return KnowledgeGraphEstimatedPlacementRouteCost(
                hardViolationCount: 0,
                crossings: 0,
                clearancePenalty: 0,
                totalLength: 0,
                maximumLength: 0
            )
        }

        var routes: [KnowledgeGraphEstimatedPlacementRoute] = []
        routes.reserveCapacity(routeEdges.count)
        var hardViolations = 0
        var totalLength: CGFloat = 0
        var maximumLength: CGFloat = 0
        for edge in routeEdges {
            let sourceCenter = Self.rectCenter(unitRects[edge.sourceUnit])
            let targetCenter = Self.rectCenter(unitRects[edge.targetUnit])
            let segments = Self.estimatedOrthogonalSegments(from: sourceCenter, to: targetCenter)
            let length = segments.reduce(CGFloat.zero) { partial, segment in
                partial + abs(segment.start.x - segment.end.x) + abs(segment.start.y - segment.end.y)
            }
            totalLength += length * CGFloat(edge.multiplicity)
            maximumLength = max(maximumLength, length)
            hardViolations += estimatedRouteNodeViolationCount(
                segments: segments,
                sourceUnit: edge.sourceUnit,
                targetUnit: edge.targetUnit,
                cardRects: cardRects
            ) * edge.multiplicity
            routes.append(KnowledgeGraphEstimatedPlacementRoute(
                sourceUnit: edge.sourceUnit,
                targetUnit: edge.targetUnit,
                segments: segments,
                bounds: Self.estimatedRouteBounds(segments),
                length: length * CGFloat(edge.multiplicity)
            ))
        }

        var crossings = 0
        var clearancePenalty: CGFloat = 0
        let conflictRoutes: [KnowledgeGraphEstimatedPlacementRoute]
        if routes.count > maxEstimatedConflictRoutes {
            conflictRoutes = Array(routes
                .sorted { lhs, rhs in
                    if abs(lhs.length - rhs.length) > 0.5 {
                        return lhs.length > rhs.length
                    }
                    return lhs.bounds.minX < rhs.bounds.minX
                }
                .prefix(maxEstimatedConflictRoutes))
        } else {
            conflictRoutes = routes
        }
        if conflictRoutes.count > 1 {
            for lhs in 0..<(conflictRoutes.count - 1) {
                for rhs in (lhs + 1)..<conflictRoutes.count {
                    let pair = estimatedRoutePairConflict(conflictRoutes[lhs], conflictRoutes[rhs])
                    crossings += pair.crossings
                    clearancePenalty += pair.clearancePenalty
                }
            }
        }

        return KnowledgeGraphEstimatedPlacementRouteCost(
            hardViolationCount: hardViolations,
            crossings: crossings,
            clearancePenalty: clearancePenalty,
            totalLength: totalLength,
            maximumLength: maximumLength
        )
    }

    private func estimatedRouteNodeViolationCount(
        segments: [KnowledgeGraphEstimatedPlacementSegment],
        sourceUnit: Int,
        targetUnit: Int,
        cardRects: [CGRect]
    ) -> Int {
        var excludedCards = units[sourceUnit].memberSet
        excludedCards.formUnion(units[targetUnit].memberSet)
        var violations = 0
        for segment in segments {
            for index in cardRects.indices where !excludedCards.contains(index) {
                let expanded = cardRects[index].insetBy(dx: -spacing.edgeNode, dy: -spacing.edgeNode)
                if Self.segmentIntersectsRect(segment.start, segment.end, expanded) {
                    violations += 1
                }
            }
        }
        return violations
    }

    private func estimatedRoutePairConflict(
        _ lhs: KnowledgeGraphEstimatedPlacementRoute,
        _ rhs: KnowledgeGraphEstimatedPlacementRoute
    ) -> KnowledgeGraphRouteConflictScore {
        let lhsBounds = lhs.bounds.insetBy(dx: -spacing.edgeEdgeRoute, dy: -spacing.edgeEdgeRoute)
        guard lhsBounds.intersects(rhs.bounds.insetBy(dx: -spacing.edgeEdgeRoute, dy: -spacing.edgeEdgeRoute)) else {
            return KnowledgeGraphRouteConflictScore(crossings: 0, clearancePenalty: 0)
        }

        var crossings = 0
        var clearancePenalty: CGFloat = 0
        let sharedEndpoint = lhs.sourceUnit == rhs.sourceUnit
            || lhs.sourceUnit == rhs.targetUnit
            || lhs.targetUnit == rhs.sourceUnit
            || lhs.targetUnit == rhs.targetUnit
        let multiplier: CGFloat = sharedEndpoint ? 2 : 120
        for lhsSegment in lhs.segments {
            for rhsSegment in rhs.segments {
                let distance = Self.segmentDistance(
                    lhsSegment.start,
                    lhsSegment.end,
                    rhsSegment.start,
                    rhsSegment.end
                )
                if distance < 0.5 {
                    crossings += 1
                }
                guard distance < spacing.edgeEdgeRoute else { continue }
                clearancePenalty += (spacing.edgeEdgeRoute - distance) * multiplier
                if distance < 0.5 {
                    clearancePenalty += sharedEndpoint ? 50 : 10_000
                }
            }
        }
        return KnowledgeGraphRouteConflictScore(crossings: crossings, clearancePenalty: clearancePenalty)
    }
}

private struct KnowledgeGraphEstimatedPlacementSegment {
    let start: CGPoint
    let end: CGPoint
}

private struct KnowledgeGraphEstimatedPlacementRoute {
    let sourceUnit: Int
    let targetUnit: Int
    let segments: [KnowledgeGraphEstimatedPlacementSegment]
    let bounds: CGRect
    let length: CGFloat
}

private struct KnowledgeGraphEstimatedPlacementRouteCost {
    let hardViolationCount: Int
    let crossings: Int
    let clearancePenalty: CGFloat
    let totalLength: CGFloat
    let maximumLength: CGFloat
}

private extension KnowledgeGraphPlacementCostModel {
    static func cardRects(positions: [CGPoint], sizes: [CGSize]) -> [CGRect] {
        positions.indices.map { index in
            CGRect(
                x: positions[index].x - sizes[index].width / 2,
                y: positions[index].y - sizes[index].height / 2,
                width: sizes[index].width,
                height: sizes[index].height
            )
        }
    }

    static func area(_ rect: CGRect) -> CGFloat {
        guard !rect.isNull else { return 0 }
        return max(rect.width, 0) * max(rect.height, 0)
    }

    static func rectsOverlap(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let intersection = lhs.intersection(rhs)
        return !intersection.isNull
            && intersection.width > 0.001
            && intersection.height > 0.001
    }

    static func rectCenter(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    static func estimatedOrthogonalSegments(
        from source: CGPoint,
        to target: CGPoint
    ) -> [KnowledgeGraphEstimatedPlacementSegment] {
        if abs(source.x - target.x) < 0.5 || abs(source.y - target.y) < 0.5 {
            return [KnowledgeGraphEstimatedPlacementSegment(start: source, end: target)]
        }
        let elbow: CGPoint
        if abs(target.x - source.x) >= abs(target.y - source.y) {
            elbow = CGPoint(x: target.x, y: source.y)
        } else {
            elbow = CGPoint(x: source.x, y: target.y)
        }
        return [
            KnowledgeGraphEstimatedPlacementSegment(start: source, end: elbow),
            KnowledgeGraphEstimatedPlacementSegment(start: elbow, end: target)
        ]
    }

    static func estimatedRouteBounds(_ segments: [KnowledgeGraphEstimatedPlacementSegment]) -> CGRect {
        segments.reduce(CGRect.null) { partial, segment in
            let rect = CGRect(
                x: min(segment.start.x, segment.end.x),
                y: min(segment.start.y, segment.end.y),
                width: abs(segment.start.x - segment.end.x),
                height: abs(segment.start.y - segment.end.y)
            ).insetBy(dx: -0.5, dy: -0.5)
            return partial.isNull ? rect : partial.union(rect)
        }
    }

    static func segmentDistance(
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

    static func segmentIntersectsRect(
        _ start: CGPoint,
        _ end: CGPoint,
        _ rect: CGRect
    ) -> Bool {
        let minX = min(start.x, end.x)
        let maxX = max(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxY = max(start.y, end.y)
        if maxX < rect.minX || minX > rect.maxX || maxY < rect.minY || minY > rect.maxY {
            return false
        }
        if rect.contains(start) || rect.contains(end) { return true }
        if abs(start.x - end.x) < 0.5 {
            let x = (start.x + end.x) * 0.5
            return x >= rect.minX && x <= rect.maxX
                && maxY >= rect.minY && minY <= rect.maxY
        }
        if abs(start.y - end.y) < 0.5 {
            let y = (start.y + end.y) * 0.5
            return y >= rect.minY && y <= rect.maxY
                && maxX >= rect.minX && minX <= rect.maxX
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

    static func pointSegmentDistance(
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

    static func segmentsIntersect(
        _ a: CGPoint,
        _ b: CGPoint,
        _ c: CGPoint,
        _ d: CGPoint
    ) -> Bool {
        func orientation(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
        }
        func onSegment(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Bool {
            q.x <= max(p.x, r.x) + 0.001
                && q.x + 0.001 >= min(p.x, r.x)
                && q.y <= max(p.y, r.y) + 0.001
                && q.y + 0.001 >= min(p.y, r.y)
        }

        let o1 = orientation(a, b, c)
        let o2 = orientation(a, b, d)
        let o3 = orientation(c, d, a)
        let o4 = orientation(c, d, b)
        if (o1 > 0 && o2 < 0 || o1 < 0 && o2 > 0)
            && (o3 > 0 && o4 < 0 || o3 < 0 && o4 > 0) {
            return true
        }
        if abs(o1) < 0.001 && onSegment(a, c, b) { return true }
        if abs(o2) < 0.001 && onSegment(a, d, b) { return true }
        if abs(o3) < 0.001 && onSegment(c, a, d) { return true }
        if abs(o4) < 0.001 && onSegment(c, b, d) { return true }
        return false
    }
}
