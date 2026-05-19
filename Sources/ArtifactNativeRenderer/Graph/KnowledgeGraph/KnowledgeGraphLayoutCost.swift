import CoreGraphics

struct KnowledgeGraphResolvedCardEdge {
    let source: Int
    let target: Int
}

struct KnowledgeGraphLayoutCostContext {
    let edgeEndpoints: [KnowledgeGraphResolvedCardEdge]
    let edgeMultiplicity: [UInt64: Int]
    let groupEdgeCounts: [UInt64: Int]
}

struct KnowledgeGraphLayoutCost {
    let placement: KnowledgeGraphPlacementCost

    func isBetter(than other: KnowledgeGraphLayoutCost) -> Bool {
        placement.isBetter(than: other.placement)
    }
}

struct KnowledgeGraphPlacementCost {
    private static let comparableOutlineAreaRatio: CGFloat = 0.08

    let hardViolationCount: Int
    let estimatedCrossings: Int
    let estimatedClearancePenalty: CGFloat
    let estimatedRouteLength: CGFloat
    let estimatedMaxRouteLength: CGFloat
    let outlineArea: CGFloat
    let aspectPenalty: CGFloat
    let whitespacePenalty: CGFloat

    func isBetter(than other: KnowledgeGraphPlacementCost) -> Bool {
        if hardViolationCount != other.hardViolationCount {
            return hardViolationCount < other.hardViolationCount
        }
        if !hasComparableOutlineArea(to: other) {
            return outlineArea < other.outlineArea
        }
        if estimatedCrossings != other.estimatedCrossings {
            return estimatedCrossings < other.estimatedCrossings
        }
        if abs(estimatedClearancePenalty - other.estimatedClearancePenalty) > 0.001 {
            return estimatedClearancePenalty < other.estimatedClearancePenalty
        }
        if abs(estimatedRouteLength - other.estimatedRouteLength) > 0.5 {
            return estimatedRouteLength < other.estimatedRouteLength
        }
        if abs(estimatedMaxRouteLength - other.estimatedMaxRouteLength) > 0.5 {
            return estimatedMaxRouteLength < other.estimatedMaxRouteLength
        }
        if abs(outlineArea - other.outlineArea) > 0.5 {
            return outlineArea < other.outlineArea
        }
        if abs(aspectPenalty - other.aspectPenalty) > 0.001 {
            return aspectPenalty < other.aspectPenalty
        }
        if abs(whitespacePenalty - other.whitespacePenalty) > 0.5 {
            return whitespacePenalty < other.whitespacePenalty
        }
        return false
    }

    private func hasComparableOutlineArea(to other: KnowledgeGraphPlacementCost) -> Bool {
        let delta = abs(outlineArea - other.outlineArea)
        let tolerance = max(CGFloat(0.5), max(outlineArea, other.outlineArea) * Self.comparableOutlineAreaRatio)
        return delta <= tolerance
    }
}

struct KnowledgeGraphRouteCost {
    let length: CGFloat
    let corners: Int
    let clearancePenalty: CGFloat
    let portCenterPenalty: CGFloat

    func isBetter(than other: KnowledgeGraphRouteCost) -> Bool {
        if abs(length - other.length) > 0.001 {
            return length < other.length
        }
        if corners != other.corners {
            return corners < other.corners
        }
        if abs(clearancePenalty - other.clearancePenalty) > 0.001 {
            return clearancePenalty < other.clearancePenalty
        }
        if abs(portCenterPenalty - other.portCenterPenalty) > 0.001 {
            return portCenterPenalty < other.portCenterPenalty
        }
        return false
    }
}

struct KnowledgeGraphRouteConflictScore {
    let crossings: Int
    let clearancePenalty: CGFloat

    func isBetter(than other: KnowledgeGraphRouteConflictScore) -> Bool {
        if crossings != other.crossings {
            return crossings < other.crossings
        }
        if abs(clearancePenalty - other.clearancePenalty) > 0.001 {
            return clearancePenalty < other.clearancePenalty
        }
        return false
    }
}
