import Foundation
import CoreGraphics
import KnowledgeGraph

/// Decomposed view of a `KnowledgeGraph` optimised for visual layout.
///
/// A `CompoundGraph` groups every IRI/blank-node subject with its **leaf
/// literals** into a single "card". A literal is a leaf when exactly one
/// distinct subject targets it — the foaf:name "Alice" pattern. Folding
/// leaves into the subject means they are no longer separate layout entities,
/// which eliminates the "where should the literal go around its parent"
/// problem entirely: the literal is *inside* the parent.
///
/// Literals with multiple distinct subjects (shared literals) remain as
/// stand-alone cards because they represent a meaningful joining vertex in
/// the topology.
///
/// Edges between cards carry the predicate label and parallel-edge metadata
/// for the renderer to apply consistent perpendicular offsets.
struct CompoundGraph: Sendable {

    let cards: [Card]
    let edges: [CardEdge]
    let cardByID: [Card.ID: Card]
    /// Visual groups computed from a `GroupingStrategy`. Empty when the
    /// strategy is `.none` or every derived group lost all its members to
    /// literal folding.
    let groups: [Group]
    /// Index of `groups` by `Group.ID` for O(1) lookups.
    let groupByID: [Group.ID: Group]
    /// Reverse map: for each `Card.ID` lists the groups that include it.
    /// `nil` — not `[]` — when the card belongs to no group, so callers can
    /// distinguish "unassigned" from "assigned to zero groups by accident".
    let groupsByCard: [Card.ID: [Group.ID]]

    init(
        cards: [Card],
        edges: [CardEdge],
        groups: [Group] = []
    ) {
        self.cards = cards
        self.edges = edges
        var byID: [Card.ID: Card] = [:]
        byID.reserveCapacity(cards.count)
        for card in cards { byID[card.id] = card }
        self.cardByID = byID

        self.groups = groups
        var groupIndex: [Group.ID: Group] = [:]
        groupIndex.reserveCapacity(groups.count)
        var reverse: [Card.ID: [Group.ID]] = [:]
        for group in groups {
            groupIndex[group.id] = group
            for member in group.members {
                reverse[member, default: []].append(group.id)
            }
        }
        self.groupByID = groupIndex
        self.groupsByCard = reverse
    }

    /// A single rendered unit: either an IRI / blank node with its inline
    /// literal attributes, or a stand-alone shared literal.
    struct Card: Identifiable, Sendable, Hashable {

        /// Stable identity for layout — derived from the wrapped node id so
        /// warm-restart positions survive across snapshots.
        struct ID: Hashable, Sendable {
            let nodeID: NodeIdentifier
        }

        enum Kind: Sendable, Hashable {
            /// IRI- or blank-node subject. May have zero or more attributes.
            case resource(NodeKind)
            /// Stand-alone literal that is the target of more than one
            /// subject. Has no attributes.
            case literal
        }

        /// One row inside a resource card: `predicate → literal value`.
        struct Attribute: Identifiable, Sendable, Hashable {
            let id: String
            let predicate: String
            let value: String
            let valueQualifier: String?
        }

        let id: ID
        let kind: Kind
        let title: String
        let qualifiedTitle: String
        let attributes: [Attribute]
        let size: CGSize
    }

    /// A directed edge between two cards. Parallel-edge metadata lets the
    /// renderer offset siblings perpendicular to the line so they read
    /// individually rather than overlapping.
    struct CardEdge: Identifiable, Sendable, Hashable {
        let id: EdgeIdentifier
        let source: Card.ID
        let target: Card.ID
        let predicate: String
        let parallelIndex: Int
        let parallelCount: Int
    }
}

// MARK: - Decomposition

extension CompoundGraph {

    /// Decompose `graph` into cards and inter-card edges.
    ///
    /// Algorithm:
    ///
    /// 1. Index every literal node by its set of distinct subjects.
    /// 2. A literal is *leaf* iff its subject set has exactly one element.
    ///    Such literals are folded into the owning subject's card as
    ///    `Attribute` rows.
    /// 3. Every other node becomes a stand-alone card (resource or shared
    ///    literal).
    /// 4. Walk `graph.edges` once more, emitting a `CardEdge` for every edge
    ///    whose target is **not** a leaf literal of its source. Edges that
    ///    were absorbed as attributes are dropped.
    /// 5. Parallel edges (same `(source, target)` pair, multiple predicates)
    ///    are numbered so the renderer can offset them.
    static func decompose(
        _ graph: KnowledgeGraph,
        groupingStrategy: GroupingStrategy = .namedGraphs()
    ) -> CompoundGraph {
        let shortener = LabelShortener(namespaces: graph.namespaces)

        let nodeByID: [NodeIdentifier: Node] = Dictionary(
            uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) }
        )

        // Step 1–2: classify literals as leaf / shared.
        var subjectsByLiteral: [NodeIdentifier: Set<NodeIdentifier>] = [:]
        for edge in graph.edges where edge.target.kind == .literal {
            subjectsByLiteral[edge.target, default: []].insert(edge.source)
        }
        var leafLiteralParent: [NodeIdentifier: NodeIdentifier] = [:]
        leafLiteralParent.reserveCapacity(subjectsByLiteral.count)
        for (literal, subjects) in subjectsByLiteral where subjects.count == 1 {
            if let only = subjects.first {
                leafLiteralParent[literal] = only
            }
        }

        // Group leaf-literal edges by parent so we can fold them as attributes
        // in deterministic predicate-order within each card.
        var leafEdgesByParent: [NodeIdentifier: [Edge]] = [:]
        var foldedEdgeIDs: Set<EdgeIdentifier> = []
        for edge in graph.edges {
            guard edge.target.kind == .literal,
                  let parent = leafLiteralParent[edge.target],
                  parent == edge.source else { continue }
            leafEdgesByParent[parent, default: []].append(edge)
            foldedEdgeIDs.insert(edge.id)
        }

        // Step 3: build cards in stable insertion order.
        var cards: [Card] = []
        cards.reserveCapacity(graph.nodes.count)
        for node in graph.nodes {
            switch node.id.kind {
            case .iri, .blank:
                let attributes = (leafEdgesByParent[node.id] ?? []).map { edge -> Card.Attribute in
                    let literalNode = nodeByID[edge.target]
                    let display = shortener.literalDisplay(
                        key: edge.target.key,
                        node: literalNode
                    )
                    return Card.Attribute(
                        id: edge.id.predicate + "\u{1F}" + edge.target.key,
                        predicate: shortener.predicateDisplay(edge: edge),
                        value: display.value,
                        valueQualifier: display.qualifier
                    )
                }
                let title = shortener.resourceTitle(node: node, identifier: node.id)
                let qualified = node.id.kind == .iri ? node.id.key : "_:\(node.id.key)"
                let size = CardSizing.size(title: title, attributes: attributes)
                cards.append(Card(
                    id: Card.ID(nodeID: node.id),
                    kind: .resource(node.id.kind),
                    title: title,
                    qualifiedTitle: qualified,
                    attributes: attributes,
                    size: size
                ))
            case .literal:
                guard leafLiteralParent[node.id] == nil else { continue }
                let display = shortener.literalDisplay(key: node.id.key, node: node)
                let title = display.value
                let size = CardSizing.size(title: title, attributes: [])
                cards.append(Card(
                    id: Card.ID(nodeID: node.id),
                    kind: .literal,
                    title: title,
                    qualifiedTitle: display.qualifier.map { "\(title)\($0)" } ?? title,
                    attributes: [],
                    size: size
                ))
            }
        }

        // Step 4–5: build inter-card edges with parallel numbering.
        struct PairKey: Hashable {
            let source: NodeIdentifier
            let target: NodeIdentifier
        }
        var bucketed: [PairKey: [Edge]] = [:]
        for edge in graph.edges where !foldedEdgeIDs.contains(edge.id) {
            // Skip self-edges to a folded literal (already absorbed).
            bucketed[PairKey(source: edge.source, target: edge.target), default: []].append(edge)
        }

        var cardEdges: [CardEdge] = []
        cardEdges.reserveCapacity(graph.edges.count - foldedEdgeIDs.count)
        let validIDs = Set(cards.map { $0.id.nodeID })
        for edge in graph.edges where !foldedEdgeIDs.contains(edge.id) {
            guard validIDs.contains(edge.source), validIDs.contains(edge.target) else { continue }
            let pair = PairKey(source: edge.source, target: edge.target)
            let siblings = bucketed[pair] ?? [edge]
            let index = siblings.firstIndex(where: { $0.id == edge.id }) ?? 0
            cardEdges.append(CardEdge(
                id: edge.id,
                source: Card.ID(nodeID: edge.source),
                target: Card.ID(nodeID: edge.target),
                predicate: shortener.predicateDisplay(edge: edge),
                parallelIndex: index,
                parallelCount: siblings.count
            ))
        }

        // Build the node→card lookup used by every grouping strategy so we
        // can drop members that did not survive literal folding.
        var cardIDsByNodeID: [NodeIdentifier: Card.ID] = [:]
        cardIDsByNodeID.reserveCapacity(cards.count)
        for card in cards { cardIDsByNodeID[card.id.nodeID] = card.id }

        let derived = groupingStrategy.deriveGroups(
            graph: graph,
            cardIDsByNodeID: cardIDsByNodeID
        )
        let filtered = derived.filter { !$0.members.isEmpty }

        return CompoundGraph(
            cards: cards,
            edges: cardEdges,
            groups: filtered
        )
    }
}

// MARK: - Sizing

/// Deterministic card sizing. We do not measure SwiftUI text up-front because
/// the layout runs off-main and the calculation must be reproducible across
/// snapshots. Sizes are intentionally a touch generous so the actual SwiftUI
/// view never clips at any reasonable system font scale.
enum CardSizing {

    static let headerHeight: CGFloat = 28
    static let dividerHeight: CGFloat = 1
    static let attributesVerticalPad: CGFloat = 8
    static let rowHeight: CGFloat = 18
    static let horizontalPad: CGFloat = 12
    static let columnGap: CGFloat = 16
    static let minWidth: CGFloat = 140
    static let maxWidth: CGFloat = 280

    /// Approximate em-width for an 11pt body font in the system family. We
    /// over-estimate slightly so the deterministic size leaves headroom for
    /// the actual SwiftUI text renderer.
    private static let bodyCharWidth: CGFloat = 6.8
    /// Approximate em-width for a 13pt semibold header.
    private static let titleCharWidth: CGFloat = 7.6
    /// Cap how long a single attribute row can dictate width. Values longer
    /// than this truncate visually instead of inflating the card.
    private static let maxValueChars: Int = 28
    private static let maxPredicateChars: Int = 18
    private static let maxTitleChars: Int = 28

    static func size(title: String, attributes: [CompoundGraph.Card.Attribute]) -> CGSize {
        let truncatedTitleCount = min(title.count, maxTitleChars)
        let titleWidth = CGFloat(truncatedTitleCount) * titleCharWidth + 24

        var widestRow: CGFloat = 0
        for attribute in attributes {
            let predicateChars = min(attribute.predicate.count, maxPredicateChars)
            let valueChars = min(attribute.value.count, maxValueChars)
            let rowWidth =
                CGFloat(predicateChars) * bodyCharWidth +
                columnGap +
                CGFloat(valueChars) * bodyCharWidth
            if rowWidth > widestRow { widestRow = rowWidth }
        }

        let contentWidth = max(titleWidth, widestRow + 2 * horizontalPad)
        let width = min(maxWidth, max(minWidth, contentWidth))

        let height: CGFloat
        if attributes.isEmpty {
            height = headerHeight
        } else {
            height = headerHeight + dividerHeight
                + attributesVerticalPad * 2
                + CGFloat(attributes.count) * rowHeight
        }
        return CGSize(width: width, height: height)
    }
}

// MARK: - Label shortening

/// Stateless helpers that turn raw RDF strings into compact display labels,
/// using the graph's declared namespace prefixes where available.
struct LabelShortener: Sendable {

    let namespaces: [Namespace]

    /// Convert an absolute IRI to its prefixed form (`foaf:name`) when a
    /// namespace match exists, otherwise return the local name (the suffix
    /// after the last `#` or `/`).
    func shortenIRI(_ iri: String) -> String {
        for namespace in namespaces where !namespace.uri.isEmpty {
            if iri.hasPrefix(namespace.uri) {
                let local = iri.dropFirst(namespace.uri.count)
                guard !local.isEmpty else { continue }
                return "\(namespace.prefix):\(local)"
            }
        }
        return localName(of: iri)
    }

    func predicateDisplay(edge: Edge) -> String {
        if let label = edge.label, !label.isEmpty {
            return label
        }
        return shortenIRI(edge.predicate)
    }

    func resourceTitle(node: Node, identifier: NodeIdentifier) -> String {
        if let label = node.label, !label.isEmpty { return label }
        switch identifier.kind {
        case .iri:
            return shortenIRI(identifier.key)
        case .blank:
            return "_:\(blankLocalLabel(identifier.key))"
        case .literal:
            return literalDisplay(key: identifier.key, node: node).value
        }
    }

    struct LiteralDisplay {
        let value: String
        let qualifier: String?
    }

    /// Parse the encoded literal key into a display value + qualifier suffix.
    ///
    /// `Node.id.key` for a literal is one of:
    ///   - `"value"@lang`
    ///   - `"value"^^datatypeIRI`
    ///   - `"value"`
    ///
    /// The qualifier we emit reuses the prefixed datatype IRI when possible
    /// so a card titled `"42"^^xsd:integer` reads naturally.
    func literalDisplay(key: String, node: Node?) -> LiteralDisplay {
        guard key.first == "\"" else {
            return LiteralDisplay(value: key, qualifier: nil)
        }
        let afterFirst = key.index(after: key.startIndex)
        let remainder = key[afterFirst...]
        guard let closingIdx = remainder.lastIndex(of: "\"") else {
            return LiteralDisplay(value: key, qualifier: nil)
        }
        let value = String(remainder[..<closingIdx])
        let tail = remainder[remainder.index(after: closingIdx)...]

        if tail.hasPrefix("@") {
            let lang = tail.dropFirst()
            return LiteralDisplay(value: value, qualifier: "@\(lang)")
        }
        if tail.hasPrefix("^^") {
            let datatype = String(tail.dropFirst(2))
            let prefixed = shortenIRI(datatype)
            return LiteralDisplay(value: value, qualifier: "^^\(prefixed)")
        }
        if let language = node?.language, !language.isEmpty {
            return LiteralDisplay(value: value, qualifier: "@\(language)")
        }
        if let datatype = node?.datatype, !datatype.isEmpty {
            return LiteralDisplay(value: value, qualifier: "^^\(shortenIRI(datatype))")
        }
        return LiteralDisplay(value: value, qualifier: nil)
    }

    private func localName(of iri: String) -> String {
        if let hashRange = iri.range(of: "#", options: .backwards) {
            return String(iri[hashRange.upperBound...])
        }
        if let slashRange = iri.range(of: "/", options: .backwards) {
            return String(iri[slashRange.upperBound...])
        }
        return iri
    }

    private func blankLocalLabel(_ scopedKey: String) -> String {
        if let slashRange = scopedKey.range(of: "/", options: .backwards) {
            return String(scopedKey[slashRange.upperBound...])
        }
        return scopedKey
    }
}
