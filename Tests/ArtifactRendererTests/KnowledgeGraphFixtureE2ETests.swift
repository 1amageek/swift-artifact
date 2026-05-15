import Testing
import Foundation
import CoreGraphics
import KnowledgeGraph
@testable import ArtifactNativeRenderer

/// End-to-end tests that parse the TriG fixtures in
/// `Tests/ArtifactRendererTests/Fixtures/Groups` through the same code path
/// the renderer uses at runtime, then assert the grouping result.
///
/// Scope is intentionally limited to what the current parsers expose:
/// only the TriG parser populates `graph.namedGraphs` (TriGParser.swift:188).
/// `Node.types` and `graph.namespaces` are not populated by the
/// Turtle / TriG parsers — only the JSON-LD parser materialises `Node.types`.
/// Therefore `.byType` and `.byNamespace` fixture tests would be testing
/// "parser limitations" rather than the grouping pipeline, so they live in
/// `CompoundGraphGroupTests` against hand-built graphs instead.
@Suite("Knowledge graph grouping — fixture E2E")
struct KnowledgeGraphFixtureE2ETests {

    // MARK: - Helpers

    private static func loadFixture(_ name: String, format: KnowledgeGraphFormat) throws -> KnowledgeGraph {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Groups"),
            "Fixture \(name) not found in Tests/ArtifactRendererTests/Fixtures/Groups"
        )
        let payload = try String(contentsOf: url, encoding: .utf8)
        return try format.parse(payload, scope: "fixture-\(name)", baseIRI: nil)
    }

    private static func keys(_ groups: [CompoundGraph.Group]) -> Set<String> {
        Set(groups.map { $0.id.key })
    }

    // MARK: - namedGraphs (two-disjoint-graphs.trig)

    @Test
    func twoDisjointTriGFixtureProducesOneGroupPerNamedGraph() throws {
        let graph = try Self.loadFixture("two-disjoint-graphs.trig", format: .trig)
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .namedGraphs())
        let groupKeys = Self.keys(compound.groups)
        #expect(groupKeys.contains("namedGraph:http://example.org/g1"))
        #expect(groupKeys.contains("namedGraph:http://example.org/g2"))
        #expect(compound.groups.count == 2)
        let g1 = compound.groupByID[CompoundGraph.Group.ID(key: "namedGraph:http://example.org/g1")]
        let g2 = compound.groupByID[CompoundGraph.Group.ID(key: "namedGraph:http://example.org/g2")]
        let g1Members = try #require(g1?.members)
        let g2Members = try #require(g2?.members)
        #expect(Set(g1Members).intersection(Set(g2Members)).isEmpty)
    }

    // MARK: - literal folding (literal-only-named-graph.trig)

    @Test
    func literalOnlyNamedGraphFixtureKeepsSubjectCards() throws {
        // All *objects* in the named graph are literals (folded as attributes
        // onto their subject cards), but the IRI subjects (ex:alice, ex:bob)
        // still survive as cards. The named graph therefore retains 2 members.
        // The B2 invariant ("group dropped when all members fold away") is
        // covered by the hand-built `emptyGroupsAreFilteredAfterLiteralFolding`
        // unit test, which is the only way to express a truly literal-only
        // named graph (no IRI subjects).
        let graph = try Self.loadFixture("literal-only-named-graph.trig", format: .trig)
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .namedGraphs())
        #expect(compound.groups.allSatisfy { !$0.members.isEmpty })
        let factsGroup = compound.groupByID[CompoundGraph.Group.ID(key: "namedGraph:http://example.org/facts")]
        let members = try #require(factsGroup?.members)
        #expect(members.count == 2)
    }

    // MARK: - combined (namedGraphs + byType)
    //
    // The TriG fixture declares `a foaf:Person` etc., but the TriG parser
    // does not populate `Node.types` from those `rdf:type` triples. So the
    // `.byType` arm produces zero groups, and only the `.namedGraphs` arm
    // contributes. The test asserts that combined behaviour: namedGraph
    // groups appear, and no type: keys leak in.

    @Test
    func combinedFixtureProducesNamedGraphGroupsOnly() throws {
        let graph = try Self.loadFixture(
            "combined-namedGraphs-and-types.trig",
            format: .trig
        )
        let compound = CompoundGraph.decompose(
            graph,
            groupingStrategy: .combined(strategies: [.namedGraphs(), .byType()])
        )
        let groupKeys = Self.keys(compound.groups)
        #expect(groupKeys.contains("namedGraph:http://example.org/engineering"))
        #expect(groupKeys.contains("namedGraph:http://example.org/sales"))
        #expect(groupKeys.contains("namedGraph:http://example.org/management"))
        #expect(compound.groups.count == 3)
        #expect(groupKeys.allSatisfy { $0.hasPrefix("namedGraph:") })
    }

    // MARK: - Layout pipeline integration

    @Test
    func fixtureFlowsThroughLayoutWithoutNaN() throws {
        // Smoke test — the fixture must round-trip through the full pipeline
        // (parse → decompose → layout) without producing NaN/Inf coordinates
        // or degenerate bounding boxes for any group.
        let graph = try Self.loadFixture(
            "combined-namedGraphs-and-types.trig",
            format: .trig
        )
        let result = KnowledgeGraphLayout.compute(
            graph: graph,
            groupingStrategy: .namedGraphs()
        )
        try #require(result.compoundGraph.groups.count == 3)
        for (_, point) in result.cardPositions {
            #expect(point.x.isFinite)
            #expect(point.y.isFinite)
        }
        for (_, bbox) in result.groupBoundingBoxes {
            #expect(bbox.width.isFinite)
            #expect(bbox.height.isFinite)
            #expect(bbox.width > 0)
            #expect(bbox.height > 0)
        }
        #expect(result.compoundGraph.groups.count == result.groupBoundingBoxes.count)
    }
}
