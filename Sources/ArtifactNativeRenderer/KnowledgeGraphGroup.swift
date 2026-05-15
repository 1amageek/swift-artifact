import Foundation
import CoreGraphics

extension CompoundGraph {

    /// A visual cluster of cards. `Group` carries **no RDF semantics** — it
    /// is an overlay computed from one of `GroupingStrategy`'s sources
    /// (named graphs, `rdf:type`, namespace prefix, or an explicit list).
    /// Triples are never created from groups; the underlying `KnowledgeGraph`
    /// is read-only as far as grouping is concerned.
    ///
    /// `members` is the deterministic, decompose-order list of cards that
    /// belong to the group. Empty groups are filtered before being added to
    /// `CompoundGraph.groups` so every persisted group has at least one
    /// member.
    struct Group: Identifiable, Sendable, Hashable {

        /// Strategy-prefixed identity so a named graph and an `rdf:type` that
        /// happen to share an IRI do not collide.
        ///
        /// Prefix conventions:
        ///   - `namedGraph:<graph.id>`
        ///   - `type:<rdf:type IRI>`
        ///   - `namespace:<prefix>`
        ///   - `explicit:<caller-supplied label>`
        struct ID: Hashable, Sendable {
            let key: String
        }

        let id: ID
        let label: String
        let members: [Card.ID]
        let style: GroupStyle
        /// Per-group strength (`[0, 1]`) for the layout cohesion force. `0`
        /// disables cohesion for this group (members still belong to it for
        /// rendering purposes).
        let cohesionStrength: Double
    }
}
