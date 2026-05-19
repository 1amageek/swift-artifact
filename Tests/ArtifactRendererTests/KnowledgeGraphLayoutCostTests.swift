import Testing
import CoreGraphics
@testable import ArtifactNativeRenderer

@Suite("KnowledgeGraph layout cost")
struct KnowledgeGraphLayoutCostTests {
    @Test
    func placementCostPrefersSmallerOutlineWhenAreaIsNotComparable() {
        let compact = KnowledgeGraphPlacementCost(
            hardViolationCount: 0,
            estimatedCrossings: 25,
            estimatedClearancePenalty: 500,
            estimatedRouteLength: 9_000,
            estimatedMaxRouteLength: 1_200,
            outlineArea: 10_000,
            aspectPenalty: 1,
            whitespacePenalty: 2_000
        )
        let stretched = KnowledgeGraphPlacementCost(
            hardViolationCount: 0,
            estimatedCrossings: 0,
            estimatedClearancePenalty: 0,
            estimatedRouteLength: 1_000,
            estimatedMaxRouteLength: 200,
            outlineArea: 20_000,
            aspectPenalty: 0,
            whitespacePenalty: 12_000
        )

        #expect(compact.isBetter(than: stretched))
    }

    @Test
    func placementCostUsesRouteQualityWhenOutlineAreaIsComparable() {
        let crossingHeavy = KnowledgeGraphPlacementCost(
            hardViolationCount: 0,
            estimatedCrossings: 4,
            estimatedClearancePenalty: 0,
            estimatedRouteLength: 1_000,
            estimatedMaxRouteLength: 200,
            outlineArea: 10_000,
            aspectPenalty: 0,
            whitespacePenalty: 1_000
        )
        let routeClean = KnowledgeGraphPlacementCost(
            hardViolationCount: 0,
            estimatedCrossings: 1,
            estimatedClearancePenalty: 0,
            estimatedRouteLength: 1_100,
            estimatedMaxRouteLength: 220,
            outlineArea: 10_500,
            aspectPenalty: 0,
            whitespacePenalty: 1_500
        )

        #expect(routeClean.isBetter(than: crossingHeavy))
    }
}
