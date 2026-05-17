import Testing
import Foundation
import CoreGraphics
import KnowledgeGraph
@testable import ArtifactNativeRenderer

@Suite("CompoundGraph grouping")
struct CompoundGraphGroupTests {

    // MARK: - Helpers

    private static let alice = NodeIdentifier.iri("http://example/alice")
    private static let bob = NodeIdentifier.iri("http://example/bob")
    private static let carol = NodeIdentifier.iri("http://example/carol")
    private static let dave = NodeIdentifier.iri("http://example/dave")
    private static let person = "http://xmlns.com/foaf/0.1/Person"
    private static let employee = "http://example/Employee"

    private static let knows = "http://xmlns.com/foaf/0.1/knows"
    private static let rdfType = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

    private static func edge(
        from: NodeIdentifier,
        to: NodeIdentifier,
        predicate: String,
        namedGraph: String? = nil
    ) -> Edge {
        Edge(id: EdgeIdentifier(
            source: from,
            predicate: predicate,
            target: to,
            namedGraph: namedGraph
        ))
    }

    private static func cardID(_ id: NodeIdentifier) -> CompoundGraph.Card.ID {
        CompoundGraph.Card.ID(nodeID: id)
    }

    // MARK: - G.groupingStrategyNoneProducesNoGroups

    @Test
    func groupingStrategyNoneProducesNoGroups() {
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice),
                Node(id: Self.bob)
            ],
            edges: [
                Self.edge(from: Self.alice, to: Self.bob, predicate: Self.knows)
            ],
            namedGraphs: [
                NamedGraph(id: "g1", nodes: [Self.alice, Self.bob])
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .none)
        #expect(compound.groups.isEmpty)
        #expect(compound.groupByID.isEmpty)
        #expect(compound.groupsByCard.isEmpty)
    }

    // MARK: - G.namedGraphsStrategyProducesOneGroupPerNamedGraph

    @Test
    func namedGraphsStrategyProducesOneGroupPerNamedGraph() {
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice),
                Node(id: Self.bob),
                Node(id: Self.carol)
            ],
            edges: [
                Self.edge(from: Self.alice, to: Self.bob, predicate: Self.knows, namedGraph: "g1"),
                Self.edge(from: Self.carol, to: Self.carol, predicate: Self.knows, namedGraph: "g2")
            ],
            namedGraphs: [
                NamedGraph(id: "g1", label: "First", nodes: [Self.alice, Self.bob]),
                NamedGraph(id: "g2", label: "Second", nodes: [Self.carol])
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .namedGraphs())
        #expect(compound.groups.count == 2)
        let g1 = compound.groupByID[CompoundGraph.Group.ID(key: "namedGraph:g1")]
        let g2 = compound.groupByID[CompoundGraph.Group.ID(key: "namedGraph:g2")]
        #expect(g1?.label == "First")
        #expect(g2?.label == "Second")
        #expect(g1?.members.count == 2)
        #expect(g2?.members.count == 1)
    }

    @Test
    func labelOnlyNamedGraphResourceIsUsedAsGroupMetadataOnly() {
        let graphID = "http://example.org/layer/context"
        let graphNode = NodeIdentifier.iri(graphID)
        let graphLabel = NodeIdentifier.literal(value: "Context")
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: graphNode),
                Node(id: graphLabel),
                Node(id: Self.alice),
                Node(id: Self.bob)
            ],
            edges: [
                Self.edge(
                    from: graphNode,
                    to: graphLabel,
                    predicate: "https://schema.org/name"
                ),
                Self.edge(
                    from: Self.alice,
                    to: Self.bob,
                    predicate: Self.knows,
                    namedGraph: graphID
                )
            ],
            namedGraphs: [
                NamedGraph(id: graphID, nodes: [Self.alice, Self.bob])
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .namedGraphs())

        #expect(compound.cards.map(\.id.nodeID).contains(graphNode) == false)
        #expect(compound.cards.map(\.id.nodeID).contains(graphLabel) == false)
        #expect(compound.groups.count == 1)
        #expect(compound.groups.first?.label == "Context")
        #expect(compound.groups.first?.members.count == 2)
    }

    @Test
    func literalPropertiesAndClassAssertionsDoNotBecomeCardsOrEdges() {
        let evidence = NodeIdentifier.iri("http://example/Evidence")
        let verified = NodeIdentifier.literal(value: "Verified")
        let status = "http://example/epistemicStatus"
        let supports = "http://example/supports"
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice, types: ["http://example/Evidence"]),
                Node(id: Self.bob, types: ["http://example/Evidence"]),
                Node(id: evidence),
                Node(id: verified)
            ],
            edges: [
                Self.edge(from: Self.alice, to: evidence, predicate: Self.rdfType),
                Self.edge(from: Self.bob, to: evidence, predicate: Self.rdfType),
                Self.edge(from: Self.alice, to: verified, predicate: status),
                Self.edge(from: Self.bob, to: verified, predicate: status),
                Self.edge(from: Self.alice, to: Self.bob, predicate: supports)
            ]
        )

        let compound = CompoundGraph.decompose(graph, groupingStrategy: .none)
        let cardIDs = Set(compound.cards.map(\.id.nodeID))

        #expect(cardIDs == [Self.alice, Self.bob])
        #expect(compound.edges.count == 1)
        #expect(compound.edges.first?.predicate == "supports")
        #expect(compound.cardByID[Self.cardID(Self.alice)]?.attributes.count == 1)
        #expect(compound.cardByID[Self.cardID(Self.bob)]?.attributes.count == 1)
        #expect(compound.cardByID[Self.cardID(Self.alice)]?.attributes.first?.value == "Verified")
        #expect(compound.cardByID[Self.cardID(Self.bob)]?.attributes.first?.value == "Verified")
    }

    @Test
    func nestedNamedGraphsRenderLayerAsSupersetOfCategoryGroups() {
        let layerID = "http://example.org/layer/context"
        let categoryOneID = "http://example.org/category/context/market"
        let categoryTwoID = "http://example.org/category/context/demand"
        let layerNode = NodeIdentifier.iri(layerID)
        let categoryOneNode = NodeIdentifier.iri(categoryOneID)
        let categoryTwoNode = NodeIdentifier.iri(categoryTwoID)
        let layerLabel = NodeIdentifier.literal(value: "Context")
        let categoryOneLabel = NodeIdentifier.literal(value: "Market")
        let categoryTwoLabel = NodeIdentifier.literal(value: "Demand")
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: layerNode),
                Node(id: categoryOneNode),
                Node(id: categoryTwoNode),
                Node(id: layerLabel),
                Node(id: categoryOneLabel),
                Node(id: categoryTwoLabel),
                Node(id: Self.alice),
                Node(id: Self.bob),
                Node(id: Self.carol),
                Node(id: Self.dave)
            ],
            edges: [
                Self.edge(
                    from: layerNode,
                    to: layerLabel,
                    predicate: "https://schema.org/name"
                ),
                Self.edge(
                    from: categoryOneNode,
                    to: categoryOneLabel,
                    predicate: "https://schema.org/name",
                    namedGraph: layerID
                ),
                Self.edge(
                    from: categoryTwoNode,
                    to: categoryTwoLabel,
                    predicate: "https://schema.org/name",
                    namedGraph: layerID
                ),
                Self.edge(
                    from: Self.alice,
                    to: Self.bob,
                    predicate: Self.knows,
                    namedGraph: categoryOneID
                ),
                Self.edge(
                    from: Self.carol,
                    to: Self.dave,
                    predicate: Self.knows,
                    namedGraph: categoryTwoID
                )
            ],
            namedGraphs: [
                NamedGraph(id: layerID),
                NamedGraph(id: categoryOneID),
                NamedGraph(id: categoryTwoID)
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .namedGraphs())

        #expect(compound.cards.map(\.id.nodeID).contains(layerNode) == false)
        #expect(compound.cards.map(\.id.nodeID).contains(categoryOneNode) == false)
        #expect(compound.cards.map(\.id.nodeID).contains(categoryTwoNode) == false)
        let layer = compound.groupByID[CompoundGraph.Group.ID(key: "namedGraph:\(layerID)")]
        let categoryOne = compound.groupByID[CompoundGraph.Group.ID(key: "namedGraph:\(categoryOneID)")]
        let categoryTwo = compound.groupByID[CompoundGraph.Group.ID(key: "namedGraph:\(categoryTwoID)")]
        #expect(layer?.label == "Context")
        #expect(categoryOne?.label == "Market")
        #expect(categoryTwo?.label == "Demand")
        #expect(Set(layer?.members ?? []) == [
            Self.cardID(Self.alice),
            Self.cardID(Self.bob),
            Self.cardID(Self.carol),
            Self.cardID(Self.dave)
        ])
        #expect(Set(categoryOne?.members ?? []) == [
            Self.cardID(Self.alice),
            Self.cardID(Self.bob)
        ])
        #expect(Set(categoryTwo?.members ?? []) == [
            Self.cardID(Self.carol),
            Self.cardID(Self.dave)
        ])
    }

    @Test
    func jsonLDViewGroupsUseTitlesAndNestLayerCategoryMembership() {
        let payload = #"""
        {
          "@context": {
            "ex": "http://example.org/"
          },
          "view": {
            "groups": [
              {
                "id": "group:layer/context",
                "kind": "layer",
                "title": "Context",
                "children": [
                  {
                    "id": "group:category/context/market",
                    "kind": "category",
                    "title": "Market",
                    "members": ["ex:alice", "ex:bob"]
                  },
                  {
                    "id": "group:category/context/demand",
                    "kind": "category",
                    "title": "Demand",
                    "members": ["ex:carol"]
                  }
                ]
              }
            ]
          },
          "@graph": []
        }
        """#
        let groups = JSONLDViewGroupExtractor.explicitGroups(from: payload)

        #expect(groups?.count == 3)
        #expect(groups?[0].id == "group:layer/context")
        #expect(groups?[0].label == "Context")
        #expect(groups?[0].memberNodeIDs == [
            NodeIdentifier.iri("http://example.org/alice"),
            NodeIdentifier.iri("http://example.org/bob"),
            NodeIdentifier.iri("http://example.org/carol")
        ])
        #expect(groups?[1].id == "group:category/context/market")
        #expect(groups?[1].label == "Market")
        #expect(groups?[1].memberNodeIDs == [
            NodeIdentifier.iri("http://example.org/alice"),
            NodeIdentifier.iri("http://example.org/bob")
        ])
        #expect(groups?[2].id == "group:category/context/demand")
        #expect(groups?[2].label == "Demand")
        #expect(groups?[2].memberNodeIDs == [
            NodeIdentifier.iri("http://example.org/carol")
        ])
    }

    // MARK: - G.emptyGroupsAreFilteredAfterLiteralFolding

    @Test
    func emptyGroupsAreFilteredAfterLiteralFolding() {
        // A named graph whose only members are leaf literals (i.e. literals
        // with a single distinct subject) gets folded away during decompose,
        // so the resulting group has zero surviving members and must be
        // dropped from `groups`.
        let literal = NodeIdentifier.literal(value: "Alice")
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice),
                Node(id: literal)
            ],
            edges: [
                Self.edge(
                    from: Self.alice,
                    to: literal,
                    predicate: "http://xmlns.com/foaf/0.1/name",
                    namedGraph: "literals"
                )
            ],
            namedGraphs: [
                NamedGraph(id: "literals", nodes: [literal])
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .namedGraphs())
        #expect(compound.groups.isEmpty)
    }

    // MARK: - G.byTypeStrategyGroupsByRdfType

    @Test
    func byTypeStrategyGroupsByRdfType() {
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice, types: [Self.person]),
                Node(id: Self.bob, types: [Self.person]),
                Node(id: Self.carol, types: [Self.employee])
            ],
            namespaces: [
                Namespace(prefix: "foaf", uri: "http://xmlns.com/foaf/0.1/")
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .byType())
        let typeKeys = compound.groups.map { $0.id.key }
        #expect(typeKeys.contains("type:\(Self.person)"))
        #expect(typeKeys.contains("type:\(Self.employee)"))
        let person = compound.groupByID[CompoundGraph.Group.ID(key: "type:\(Self.person)")]
        #expect(person?.members.count == 2)
        let employee = compound.groupByID[CompoundGraph.Group.ID(key: "type:\(Self.employee)")]
        #expect(employee?.members.count == 1)
        // Label uses the foaf prefix when the IRI matches a declared namespace.
        #expect(person?.label == "foaf:Person")
    }

    // MARK: - G.byTypeAllowsMultipleMembershipForMultiTypedNode

    @Test
    func byTypeAllowsMultipleMembershipForMultiTypedNode() {
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice, types: [Self.person, Self.employee])
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .byType())
        let aliceCard = Self.cardID(Self.alice)
        let memberships = compound.groupsByCard[aliceCard] ?? []
        #expect(memberships.count == 2)
        #expect(memberships.contains(CompoundGraph.Group.ID(key: "type:\(Self.person)")))
        #expect(memberships.contains(CompoundGraph.Group.ID(key: "type:\(Self.employee)")))
    }

    // MARK: - G.byNamespaceStrategyGroupsByIriPrefix

    @Test
    func byNamespaceStrategyGroupsByIriPrefix() {
        let foaf = "http://xmlns.com/foaf/0.1/"
        let alice = NodeIdentifier.iri("\(foaf)alice")
        let bob = NodeIdentifier.iri("\(foaf)bob")
        let graph = KnowledgeGraph(
            nodes: [Node(id: alice), Node(id: bob)],
            namespaces: [Namespace(prefix: "foaf", uri: foaf)]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .byNamespace())
        #expect(compound.groups.count == 1)
        let group = compound.groups[0]
        #expect(group.id.key == "namespace:foaf")
        #expect(group.label == "foaf")
        #expect(group.members.count == 2)
    }

    // MARK: - G.byNamespaceUsesLongestPrefixMatch

    @Test
    func byNamespaceUsesLongestPrefixMatch() {
        // Two namespaces share a common stem; the longer URI must win for
        // every node whose IRI matches it.
        let short = "http://example/"
        let long = "http://example/api/"
        let general = NodeIdentifier.iri("\(short)thing")
        let apiNode = NodeIdentifier.iri("\(long)resource")
        let graph = KnowledgeGraph(
            nodes: [Node(id: general), Node(id: apiNode)],
            namespaces: [
                Namespace(prefix: "ex", uri: short),
                Namespace(prefix: "exApi", uri: long)
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .byNamespace())
        let ex = compound.groupByID[CompoundGraph.Group.ID(key: "namespace:ex")]
        let exApi = compound.groupByID[CompoundGraph.Group.ID(key: "namespace:exApi")]
        #expect(ex?.members == [Self.cardID(general)])
        #expect(exApi?.members == [Self.cardID(apiNode)])
    }

    // MARK: - G.explicitStrategyFiltersInvalidCardIDs

    @Test
    func explicitStrategyFiltersInvalidCardIDs() {
        let phantom = NodeIdentifier.iri("http://example/missing")
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice),
                Node(id: Self.bob)
            ]
        )
        let strategy: GroupingStrategy = .explicit(groups: [
            GroupingStrategy.ExplicitGroup(
                id: "team",
                label: "team",
                memberNodeIDs: [Self.alice, phantom, Self.bob]
            ),
            GroupingStrategy.ExplicitGroup(
                id: "phantom-only",
                label: "phantom-only",
                memberNodeIDs: [phantom]
            )
        ])
        let compound = CompoundGraph.decompose(graph, groupingStrategy: strategy)
        // phantom-only is dropped because all its IDs are invalid; team
        // survives with the two valid members.
        #expect(compound.groups.count == 1)
        let team = compound.groups[0]
        #expect(team.label == "team")
        #expect(team.members == [Self.cardID(Self.alice), Self.cardID(Self.bob)])
    }

    // MARK: - G.combinedStrategyDeduplicatesByLabelAndMembers

    @Test
    func combinedStrategyDeduplicatesByLabelAndMembers() {
        // The explicit "Person" group shares its (label, sorted members) tuple
        // with the byType group derived from foaf:Person — combined must dedup.
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice, types: ["foaf:Person"]),
                Node(id: Self.bob, types: ["foaf:Person"])
            ]
        )
        let strategy: GroupingStrategy = .combined(strategies: [
            .explicit(groups: [
                GroupingStrategy.ExplicitGroup(
                    id: "foaf-person",
                    label: "foaf:Person",
                    memberNodeIDs: [Self.alice, Self.bob]
                )
            ]),
            .byType()
        ])
        let compound = CompoundGraph.decompose(graph, groupingStrategy: strategy)
        // Only the explicit group survives because it's seen first; the
        // byType-derived duplicate is dropped by `(label, sortedMembers)`.
        #expect(compound.groups.count == 1)
        #expect(compound.groups[0].id.key == "explicit:foaf-person")
    }

    // MARK: - G.groupIDsArePrefixedPerStrategyToAvoidCollision

    @Test
    func groupIDsArePrefixedPerStrategyToAvoidCollision() {
        // A named graph and an rdf:type that happen to share the same IRI
        // must produce distinct Group.IDs thanks to the strategy prefix.
        let sharedIRI = "http://example/Shared"
        let graph = KnowledgeGraph(
            nodes: [Node(id: Self.alice, types: [sharedIRI])],
            namedGraphs: [NamedGraph(id: sharedIRI, nodes: [Self.alice])]
        )
        let strategy: GroupingStrategy = .combined(strategies: [.namedGraphs(), .byType()])
        let compound = CompoundGraph.decompose(graph, groupingStrategy: strategy)
        let keys = Set(compound.groups.map { $0.id.key })
        #expect(keys.contains("namedGraph:\(sharedIRI)"))
        #expect(keys.contains("type:\(sharedIRI)"))
        #expect(keys.count == 2)
    }

    // MARK: - G.groupsByCardIsReverseMapOfGroupMembers

    @Test
    func groupsByCardIsReverseMapOfGroupMembers() {
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice, types: [Self.person]),
                Node(id: Self.bob, types: [Self.person, Self.employee])
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .byType())
        for group in compound.groups {
            for member in group.members {
                let reverse = compound.groupsByCard[member] ?? []
                #expect(reverse.contains(group.id))
            }
        }
    }

    // MARK: - G.groupsByCardIsAbsentForUnassignedCards

    @Test
    func groupsByCardIsAbsentForUnassignedCards() {
        // Carol carries no type — she belongs to no .byType group.
        // `groupsByCard[carol]` must be nil, not an empty array.
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice, types: [Self.person]),
                Node(id: Self.carol)
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .byType())
        #expect(compound.groupsByCard[Self.cardID(Self.carol)] == nil)
    }

    // MARK: - C3 invariant

    @Test
    func everyGroupHasAtLeastOneMember() {
        let graph = KnowledgeGraph(
            nodes: [Node(id: Self.alice, types: [Self.person])]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .byType())
        #expect(compound.groups.allSatisfy { !$0.members.isEmpty })
    }

    // MARK: - Edge cases

    @Test
    func emptyGraphProducesNoGroupsForEveryStrategy() {
        // No nodes, no edges, no namespaces, no named graphs — every strategy
        // must produce zero groups without crashing or emitting placeholders.
        let empty = KnowledgeGraph()
        for strategy: GroupingStrategy in [
            .none,
            .namedGraphs(),
            .byType(),
            .byNamespace(),
            .explicit(groups: []),
            .combined(strategies: [.namedGraphs(), .byType()])
        ] {
            let compound = CompoundGraph.decompose(empty, groupingStrategy: strategy)
            #expect(compound.groups.isEmpty)
            #expect(compound.groupByID.isEmpty)
            #expect(compound.groupsByCard.isEmpty)
        }
    }

    @Test
    func combinedStrategyWithEmptyListProducesNoGroups() {
        // .combined(strategies: []) is a no-op — equivalent to .none.
        let graph = KnowledgeGraph(
            nodes: [Node(id: Self.alice, types: [Self.person])],
            namedGraphs: [NamedGraph(id: "g1", nodes: [Self.alice])]
        )
        let compound = CompoundGraph.decompose(
            graph,
            groupingStrategy: .combined(strategies: [])
        )
        #expect(compound.groups.isEmpty)
    }

    @Test
    func nestedCombinedStrategyFlattens() {
        // .combined nested inside .combined must produce the same union as a
        // single-level .combined with both sub-strategies.
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice, types: [Self.person]),
                Node(id: Self.bob, types: [Self.employee])
            ],
            namedGraphs: [
                NamedGraph(id: "team", nodes: [Self.alice, Self.bob])
            ]
        )
        let nested: GroupingStrategy = .combined(strategies: [
            .combined(strategies: [.namedGraphs(), .byType()])
        ])
        let flat: GroupingStrategy = .combined(strategies: [
            .namedGraphs(),
            .byType()
        ])
        let nestedKeys = Set(
            CompoundGraph.decompose(graph, groupingStrategy: nested)
                .groups
                .map { $0.id.key }
        )
        let flatKeys = Set(
            CompoundGraph.decompose(graph, groupingStrategy: flat)
                .groups
                .map { $0.id.key }
        )
        #expect(nestedKeys == flatKeys)
        #expect(nestedKeys.contains("namedGraph:team"))
        #expect(nestedKeys.contains("type:\(Self.person)"))
        #expect(nestedKeys.contains("type:\(Self.employee)"))
    }

    @Test
    func byNamespaceSkipsNodesWithUnmatchedIRI() {
        // A node whose IRI matches no declared namespace must not appear in
        // any namespace group. `byNamespace` is a strict prefix filter — it
        // does not invent groups for orphaned IRIs.
        let foaf = "http://xmlns.com/foaf/0.1/"
        let alice = NodeIdentifier.iri("\(foaf)alice")
        let orphan = NodeIdentifier.iri("urn:isbn:0451524934")
        let graph = KnowledgeGraph(
            nodes: [Node(id: alice), Node(id: orphan)],
            namespaces: [Namespace(prefix: "foaf", uri: foaf)]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .byNamespace())
        #expect(compound.groups.count == 1)
        #expect(compound.groups[0].members == [Self.cardID(alice)])
        #expect(compound.groupsByCard[Self.cardID(orphan)] == nil)
    }

    @Test
    func byTypeIgnoresNodesWithEmptyTypesArray() {
        // A node with `types: []` is not a group member. The strategy reads
        // `Node.types` verbatim — no inference, no fallback to "rdfs:Resource".
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice, types: [Self.person]),
                Node(id: Self.bob, types: [])
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .byType())
        #expect(compound.groups.count == 1)
        #expect(compound.groups[0].members == [Self.cardID(Self.alice)])
        #expect(compound.groupsByCard[Self.cardID(Self.bob)] == nil)
    }

    @Test
    func explicitGroupSupportsDistinctIDsWithIdenticalColonLabels() {
        // Labels are display-only; collisions are resolved by `id`. Two groups
        // can share a colon-containing label so long as their ids differ.
        let graph = KnowledgeGraph(
            nodes: [Node(id: Self.alice), Node(id: Self.bob)]
        )
        let strategy: GroupingStrategy = .explicit(groups: [
            GroupingStrategy.ExplicitGroup(
                id: "team-a",
                label: "ex:Team",
                memberNodeIDs: [Self.alice]
            ),
            GroupingStrategy.ExplicitGroup(
                id: "team-b",
                label: "ex:Team",
                memberNodeIDs: [Self.bob]
            )
        ])
        let compound = CompoundGraph.decompose(graph, groupingStrategy: strategy)
        #expect(compound.groups.count == 2)
        let keys = Set(compound.groups.map { $0.id.key })
        #expect(keys == ["explicit:team-a", "explicit:team-b"])
    }

    @Test
    func groupsByCardAndMembersAreBidirectionalInverses() {
        // For every Card.ID `c` and Group.ID `g`:
        //   c ∈ group(g).members  ⇔  g ∈ groupsByCard[c]
        // The reverse map must agree with the forward map in both directions.
        let graph = KnowledgeGraph(
            nodes: [
                Node(id: Self.alice, types: [Self.person, Self.employee]),
                Node(id: Self.bob, types: [Self.person]),
                Node(id: Self.carol)
            ]
        )
        let compound = CompoundGraph.decompose(graph, groupingStrategy: .byType())
        // Forward: every member appears in groupsByCard.
        for group in compound.groups {
            for member in group.members {
                #expect(compound.groupsByCard[member]?.contains(group.id) == true)
            }
        }
        // Reverse: every (card, group) entry has the card in the group.
        for (cardID, groupIDs) in compound.groupsByCard {
            for groupID in groupIDs {
                let group = compound.groupByID[groupID]
                #expect(group?.members.contains(cardID) == true)
            }
        }
    }
}
