import Testing
import SwiftUI
import KnowledgeGraph
import KnowledgeGraphParsers
@testable import ArtifactNativeRenderer

@Suite("KnowledgeGraphPresentation style resolver")
struct KnowledgeGraphPresentationStyleResolverTests {

    @Test
    func jsonLDPresentationStylesReachNodeGroupAndEdgeDrawing() throws {
        let payload = #"""
        {
          "@context": {
            "ex": "https://example.org/",
            "rel": "https://example.org/relation#",
            "title": "https://schema.org/name",
            "handoff": { "@id": "rel:handoff", "@type": "@id" }
          },
          "@graph": [
            {
              "@id": "ex:source",
              "title": "Source",
              "handoff": "ex:target"
            },
            {
              "@id": "ex:target",
              "title": "Target"
            }
          ],
          "view": {
            "groups": [
              {
                "id": "flow",
                "title": "Flow",
                "members": ["ex:source", "ex:target"]
              }
            ],
            "styles": [
              {
                "id": "canvas",
                "target": { "type": "canvas" },
                "fill": "#F6F9FB"
              },
              {
                "id": "node-source",
                "target": { "type": "node", "id": "ex:source" },
                "shape": "capsule",
                "stroke": "#2563EB",
                "strokeWidth": 2.5
              },
              {
                "id": "group-flow",
                "target": { "type": "group", "id": "flow" },
                "shape": "roundedRectangle",
                "radius": 16,
                "lineStyle": "solid",
                "opacity": 0.22
              },
              {
                "id": "handoff-edge",
                "target": { "type": "kind", "id": "rel:handoff" },
                "stroke": "#9333EA",
                "strokeWidth": 3.0,
                "lineStyle": "dashed",
                "sourceMarker": "diamond",
                "targetMarker": "arrow",
                "edgeLabel": {
                  "fill": "#3B0764",
                  "stroke": "#C084FC",
                  "strokeWidth": 1.5,
                  "textColor": "#F5D0FE",
                  "textWeight": "bold",
                  "textSize": 11,
                  "opacity": 0.94
                }
              }
            ]
          }
        }
        """#
        let graph = try KnowledgeGraphFormat.jsonLD.parse(
            payload,
            scope: "style-resolver-test",
            baseIRI: "https://example.org/"
        )
        let presentation = try #require(try JSONLDGraphPresentationExtractor.presentation(from: payload))
        let compound = CompoundGraph.decompose(
            graph,
            groupingStrategy: .explicit(groups: [
                GroupingStrategy.ExplicitGroup(
                    id: "flow",
                    label: "Flow",
                    memberNodeIDs: [
                        .iri("https://example.org/source"),
                        .iri("https://example.org/target")
                    ]
                )
            ])
        )
        let resolver = KnowledgeGraphPresentationStyleResolver(
            graph: graph,
            presentation: presentation
        )
        let theme = KnowledgeGraphVisualTheme(colorScheme: .light)

        let sourceCard = try #require(compound.cardByID[.init(nodeID: .iri("https://example.org/source"))])
        let nodeStyle = resolver.cardStyle(for: sourceCard, theme: theme)
        #expect(nodeStyle.shape == .capsule)
        #expect(nodeStyle.strokeWidth == 2.5)

        let edge = try #require(compound.edges.first)
        let edgeStyle = resolver.edgeStyle(for: edge, theme: theme)
        #expect(edgeStyle.strokeWidth == 3.0)
        #expect(edgeStyle.strokeLine == .dashed(pattern: nil))
        #expect(edgeStyle.sourceMarker == .diamond)
        #expect(edgeStyle.targetMarker == .arrow)
        #expect(edgeStyle.label?.strokeWidth == 1.5)
        #expect(edgeStyle.label?.textWeight == .bold)
        #expect(edgeStyle.label?.textSize == 11)
        #expect(edgeStyle.label?.opacity == 0.94)

        let group = try #require(compound.groups.first)
        let groupStyle = resolver.groupStyle(for: group, groupIndex: 0, theme: theme)
        #expect(groupStyle.shape == .roundedRectangle(radius: 16))
        #expect(groupStyle.strokeLine == .solid)
        #expect(groupStyle.opacity == 0.22)

        let canvasStyle = resolver.canvasStyle(theme: theme)
        #expect(canvasStyle.fill != nil)
    }

    @Test
    func jsonLDPresentationStackLayoutsReachGraphLayout() throws {
        let payload = #"""
        {
          "@context": {
            "ex": "https://example.org/",
            "rel": "https://example.org/relation#",
            "title": "https://schema.org/name",
            "next": { "@id": "rel:next", "@type": "@id" }
          },
          "@graph": [
            { "@id": "ex:a", "title": "A", "next": "ex:c" },
            { "@id": "ex:b", "title": "B", "next": "ex:d" },
            { "@id": "ex:c", "title": "C" },
            { "@id": "ex:d", "title": "D" }
          ],
          "view": {
            "groups": [
              { "id": "left", "title": "Left", "members": ["ex:a", "ex:b"] },
              { "id": "right", "title": "Right", "members": ["ex:c", "ex:d"] }
            ],
            "layouts": [
              {
                "id": "left-stack",
                "type": "stack",
                "direction": "topToBottom",
                "spacing": 16,
                "items": ["ex:a", "ex:b"]
              },
              {
                "id": "right-stack",
                "type": "stack",
                "direction": "topToBottom",
                "spacing": 16,
                "items": ["ex:c", "ex:d"]
              },
              {
                "id": "group-stack",
                "type": "stack",
                "direction": "leftToRight",
                "alignment": "leading",
                "spacing": 80,
                "priority": "required",
                "items": [
                  { "type": "group", "id": "left" },
                  { "type": "group", "id": "right" }
                ]
              }
            ]
          }
        }
        """#
        let graph = try KnowledgeGraphFormat.jsonLD.parse(
            payload,
            scope: "layout-directive-test",
            baseIRI: "https://example.org/"
        )
        let presentation = try #require(try JSONLDGraphPresentationExtractor.presentation(from: payload))
        let layout = KnowledgeGraphLayout.compute(
            graph: graph,
            groupingStrategy: .explicit(groups: explicitGroups(from: presentation.groups)),
            presentation: presentation
        )

        let leftGroup = try #require(layout.groupBoundingBoxes[.init(key: "explicit:left")])
        let rightGroup = try #require(layout.groupBoundingBoxes[.init(key: "explicit:right")])
        #expect(leftGroup.maxX < rightGroup.minX)

        let a = try #require(layout.cardPositions[.init(nodeID: .iri("https://example.org/a"))])
        let b = try #require(layout.cardPositions[.init(nodeID: .iri("https://example.org/b"))])
        let c = try #require(layout.cardPositions[.init(nodeID: .iri("https://example.org/c"))])
        let d = try #require(layout.cardPositions[.init(nodeID: .iri("https://example.org/d"))])
        #expect(a.y < b.y)
        #expect(c.y < d.y)
        #expect(max(a.x, b.x) < min(c.x, d.x))
    }

    @Test
    func styleCascadeUsesPrioritySpecificityAndSourceOrder() throws {
        let payload = #"""
        {
          "@context": {
            "ex": "https://example.org/",
            "rel": "https://example.org/relation#",
            "title": "https://schema.org/name",
            "handoff": { "@id": "rel:handoff", "@type": "@id" }
          },
          "@graph": [
            { "@id": "ex:source", "title": "Source", "handoff": "ex:target" },
            { "@id": "ex:target", "title": "Target" }
          ],
          "view": {
            "styles": [
              {
                "id": "kind-handoff",
                "target": { "type": "kind", "id": "rel:handoff" },
                "strokeWidth": 4
              },
              {
                "id": "all-edges-later",
                "target": { "type": "allEdges" },
                "strokeWidth": 1,
                "targetMarker": "circle"
              },
              {
                "id": "all-edges-last",
                "target": { "type": "allEdges" },
                "targetMarker": "diamond"
              }
            ]
          }
        }
        """#
        let graph = try KnowledgeGraphFormat.jsonLD.parse(
            payload,
            scope: "style-cascade-test",
            baseIRI: "https://example.org/"
        )
        let presentation = try #require(try JSONLDGraphPresentationExtractor.presentation(from: payload))
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .none)
        let edge = try #require(compound.edges.first)
        let resolver = KnowledgeGraphPresentationStyleResolver(graph: graph, presentation: presentation)
        let style = resolver.edgeStyle(for: edge, theme: KnowledgeGraphVisualTheme(colorScheme: .light))

        #expect(style.strokeWidth == 4)
        #expect(style.targetMarker == .diamond)
    }

    private func explicitGroups(from groups: [GraphPresentationGroup]) -> [GroupingStrategy.ExplicitGroup] {
        groups.flatMap { group -> [GroupingStrategy.ExplicitGroup] in
            let members = group.members.compactMap { reference -> NodeIdentifier? in
                guard case .node(let node) = reference else { return nil }
                return node
            }
            return [
                GroupingStrategy.ExplicitGroup(
                    id: group.id,
                    label: group.title,
                    memberNodeIDs: members
                )
            ] + explicitGroups(from: group.children)
        }
    }
}
