import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView
import KnowledgeGraph

/// Renders `application/ld+json` artifacts as a force-directed diagram.
///
/// Streaming behaviour: while the artifact is incomplete, a tolerant
/// partial-JSON pass extracts whatever triples are derivable from the
/// currently-arrived prefix (`PartialJSONLDProcessor`). Once a single triple
/// is available, the renderer flips to `.renderable` so the diagram appears
/// progressively rather than waiting for the closing `}`. The complete
/// payload runs through the full W3C JSON-LD parser as the final pass.
///
/// Setting `attributes["base"]` supplies the base IRI used to resolve
/// relative IRIs inside the document; for the complete-payload parse the
/// underlying parser throws `ParserError.noBaseIRI` if a relative IRI
/// appears with no base in scope.
public struct JSONLDRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .jsonLD
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        if KnowledgeGraphFormat.jsonLD.hasRenderablePartial(
            artifact.payload,
            baseIRI: artifact.attributes["base"]
        ) {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first resolvable node"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        KnowledgeGraphRendererBody(artifact: artifact, payload: payload, format: .jsonLD)
    }
}

#Preview("Card — small JSON-LD graph") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("jl1"),
            type: .jsonLD,
            title: "JSON-LD",
            attributes: ["base": "http://example.org/"],
            payload: #"""
            {
              "@context": {
                "name": "http://schema.org/name",
                "knows": {
                  "@id": "http://schema.org/knows",
                  "@type": "@id"
                }
              },
              "@graph": [
                {"@id": "http://example.org/alice", "name": "Alice", "knows": "http://example.org/bob"},
                {"@id": "http://example.org/bob",   "name": "Bob",   "knows": "http://example.org/carol"},
                {"@id": "http://example.org/carol", "name": "Carol"}
              ]
            }
            """#,
            isComplete: true
        ),
        renderer: JSONLDRenderer()
    )
    .frame(width: 520, height: 420)
}

#Preview("Card — complex grouped JSON-LD graph") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("jl-complex-grouped"),
            type: .jsonLD,
            title: "Complex Grouped JSON-LD",
            attributes: ["base": "https://example.org/"],
            payload: #"""
            {
              "@context": {
                "@base": "https://example.org/",
                "factor": "https://example.org/factor/",
                "evidence": "https://example.org/evidence/",
                "question": "https://example.org/question/",
                "rel": "https://example.org/relation#",
                "schema": "https://schema.org/",
                "vocab": "https://example.org/vocab#",
                "xsd": "http://www.w3.org/2001/XMLSchema#",

                "Factor": "vocab:Factor",
                "Evidence": "vocab:Evidence",
                "Question": "vocab:Question",
                "Insight": "vocab:Insight",
                "Risk": "vocab:Risk",
                "title": "schema:name",
                "content": "schema:description",
                "confidence": {
                  "@id": "vocab:confidence",
                  "@type": "xsd:decimal"
                },
                "supports": {
                  "@id": "rel:supports",
                  "@type": "@id"
                },
                "derivedFrom": {
                  "@id": "rel:derivedFrom",
                  "@type": "@id",
                  "@container": "@set"
                },
                "asksAbout": {
                  "@id": "rel:asksAbout",
                  "@type": "@id"
                },
                "mitigates": {
                  "@id": "rel:mitigates",
                  "@type": "@id"
                },
                "chartableData": {
                  "@id": "rel:chartableData",
                  "@type": "@id"
                }
              },
              "view": {
                "groups": [
                  {
                    "id": "group:layer/context",
                    "kind": "layer",
                    "title": "Context",
                    "children": [
                      {
                        "id": "group:category/context/industrial-base",
                        "kind": "category",
                        "title": "Industrial base",
                        "members": [
                          "factor:setouchi-industrial-base",
                          "factor:shipping-corridor",
                          "evidence:port-throughput"
                        ]
                      },
                      {
                        "id": "group:category/context/labor-market",
                        "kind": "category",
                        "title": "Labor market",
                        "members": [
                          "factor:regional-labor-pool",
                          "evidence:vocational-pipeline"
                        ]
                      }
                    ]
                  },
                  {
                    "id": "group:layer/situation",
                    "kind": "layer",
                    "title": "Situation",
                    "children": [
                      {
                        "id": "group:category/situation/demand",
                        "kind": "category",
                        "title": "Demand",
                        "members": [
                          "factor:shipbuilding-backlog",
                          "factor:ev-supply-chain-shift",
                          "evidence:capex-announcements"
                        ]
                      },
                      {
                        "id": "group:category/situation/cost",
                        "kind": "category",
                        "title": "Cost pressure",
                        "members": [
                          "factor:energy-cost-pressure",
                          "factor:procurement-friction"
                        ]
                      }
                    ]
                  },
                  {
                    "id": "group:layer/issue",
                    "kind": "layer",
                    "title": "Issue",
                    "children": [
                      {
                        "id": "group:category/issue/capacity",
                        "kind": "category",
                        "title": "Capacity risk",
                        "members": [
                          "factor:grid-capacity-risk",
                          "factor:skilled-labor-shortage",
                          "question:export-demand-durability"
                        ]
                      },
                      {
                        "id": "group:category/issue/supply",
                        "kind": "category",
                        "title": "Supply resilience",
                        "members": [
                          "factor:component-supply-volatility",
                          "factor:inventory-buffer-limit"
                        ]
                      }
                    ]
                  },
                  {
                    "id": "group:layer/outcome",
                    "kind": "layer",
                    "title": "Outcome",
                    "children": [
                      {
                        "id": "group:category/outcome/investment",
                        "kind": "category",
                        "title": "Investment thesis",
                        "members": [
                          "factor:gx-investment-scenario",
                          "factor:automation-upside"
                        ]
                      },
                      {
                        "id": "group:category/outcome/resilience",
                        "kind": "category",
                        "title": "Regional resilience",
                        "members": [
                          "factor:regional-cluster-resilience",
                          "evidence:scenario-dashboard"
                        ]
                      }
                    ]
                  }
                ]
              },
              "@graph": [
                {
                  "@id": "factor:setouchi-industrial-base",
                  "@type": "Factor",
                  "title": "Setouchi industrial base",
                  "content": "Existing manufacturing density anchors the regional supply network.",
                  "confidence": 0.72,
                  "supports": "factor:regional-cluster-resilience"
                },
                {
                  "@id": "factor:shipping-corridor",
                  "@type": "Factor",
                  "title": "Shipping corridor",
                  "content": "Port and inland routes connect component suppliers with assembly sites.",
                  "confidence": 0.68,
                  "supports": "factor:shipbuilding-backlog"
                },
                {
                  "@id": "evidence:port-throughput",
                  "@type": "Evidence",
                  "title": "Port throughput trend",
                  "content": "Cargo throughput remains high enough to support expansion scenarios.",
                  "confidence": 0.77,
                  "supports": [
                    "factor:shipping-corridor",
                    "factor:regional-cluster-resilience"
                  ]
                },
                {
                  "@id": "factor:regional-labor-pool",
                  "@type": "Factor",
                  "title": "Regional labor pool",
                  "content": "Specialized workers are available but concentrated in a few districts.",
                  "confidence": 0.63,
                  "supports": "factor:automation-upside"
                },
                {
                  "@id": "evidence:vocational-pipeline",
                  "@type": "Evidence",
                  "title": "Vocational pipeline",
                  "content": "Training capacity partially offsets retirement-driven labor losses.",
                  "confidence": 0.64,
                  "supports": "factor:regional-labor-pool"
                },
                {
                  "@id": "factor:shipbuilding-backlog",
                  "@type": "Factor",
                  "title": "Shipbuilding backlog",
                  "content": "Backlog creates near-term utilization but raises delivery risk.",
                  "confidence": 0.70,
                  "derivedFrom": [
                    "factor:shipping-corridor",
                    "evidence:port-throughput"
                  ],
                  "supports": "factor:gx-investment-scenario"
                },
                {
                  "@id": "factor:ev-supply-chain-shift",
                  "@type": "Insight",
                  "title": "EV supply-chain shift",
                  "content": "EV component demand is moving procurement toward higher precision suppliers.",
                  "confidence": 0.66,
                  "derivedFrom": [
                    "factor:setouchi-industrial-base",
                    "evidence:capex-announcements"
                  ],
                  "supports": "factor:automation-upside"
                },
                {
                  "@id": "evidence:capex-announcements",
                  "@type": "Evidence",
                  "title": "Capex announcements",
                  "content": "Multiple firms announced expansion plans in adjacent production categories.",
                  "confidence": 0.74,
                  "supports": [
                    "factor:ev-supply-chain-shift",
                    "factor:gx-investment-scenario"
                  ]
                },
                {
                  "@id": "factor:energy-cost-pressure",
                  "@type": "Risk",
                  "title": "Energy cost pressure",
                  "content": "Power price volatility can erode margin on energy-intensive production.",
                  "confidence": 0.61,
                  "supports": "factor:grid-capacity-risk"
                },
                {
                  "@id": "factor:procurement-friction",
                  "@type": "Risk",
                  "title": "Procurement friction",
                  "content": "Lead times for critical components remain unstable.",
                  "confidence": 0.58,
                  "supports": [
                    "factor:component-supply-volatility",
                    "factor:inventory-buffer-limit"
                  ]
                },
                {
                  "@id": "factor:grid-capacity-risk",
                  "@type": "Risk",
                  "title": "Grid capacity risk",
                  "content": "Electricity constraints could delay factory utilization.",
                  "confidence": 0.57,
                  "derivedFrom": [
                    "factor:energy-cost-pressure",
                    "factor:shipbuilding-backlog"
                  ],
                  "mitigates": "factor:gx-investment-scenario"
                },
                {
                  "@id": "factor:skilled-labor-shortage",
                  "@type": "Risk",
                  "title": "Skilled labor shortage",
                  "content": "Retirement pressure creates bottlenecks in welding and controls work.",
                  "confidence": 0.69,
                  "derivedFrom": [
                    "factor:regional-labor-pool",
                    "evidence:vocational-pipeline"
                  ],
                  "supports": "question:export-demand-durability"
                },
                {
                  "@id": "question:export-demand-durability",
                  "@type": "Question",
                  "title": "Export demand durability",
                  "content": "Demand durability depends on overseas infrastructure spending.",
                  "confidence": 0.45,
                  "asksAbout": [
                    "factor:shipbuilding-backlog",
                    "factor:ev-supply-chain-shift"
                  ]
                },
                {
                  "@id": "factor:component-supply-volatility",
                  "@type": "Risk",
                  "title": "Component supply volatility",
                  "content": "Supplier concentration makes component availability unstable.",
                  "confidence": 0.62,
                  "derivedFrom": "factor:procurement-friction",
                  "supports": "factor:inventory-buffer-limit"
                },
                {
                  "@id": "factor:inventory-buffer-limit",
                  "@type": "Risk",
                  "title": "Inventory buffer limit",
                  "content": "Small suppliers cannot carry enough inventory to absorb shocks.",
                  "confidence": 0.55,
                  "derivedFrom": [
                    "factor:procurement-friction",
                    "factor:component-supply-volatility"
                  ],
                  "supports": "factor:regional-cluster-resilience"
                },
                {
                  "@id": "factor:gx-investment-scenario",
                  "@type": "Insight",
                  "title": "GX investment scenario",
                  "content": "Green transformation investment is attractive when grid risk is contained.",
                  "confidence": 0.67,
                  "derivedFrom": [
                    "factor:shipbuilding-backlog",
                    "evidence:capex-announcements",
                    "factor:grid-capacity-risk"
                  ],
                  "chartableData": "evidence:scenario-dashboard"
                },
                {
                  "@id": "factor:automation-upside",
                  "@type": "Insight",
                  "title": "Automation upside",
                  "content": "Automation offsets labor constraints and improves regional productivity.",
                  "confidence": 0.71,
                  "derivedFrom": [
                    "factor:regional-labor-pool",
                    "factor:ev-supply-chain-shift",
                    "factor:skilled-labor-shortage"
                  ],
                  "supports": "factor:regional-cluster-resilience"
                },
                {
                  "@id": "factor:regional-cluster-resilience",
                  "@type": "Insight",
                  "title": "Regional cluster resilience",
                  "content": "The cluster can stay resilient if supply volatility and grid limits are managed.",
                  "confidence": 0.65,
                  "derivedFrom": [
                    "factor:setouchi-industrial-base",
                    "factor:automation-upside",
                    "factor:inventory-buffer-limit"
                  ],
                  "chartableData": "evidence:scenario-dashboard"
                },
                {
                  "@id": "evidence:scenario-dashboard",
                  "@type": "Evidence",
                  "title": "Scenario dashboard",
                  "content": "Dashboard metrics connect investment, automation, and resilience outcomes.",
                  "confidence": 0.73,
                  "supports": [
                    "factor:gx-investment-scenario",
                    "factor:regional-cluster-resilience"
                  ]
                }
              ]
            }
            """#,
            isComplete: true
        ),
        renderer: JSONLDRenderer()
    )
    .artifactContentMaxHeight(nil)
    .frame(width: 1120, height: 760)
}

#Preview("Bare — malformed JSON-LD → error") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("jl2"),
            type: .jsonLD,
            attributes: ["base": "http://example.org/"],
            payload: #"""
            {
              "@context": { "name": "http://schema.org/name" },
              "@id": "http://example.org/alice",
              "name": "Alice
            """#,
            isComplete: true
        )
    )
    .artifactRenderer(JSONLDRenderer())
    .frame(width: 420, height: 360)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("jl3"),
        type: .jsonLD,
        title: "Streaming JSON-LD",
        attributes: ["base": "http://example.org/"],
        fullPayload: #"""
        {
          "@context": {
            "name": "http://schema.org/name",
            "knows": { "@id": "http://schema.org/knows", "@type": "@id" }
          },
          "@graph": [
            {"@id": "http://example.org/alice", "name": "Alice", "knows": "http://example.org/bob"},
            {"@id": "http://example.org/bob",   "name": "Bob",   "knows": "http://example.org/carol"},
            {"@id": "http://example.org/carol", "name": "Carol", "knows": "http://example.org/dave"},
            {"@id": "http://example.org/dave",  "name": "Dave"}
          ]
        }
        """#,
        chunkSize: 8,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(JSONLDRenderer())
    .frame(width: 520, height: 460)
}

// MARK: - Group previews
//
// JSON-LD is the only format whose parser populates `Node.types` from `@type`
// keys, so `.byType` is content-driven. Nested `@graph` blocks (a graph whose
// node has `@id` AND a `@graph` array) also produce NamedGraph entries, so
// `.namedGraphs` is content-driven too.

#Preview("Group — namedGraphs (nested @graph blocks)") {
    KnowledgeGraphView(
        graph: jsonLDPreviewGraph(
            #"""
            {
              "@graph": [
                {"@id": "http://example.org/engineering",
                 "@graph": [
                   {"@id": "http://example.org/alice",
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/bob"}},
                   {"@id": "http://example.org/bob",
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/carol"}}
                 ]},
                {"@id": "http://example.org/sales",
                 "@graph": [
                   {"@id": "http://example.org/dave",
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/eve"}},
                   {"@id": "http://example.org/eve",
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/frank"}}
                 ]},
                {"@id": "http://example.org/management",
                 "@graph": [
                   {"@id": "http://example.org/grace",
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/henry"}},
                   {"@id": "http://example.org/henry",
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/ivy"}}
                 ]}
              ]
            }
            """#,
            scope: "jsonld-group-namedGraphs-three"
        ),
        groupingStrategy: .namedGraphs()
    )
    .frame(width: 640, height: 480)
}

#Preview("Group — byType (three disjoint type buckets)") {
    KnowledgeGraphView(
        graph: jsonLDPreviewGraph(
            #"""
            {
              "@graph": [
                {"@id": "http://example.org/alice",
                 "@type": "http://xmlns.com/foaf/0.1/Person",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/bob"}},
                {"@id": "http://example.org/bob",
                 "@type": "http://xmlns.com/foaf/0.1/Person",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/carol"}},
                {"@id": "http://example.org/carol",
                 "@type": "http://xmlns.com/foaf/0.1/Person"},

                {"@id": "http://example.org/acme",
                 "@type": "http://example.org/Company"},
                {"@id": "http://example.org/globex",
                 "@type": "http://example.org/Company"},

                {"@id": "http://example.org/laptop",
                 "@type": "http://example.org/Device"},
                {"@id": "http://example.org/phone",
                 "@type": "http://example.org/Device"},

                {"@id": "http://example.org/alice",
                 "http://example.org/worksAt": {"@id": "http://example.org/acme"}},
                {"@id": "http://example.org/bob",
                 "http://example.org/worksAt": {"@id": "http://example.org/globex"}},
                {"@id": "http://example.org/carol",
                 "http://example.org/owns": {"@id": "http://example.org/laptop"}},
                {"@id": "http://example.org/bob",
                 "http://example.org/owns": {"@id": "http://example.org/phone"}}
              ]
            }
            """#,
            scope: "jsonld-group-byType-three"
        ),
        groupingStrategy: .byType()
    )
    .frame(width: 640, height: 480)
}

#Preview("Group — combined namedGraphs + byType") {
    KnowledgeGraphView(
        graph: jsonLDPreviewGraph(
            #"""
            {
              "@graph": [
                {"@id": "http://example.org/engineering",
                 "@graph": [
                   {"@id": "http://example.org/alice",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Engineer"],
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/bob"}},
                   {"@id": "http://example.org/bob",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Engineer"]}
                 ]},
                {"@id": "http://example.org/sales",
                 "@graph": [
                   {"@id": "http://example.org/carol",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Salesperson"],
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/dave"}},
                   {"@id": "http://example.org/dave",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Salesperson"]}
                 ]}
              ]
            }
            """#,
            scope: "jsonld-group-combined"
        ),
        groupingStrategy: .combined(strategies: [.namedGraphs(), .byType()])
    )
    .frame(width: 640, height: 480)
}

#Preview("Nested groups — content-driven (type ⊇ namedGraph)") {
    // The byType bucket `type:Person` covers all four people across both
    // named graphs, while `namedGraph:engineering` and `namedGraph:sales`
    // are 2-card subsets each. The Person bbox visibly contains the two
    // department bboxes, with the overlap region darkening per F7.
    KnowledgeGraphView(
        graph: jsonLDPreviewGraph(
            #"""
            {
              "@graph": [
                {"@id": "http://example.org/engineering",
                 "@graph": [
                   {"@id": "http://example.org/alice",
                    "@type": "http://xmlns.com/foaf/0.1/Person",
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/bob"}},
                   {"@id": "http://example.org/bob",
                    "@type": "http://xmlns.com/foaf/0.1/Person"}
                 ]},
                {"@id": "http://example.org/sales",
                 "@graph": [
                   {"@id": "http://example.org/carol",
                    "@type": "http://xmlns.com/foaf/0.1/Person",
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/dave"}},
                   {"@id": "http://example.org/dave",
                    "@type": "http://xmlns.com/foaf/0.1/Person"}
                 ]}
              ]
            }
            """#,
            scope: "jsonld-nested-content"
        ),
        groupingStrategy: .combined(strategies: [.byType(), .namedGraphs()])
    )
    .frame(width: 640, height: 480)
}

#Preview("Nested groups — .explicit (company ⊇ team ⊇ core)") {
    let alice = NodeIdentifier.iri("http://example.org/alice")
    let bob = NodeIdentifier.iri("http://example.org/bob")
    let carol = NodeIdentifier.iri("http://example.org/carol")
    let dave = NodeIdentifier.iri("http://example.org/dave")
    let eve = NodeIdentifier.iri("http://example.org/eve")
    return KnowledgeGraphView(
        graph: jsonLDPreviewGraph(
            #"""
            {
              "@graph": [
                {"@id": "http://example.org/alice",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/bob"}},
                {"@id": "http://example.org/bob",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/carol"}},
                {"@id": "http://example.org/carol",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/dave"}},
                {"@id": "http://example.org/dave",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/eve"}},
                {"@id": "http://example.org/eve",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/alice"}}
              ]
            }
            """#,
            scope: "jsonld-nested-explicit"
        ),
        groupingStrategy: .explicit(groups: [
            GroupingStrategy.ExplicitGroup(
                id: "company",
                label: "Company",
                memberNodeIDs: [alice, bob, carol, dave, eve]
            ),
            GroupingStrategy.ExplicitGroup(
                id: "engineering",
                label: "Engineering",
                memberNodeIDs: [alice, bob, carol]
            ),
            GroupingStrategy.ExplicitGroup(
                id: "core",
                label: "Core",
                memberNodeIDs: [alice, bob]
            )
        ])
    )
    .frame(width: 640, height: 480)
}

private func jsonLDPreviewGraph(
    _ payload: String,
    scope: String
) -> KnowledgeGraph {
    do {
        return try KnowledgeGraphFormat.jsonLD.parse(payload, scope: scope, baseIRI: nil)
    } catch {
        fatalError("JSON-LD preview parse failure (\(scope)): \(error)")
    }
}
