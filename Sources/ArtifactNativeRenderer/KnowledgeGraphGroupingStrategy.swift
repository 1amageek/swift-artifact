import Foundation
import CoreGraphics
import KnowledgeGraph

/// How a `CompoundGraph` should be partitioned into visual groups.
///
/// Strategies are pure functions of the input `KnowledgeGraph` plus the
/// already-decomposed cards — they never mutate triples and they never
/// invent edges. RDF semantics are preserved: `.byType` reads exactly the
/// `Node.types` array the parser populated and performs no inference,
/// `.byNamespace` does literal longest-prefix matching against
/// `graph.namespaces`, and `.namedGraphs` reads `graph.namedGraphs` as a
/// labelled view of pre-existing node memberships.
enum GroupingStrategy: Sendable, Hashable {

    /// No groups. Renderer skips group drawing entirely.
    case none

    /// One group per non-empty `KnowledgeGraph.namedGraphs` entry. Empty
    /// after literal folding ⇒ filtered out.
    case namedGraphs(
        cohesionStrength: Double = 0.05,
        style: GroupStyle = .default
    )

    /// One group per distinct `rdf:type` IRI present on any node. Multi-typed
    /// nodes belong to every matching group.
    case byType(
        cohesionStrength: Double = 0.05,
        style: GroupStyle = .default
    )

    /// One group per declared namespace prefix in `graph.namespaces`. Nodes
    /// are matched by **longest prefix**; ties are broken by URI string
    /// ordering for determinism.
    case byNamespace(
        cohesionStrength: Double = 0.05,
        style: GroupStyle = .default
    )

    /// Caller-supplied label / member-list pairs. Invalid card IDs are
    /// silently filtered. Empty groups after filtering are dropped.
    case explicit(
        groups: [ExplicitGroup],
        cohesionStrength: Double = 0.05,
        style: GroupStyle = .default
    )

    /// Union of several strategies. Groups with identical `(label, sorted
    /// members)` tuples are deduplicated so e.g. a named graph whose members
    /// match a single `rdf:type` does not render twice.
    indirect case combined(
        strategies: [GroupingStrategy]
    )

    /// One entry in a `.explicit` strategy. `id` must be unique within the
    /// `.explicit` strategy's group list — it is the second half of the
    /// rendered group's stable ID. `label` is the human-facing text and need
    /// not be unique (e.g. two groups can both be labelled "team" as long as
    /// their `id`s differ).
    struct ExplicitGroup: Sendable, Hashable {
        let id: String
        let label: String
        let memberNodeIDs: [NodeIdentifier]

        init(id: String, label: String, memberNodeIDs: [NodeIdentifier]) {
            self.id = id
            self.label = label
            self.memberNodeIDs = memberNodeIDs
        }
    }

}

// MARK: - Group derivation

extension GroupingStrategy {

    /// Compute the groups this strategy produces for the given graph and
    /// already-decomposed card set. Empty groups (after filtering members
    /// that did not survive literal folding) are dropped.
    ///
    /// - Parameters:
    ///   - graph: The source `KnowledgeGraph`. Read-only; never mutated.
    ///   - cardIDsByNodeID: Maps each surviving card's underlying node id
    ///     to its `Card.ID`. Used to filter members that were folded away
    ///     during decomposition.
    /// - Returns: Deterministically ordered groups with non-empty members.
    func deriveGroups(
        graph: KnowledgeGraph,
        cardIDsByNodeID: [NodeIdentifier: CompoundGraph.Card.ID]
    ) -> [CompoundGraph.Group] {
        switch self {
        case .none:
            return []

        case .namedGraphs(let strength, let style):
            return deriveNamedGraphs(
                graph: graph,
                cardIDsByNodeID: cardIDsByNodeID,
                cohesionStrength: strength,
                style: style
            )

        case .byType(let strength, let style):
            return deriveByType(
                graph: graph,
                cardIDsByNodeID: cardIDsByNodeID,
                cohesionStrength: strength,
                style: style
            )

        case .byNamespace(let strength, let style):
            return deriveByNamespace(
                graph: graph,
                cardIDsByNodeID: cardIDsByNodeID,
                cohesionStrength: strength,
                style: style
            )

        case .explicit(let groups, let strength, let style):
            return deriveExplicit(
                explicitGroups: groups,
                cardIDsByNodeID: cardIDsByNodeID,
                cohesionStrength: strength,
                style: style
            )

        case .combined(let strategies):
            return deriveCombined(
                strategies: strategies,
                graph: graph,
                cardIDsByNodeID: cardIDsByNodeID
            )
        }
    }

    // MARK: - byType

    private func deriveByType(
        graph: KnowledgeGraph,
        cardIDsByNodeID: [NodeIdentifier: CompoundGraph.Card.ID],
        cohesionStrength: Double,
        style: GroupStyle
    ) -> [CompoundGraph.Group] {
        // Collect (type IRI, card IDs in stable order) preserving the order in
        // which each type is first seen across `graph.nodes`. No `rdfs:Class`
        // inference — we read `Node.types` verbatim, which is exactly what
        // the parser populated from `rdf:type` predicates.
        var orderedTypes: [String] = []
        var membersByType: [String: [CompoundGraph.Card.ID]] = [:]
        var seenByType: [String: Set<CompoundGraph.Card.ID>] = [:]
        for node in graph.nodes {
            guard let cardID = cardIDsByNodeID[node.id] else { continue }
            for type in node.types where !type.isEmpty {
                if membersByType[type] == nil {
                    orderedTypes.append(type)
                    membersByType[type] = []
                    seenByType[type] = []
                }
                if seenByType[type]!.insert(cardID).inserted {
                    membersByType[type]!.append(cardID)
                }
            }
        }
        var result: [CompoundGraph.Group] = []
        result.reserveCapacity(orderedTypes.count)
        for type in orderedTypes {
            let members = membersByType[type] ?? []
            guard !members.isEmpty else { continue }
            result.append(CompoundGraph.Group(
                id: CompoundGraph.Group.ID(key: "type:\(type)"),
                label: typeLabel(for: type, namespaces: graph.namespaces),
                members: members,
                style: style,
                cohesionStrength: cohesionStrength
            ))
        }
        return result
    }

    private func typeLabel(for type: String, namespaces: [Namespace]) -> String {
        for namespace in namespaces where !namespace.uri.isEmpty {
            if type.hasPrefix(namespace.uri) {
                let local = type.dropFirst(namespace.uri.count)
                guard !local.isEmpty else { continue }
                return "\(namespace.prefix):\(local)"
            }
        }
        if let hash = type.range(of: "#", options: .backwards) {
            return String(type[hash.upperBound...])
        }
        if let slash = type.range(of: "/", options: .backwards) {
            return String(type[slash.upperBound...])
        }
        return type
    }

    // MARK: - byNamespace

    private func deriveByNamespace(
        graph: KnowledgeGraph,
        cardIDsByNodeID: [NodeIdentifier: CompoundGraph.Card.ID],
        cohesionStrength: Double,
        style: GroupStyle
    ) -> [CompoundGraph.Group] {
        // Sort prefixes by URI length descending so longest-prefix wins. Ties
        // are broken by URI string ordering, which keeps the resolution
        // deterministic without relying on namespace declaration order.
        let candidates = graph.namespaces
            .filter { !$0.uri.isEmpty }
            .sorted { lhs, rhs in
                if lhs.uri.count != rhs.uri.count {
                    return lhs.uri.count > rhs.uri.count
                }
                return lhs.uri < rhs.uri
            }
        var orderedPrefixes: [String] = []
        var membersByPrefix: [String: [CompoundGraph.Card.ID]] = [:]
        var seenByPrefix: [String: Set<CompoundGraph.Card.ID>] = [:]
        var labelByPrefix: [String: String] = [:]
        for node in graph.nodes where node.id.kind == .iri {
            guard let cardID = cardIDsByNodeID[node.id] else { continue }
            for namespace in candidates where node.id.key.hasPrefix(namespace.uri) {
                let key = namespace.prefix
                if membersByPrefix[key] == nil {
                    orderedPrefixes.append(key)
                    membersByPrefix[key] = []
                    seenByPrefix[key] = []
                    labelByPrefix[key] = namespace.prefix.isEmpty
                        ? namespace.uri
                        : namespace.prefix
                }
                if seenByPrefix[key]!.insert(cardID).inserted {
                    membersByPrefix[key]!.append(cardID)
                }
                break // longest-prefix wins; first match in sorted order
            }
        }
        var result: [CompoundGraph.Group] = []
        result.reserveCapacity(orderedPrefixes.count)
        for prefix in orderedPrefixes {
            let members = membersByPrefix[prefix] ?? []
            guard !members.isEmpty else { continue }
            result.append(CompoundGraph.Group(
                id: CompoundGraph.Group.ID(key: "namespace:\(prefix)"),
                label: labelByPrefix[prefix] ?? prefix,
                members: members,
                style: style,
                cohesionStrength: cohesionStrength
            ))
        }
        return result
    }

    // MARK: - explicit

    private func deriveExplicit(
        explicitGroups: [ExplicitGroup],
        cardIDsByNodeID: [NodeIdentifier: CompoundGraph.Card.ID],
        cohesionStrength: Double,
        style: GroupStyle
    ) -> [CompoundGraph.Group] {
        // Detect duplicate explicit ids early — two `ExplicitGroup`s with the
        // same `id` would collapse onto the same `Group.ID`, which silently
        // drops the second group's bbox and members from the renderer.
        var seenIDs: Set<String> = []
        seenIDs.reserveCapacity(explicitGroups.count)
        for group in explicitGroups {
            precondition(
                seenIDs.insert(group.id).inserted,
                "ExplicitGroup id \"\(group.id)\" appears more than once"
            )
        }
        // Node IDs that do not resolve to a surviving card are dropped — the
        // .explicit strategy is the only one whose source is caller-supplied,
        // and we don't want a single stale node id (typo, or a node that the
        // decomposer folded into a literal) to invalidate an otherwise good
        // config. The internal strategies (.byType, .byNamespace, .namedGraphs)
        // do the same `cardIDsByNodeID` lookup with `continue` — there it is
        // the *expected* path for nodes that survive decomposition as literals
        // rather than as standalone subjects.
        var result: [CompoundGraph.Group] = []
        result.reserveCapacity(explicitGroups.count)
        for group in explicitGroups {
            var seen: Set<CompoundGraph.Card.ID> = []
            var members: [CompoundGraph.Card.ID] = []
            members.reserveCapacity(group.memberNodeIDs.count)
            for nodeID in group.memberNodeIDs {
                guard let cardID = cardIDsByNodeID[nodeID] else { continue }
                if seen.insert(cardID).inserted {
                    members.append(cardID)
                }
            }
            guard !members.isEmpty else { continue }
            result.append(CompoundGraph.Group(
                id: CompoundGraph.Group.ID(key: "explicit:\(group.id)"),
                label: group.label,
                members: members,
                style: style,
                cohesionStrength: cohesionStrength
            ))
        }
        return result
    }

    // MARK: - combined

    private func deriveCombined(
        strategies: [GroupingStrategy],
        graph: KnowledgeGraph,
        cardIDsByNodeID: [NodeIdentifier: CompoundGraph.Card.ID]
    ) -> [CompoundGraph.Group] {
        // Union of sub-strategy outputs, with `(label, sortedMembers)`
        // deduplication. The first seen instance wins so e.g. a named graph
        // listed before its rdf:type-equivalent keeps the `namedGraph:` id.
        var result: [CompoundGraph.Group] = []
        var seen: Set<DedupKey> = []
        for strategy in strategies {
            let derived = strategy.deriveGroups(
                graph: graph,
                cardIDsByNodeID: cardIDsByNodeID
            )
            for group in derived where !group.members.isEmpty {
                let sorted = group.members
                    .map { $0.nodeID.key }
                    .sorted()
                let key = DedupKey(label: group.label, sortedMemberKeys: sorted)
                if seen.insert(key).inserted {
                    result.append(group)
                }
            }
        }
        return result
    }

    private struct DedupKey: Hashable {
        let label: String
        let sortedMemberKeys: [String]
    }

    // MARK: - namedGraphs

    private func deriveNamedGraphs(
        graph: KnowledgeGraph,
        cardIDsByNodeID: [NodeIdentifier: CompoundGraph.Card.ID],
        cohesionStrength: Double,
        style: GroupStyle
    ) -> [CompoundGraph.Group] {
        // Membership sources, in priority order:
        // 1. `named.nodes` — explicit, set by callers that build graphs by hand
        //    or by parsers that materialise membership eagerly.
        // 2. Edges whose `id.namedGraph == named.id` — needed because the
        //    TriG / N-Quads / JSON-LD parsers in swift-knowledge-graph populate
        //    only `Edge.namedGraph`, not `NamedGraph.nodes`. Walking edges
        //    re-derives membership without reinterpreting Named Graph semantics
        //    (each edge already carries the graph attribution from parse time).
        let edgeMembersByGraphID = membersByNamedGraphFromEdges(graph: graph)
        let baseMembersByGraphID = baseMembersByNamedGraph(
            graph: graph,
            edgeMembersByGraphID: edgeMembersByGraphID
        )
        var result: [CompoundGraph.Group] = []
        result.reserveCapacity(graph.namedGraphs.count)
        for named in graph.namedGraphs {
            var seen: Set<CompoundGraph.Card.ID> = []
            var members: [CompoundGraph.Card.ID] = []
            let nodeIDs = expandedMembers(
                for: named.id,
                baseMembersByGraphID: baseMembersByGraphID,
                expanding: []
            )
            members.reserveCapacity(nodeIDs.count)
            for nodeID in nodeIDs {
                guard let cardID = cardIDsByNodeID[nodeID] else { continue }
                if seen.insert(cardID).inserted {
                    members.append(cardID)
                }
            }
            guard !members.isEmpty else { continue }
            let label = namedGraphLabel(for: named, in: graph) ?? named.id
            result.append(CompoundGraph.Group(
                id: CompoundGraph.Group.ID(key: "namedGraph:\(named.id)"),
                label: label,
                members: members,
                style: style,
                cohesionStrength: cohesionStrength
            ))
        }
        return result
    }

    private func baseMembersByNamedGraph(
        graph: KnowledgeGraph,
        edgeMembersByGraphID: [String: [NodeIdentifier]]
    ) -> [String: [NodeIdentifier]] {
        var result: [String: [NodeIdentifier]] = [:]
        result.reserveCapacity(graph.namedGraphs.count)
        for named in graph.namedGraphs {
            result[named.id] = named.nodes.isEmpty
                ? (edgeMembersByGraphID[named.id] ?? [])
                : named.nodes
        }
        return result
    }

    private func expandedMembers(
        for graphID: String,
        baseMembersByGraphID: [String: [NodeIdentifier]],
        expanding: Set<String>
    ) -> [NodeIdentifier] {
        guard !expanding.contains(graphID) else { return [] }
        let nextExpanding = expanding.union([graphID])
        let baseMembers = baseMembersByGraphID[graphID] ?? []
        var result: [NodeIdentifier] = []
        var seen: Set<NodeIdentifier> = []
        func append(_ nodeID: NodeIdentifier) {
            if seen.insert(nodeID).inserted {
                result.append(nodeID)
            }
        }
        for nodeID in baseMembers {
            append(nodeID)
            guard nodeID.kind == .iri || nodeID.kind == .blank else { continue }
            guard baseMembersByGraphID[nodeID.key] != nil else { continue }
            for childNodeID in expandedMembers(
                for: nodeID.key,
                baseMembersByGraphID: baseMembersByGraphID,
                expanding: nextExpanding
            ) {
                append(childNodeID)
            }
        }
        return result
    }

    private func namedGraphLabel(for named: NamedGraph, in graph: KnowledgeGraph) -> String? {
        if let label = named.label, !label.isEmpty {
            return label
        }
        let candidates = graph.nodes.compactMap { node -> NodeIdentifier? in
            switch node.id.kind {
            case .iri, .blank:
                return node.id.key == named.id ? node.id : nil
            case .literal:
                return nil
            }
        }
        guard !candidates.isEmpty else { return nil }
        let nodeByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        for candidate in candidates {
            for edge in graph.edges where edge.source == candidate && isNamedGraphLabelPredicate(edge.predicate) {
                guard edge.target.kind == .literal else { continue }
                if let label = literalValue(for: edge.target, nodeByID: nodeByID), !label.isEmpty {
                    return label
                }
            }
        }
        return nil
    }

    private func isNamedGraphLabelPredicate(_ predicate: String) -> Bool {
        switch predicate {
        case "http://www.w3.org/2000/01/rdf-schema#label",
             "http://schema.org/name",
             "https://schema.org/name",
             "http://schema.org/title",
             "https://schema.org/title",
             "http://purl.org/dc/terms/title",
             "http://purl.org/dc/elements/1.1/title":
            return true
        default:
            return false
        }
    }

    private func literalValue(
        for id: NodeIdentifier,
        nodeByID: [NodeIdentifier: Node]
    ) -> String? {
        guard id.kind == .literal else { return nil }
        if let label = nodeByID[id]?.label, !label.isEmpty {
            return label
        }
        return lexicalLiteralValue(from: id.key)
    }

    private func lexicalLiteralValue(from key: String) -> String? {
        guard key.first == "\"" else { return nil }
        var result = ""
        var index = key.index(after: key.startIndex)
        var escaped = false
        while index < key.endIndex {
            let character = key[index]
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
            index = key.index(after: index)
        }
        return nil
    }

    private func membersByNamedGraphFromEdges(
        graph: KnowledgeGraph
    ) -> [String: [NodeIdentifier]] {
        var result: [String: [NodeIdentifier]] = [:]
        var seenPerGraph: [String: Set<NodeIdentifier>] = [:]
        for edge in graph.edges {
            guard let graphID = edge.id.namedGraph else { continue }
            var seen = seenPerGraph[graphID] ?? []
            var nodes = result[graphID] ?? []
            if seen.insert(edge.id.source).inserted {
                nodes.append(edge.id.source)
            }
            if seen.insert(edge.id.target).inserted {
                nodes.append(edge.id.target)
            }
            seenPerGraph[graphID] = seen
            result[graphID] = nodes
        }
        return result
    }
}
