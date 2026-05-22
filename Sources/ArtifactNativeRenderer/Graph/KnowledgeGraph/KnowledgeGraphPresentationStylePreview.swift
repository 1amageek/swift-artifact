import SwiftUI
import ArtifactCore
import ArtifactView

#if DEBUG
private struct KnowledgeGraphPresentationStylePreview: View {
    var body: some View {
        ArtifactCard(
            AnyArtifact(
                id: ArtifactIdentifier("jsonld-logistics-style-board"),
                type: .jsonLD,
                title: "GraphPresentation logistics board",
                attributes: ["base": "https://example.org/"],
                payload: Self.payload,
                isComplete: true
            ),
            renderer: JSONLDRenderer()
        )
        .artifactContentMaxHeight(nil)
        .padding(18)
        .frame(width: 1210, height: 760)
        .background(Color(red: 0.965, green: 0.975, blue: 0.98))
    }

    private static let payload = #"""
    {
      "@context": {
        "ex": "https://example.org/",
        "schema": "https://schema.org/",
        "rel": "https://example.org/relation#",
        "xsd": "http://www.w3.org/2001/XMLSchema#",
        "title": "schema:name",
        "note": "schema:description",
        "stage": "ex:stage",
        "status": "ex:status",
        "confidence": { "@id": "ex:confidence", "@type": "xsd:decimal" },
        "next": { "@id": "rel:next", "@type": "@id" },
        "handoff": { "@id": "rel:handoff", "@type": "@id" },
        "supports": { "@id": "rel:supports", "@type": "@id" },
        "reference": { "@id": "rel:reference", "@type": "@id" }
      },
      "@graph": [
        {
          "@id": "ex:oem-factory",
          "title": "OEM Factory",
          "note": "rectangle",
          "stage": "overseas",
          "status": "critical",
          "confidence": 0.82,
          "handoff": "ex:air-forwarder"
        },
        {
          "@id": "ex:vietnam-plant",
          "title": "Vietnam Plant",
          "note": "rounded",
          "stage": "overseas",
          "status": "stable",
          "confidence": 0.78,
          "handoff": "ex:ocean-forwarder"
        },
        {
          "@id": "ex:bangladesh-plant",
          "title": "Bangladesh Plant",
          "note": "rectangle",
          "stage": "overseas",
          "status": "stable",
          "confidence": 0.71,
          "reference": "ex:ocean-forwarder"
        },
        {
          "@id": "ex:air-forwarder",
          "title": "Air Forwarder",
          "note": "capsule + dashed",
          "stage": "international",
          "status": "watch",
          "confidence": 0.74,
          "next": "ex:chiba-dc"
        },
        {
          "@id": "ex:ocean-forwarder",
          "title": "Ocean Forwarder",
          "note": "capsule + amber",
          "stage": "international",
          "status": "watch",
          "confidence": 0.68,
          "handoff": "ex:okayama-dc"
        },
        {
          "@id": "ex:chiba-dc",
          "title": "Chiba DC",
          "note": "blue stroke",
          "stage": "domestic",
          "status": "stable",
          "confidence": 0.91,
          "supports": "ex:store-a"
        },
        {
          "@id": "ex:okayama-dc",
          "title": "Okayama DC",
          "note": "orange stroke",
          "stage": "domestic",
          "status": "stable",
          "confidence": 0.88,
          "supports": "ex:store-b"
        },
        {
          "@id": "ex:store-a",
          "title": "Store A",
          "note": "rounded",
          "stage": "retail",
          "status": "stable",
          "confidence": 0.93
        },
        {
          "@id": "ex:store-b",
          "title": "Store B",
          "note": "rounded",
          "stage": "retail",
          "status": "stable",
          "confidence": 0.89
        }
      ],
      "view": {
        "id": "logistics-style-board",
        "title": "GraphPresentation logistics board",
        "groups": [
          {
            "id": "overseas",
            "title": "Overseas",
            "members": ["ex:oem-factory", "ex:vietnam-plant", "ex:bangladesh-plant"]
          },
          {
            "id": "international",
            "title": "International",
            "members": ["ex:air-forwarder", "ex:ocean-forwarder"]
          },
          {
            "id": "domestic",
            "title": "Domestic DC",
            "members": ["ex:chiba-dc", "ex:okayama-dc"]
          },
          {
            "id": "retail",
            "title": "Retail",
            "members": ["ex:store-a", "ex:store-b"]
          }
        ],
        "styles": [
          {
            "id": "canvas-background",
            "target": { "type": "canvas" },
            "fill": "#F6F9FB"
          },
          {
            "id": "all-nodes",
            "target": { "type": "allNodes" },
            "shape": "roundedRectangle",
            "radius": 7,
            "fill": "#FFFFFF",
            "stroke": "#CBD5E1",
            "strokeWidth": 1.4,
            "textColor": "#212936"
          },
          {
            "id": "overseas-group",
            "target": { "type": "group", "id": "overseas" },
            "shape": "rectangle",
            "fill": "#EAF8F3",
            "stroke": "#23AD82",
            "strokeWidth": 1.2,
            "lineStyle": "solid",
            "textColor": "#FFFFFF",
            "priority": "override"
          },
          {
            "id": "international-group",
            "target": { "type": "group", "id": "international" },
            "shape": "roundedRectangle",
            "radius": 7,
            "fill": "#EAF7FD",
            "stroke": "#1C9BDC",
            "strokeWidth": 1.2,
            "lineStyle": "solid",
            "textColor": "#FFFFFF",
            "priority": "override"
          },
          {
            "id": "domestic-group",
            "target": { "type": "group", "id": "domestic" },
            "shape": "roundedRectangle",
            "radius": 7,
            "fill": "#EAF8F3",
            "stroke": "#23AD82",
            "strokeWidth": 1.2,
            "lineStyle": "solid",
            "textColor": "#FFFFFF",
            "priority": "override"
          },
          {
            "id": "retail-group",
            "target": { "type": "group", "id": "retail" },
            "shape": "capsule",
            "fill": "#EAF8F3",
            "stroke": "#23AD82",
            "strokeWidth": 1.2,
            "lineStyle": "solid",
            "textColor": "#FFFFFF",
            "priority": "override"
          },
          {
            "id": "oem-factory-style",
            "target": { "type": "node", "id": "ex:oem-factory" },
            "shape": "rectangle",
            "stroke": "#22C55E",
            "priority": "override"
          },
          {
            "id": "vietnam-plant-style",
            "target": { "type": "node", "id": "ex:vietnam-plant" },
            "shape": "roundedRectangle",
            "radius": 7,
            "stroke": "#34D399",
            "priority": "override"
          },
          {
            "id": "bangladesh-plant-style",
            "target": { "type": "node", "id": "ex:bangladesh-plant" },
            "shape": "rectangle",
            "stroke": "#22C55E",
            "priority": "override"
          },
          {
            "id": "air-forwarder-style",
            "target": { "type": "node", "id": "ex:air-forwarder" },
            "shape": "capsule",
            "stroke": "#3B82F6",
            "strokeWidth": 1.6,
            "lineStyle": "dashed",
            "priority": "override"
          },
          {
            "id": "ocean-forwarder-style",
            "target": { "type": "node", "id": "ex:ocean-forwarder" },
            "shape": "capsule",
            "stroke": "#F59E0B",
            "strokeWidth": 1.6,
            "priority": "override"
          },
          {
            "id": "chiba-dc-style",
            "target": { "type": "node", "id": "ex:chiba-dc" },
            "shape": "roundedRectangle",
            "radius": 7,
            "stroke": "#3B82F6",
            "strokeWidth": 1.6,
            "priority": "override"
          },
          {
            "id": "okayama-dc-style",
            "target": { "type": "node", "id": "ex:okayama-dc" },
            "shape": "roundedRectangle",
            "radius": 7,
            "stroke": "#F59E0B",
            "strokeWidth": 1.6,
            "priority": "override"
          },
          {
            "id": "retail-node-style",
            "target": { "type": "kind", "id": "iri" },
            "strokeWidth": 1.3
          },
          {
            "id": "all-edges",
            "target": { "type": "allEdges" },
            "stroke": "#6B7280",
            "strokeWidth": 1.5,
            "lineStyle": "solid",
            "sourceMarker": "none",
            "targetMarker": "arrow",
            "edgeLabel": {
              "shape": "roundedRectangle",
              "radius": 5,
              "fill": "#F8FAFC",
              "stroke": "#CBD5E1",
              "strokeWidth": 1,
              "textColor": "#475569",
              "textWeight": "semibold",
              "textSize": 10
            }
          },
          {
            "id": "handoff-edges",
            "target": { "type": "kind", "id": "rel:handoff" },
            "stroke": "#9333EA",
            "strokeWidth": 1.8,
            "lineStyle": "dashed",
            "sourceMarker": "diamond",
            "targetMarker": "arrow",
            "edgeLabel": {
              "shape": "roundedRectangle",
              "radius": 5,
              "fill": "#3B0764",
              "stroke": "#C084FC",
              "strokeWidth": 1,
              "textColor": "#F5D0FE",
              "textWeight": "bold",
              "textSize": 10,
              "opacity": 0.94
            },
            "priority": "override"
          },
          {
            "id": "reference-edges",
            "target": { "type": "kind", "id": "rel:reference" },
            "stroke": "#2563EB",
            "strokeWidth": 1.6,
            "lineStyle": "dotted",
            "sourceMarker": "none",
            "targetMarker": "arrow",
            "edgeLabel": {
              "fill": "#DBEAFE",
              "stroke": "#2563EB",
              "textColor": "#1E3A8A",
              "textWeight": "semibold"
            },
            "priority": "override"
          }
        ],
        "layouts": [
          {
            "id": "overseas-stack",
            "scope": { "type": "group", "id": "overseas" },
            "type": "stack",
            "direction": "topToBottom",
            "alignment": "stretch",
            "spacing": 14,
            "items": ["ex:oem-factory", "ex:vietnam-plant", "ex:bangladesh-plant"]
          },
          {
            "id": "international-stack",
            "scope": { "type": "group", "id": "international" },
            "type": "stack",
            "direction": "topToBottom",
            "alignment": "stretch",
            "spacing": 14,
            "items": ["ex:air-forwarder", "ex:ocean-forwarder"]
          },
          {
            "id": "domestic-stack",
            "scope": { "type": "group", "id": "domestic" },
            "type": "stack",
            "direction": "topToBottom",
            "alignment": "stretch",
            "spacing": 14,
            "items": ["ex:chiba-dc", "ex:okayama-dc"]
          },
          {
            "id": "retail-stack",
            "scope": { "type": "group", "id": "retail" },
            "type": "stack",
            "direction": "topToBottom",
            "alignment": "stretch",
            "spacing": 14,
            "items": ["ex:store-a", "ex:store-b"]
          },
          {
            "id": "stage-order",
            "type": "stack",
            "direction": "leftToRight",
            "alignment": "leading",
            "spacing": 70,
            "priority": "required",
            "items": [
              { "type": "group", "id": "overseas" },
              { "type": "group", "id": "international" },
              { "type": "group", "id": "domestic" },
              { "type": "group", "id": "retail" }
            ]
          }
        ]
      }
    }
    """#
}

#Preview("JSON-LD GraphPresentation logistics board") {
    KnowledgeGraphPresentationStylePreview()
}
#endif
