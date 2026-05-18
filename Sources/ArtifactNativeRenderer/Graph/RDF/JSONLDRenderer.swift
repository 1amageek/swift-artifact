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
