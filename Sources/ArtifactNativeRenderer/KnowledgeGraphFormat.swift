import Foundation
import KnowledgeGraph
import KnowledgeGraphParsers

/// Dispatch table mapping a renderer to its concrete parser.
///
/// Each case constructs the parser, seeds the `ParsingContext` with a stable
/// blank-node scope, and returns a fully built `KnowledgeGraph`. Centralising
/// the construction keeps the five renderer types thin and ensures the same
/// scoping / base-IRI policy is applied uniformly.
enum KnowledgeGraphFormat: Sendable {
    case turtle
    case trig
    case nQuads
    case rdfXML
    case jsonLD

    /// Parse `text` into a `KnowledgeGraph`.
    ///
    /// - Parameters:
    ///   - text: The full source document.
    ///   - scope: Stable blank-node scope identifier — typically the artifact
    ///     ID so that re-parsing the same payload yields identical blank-node
    ///     identifiers (warm-restart-safe for a layout engine).
    ///   - baseIRI: Optional base IRI for resolving relative references.
    ///     JSON-LD and RDF/XML require a base when the document contains any
    ///     relative IRI; absent a base, the parser will throw
    ///     `ParserError.noBaseIRI` on the first relative reference.
    func parse(
        _ text: String,
        scope: String,
        baseIRI: String?
    ) throws -> KnowledgeGraph {
        var context = ParsingContext(blankScopeID: scope)
        if let baseIRI {
            context.setBaseIRI(IRI(baseIRI))
        }
        switch self {
        case .turtle:
            var parser = TurtleParser(context: context)
            return try parser.parse(text)
        case .trig:
            var parser = TriGParser(context: context)
            return try parser.parse(text)
        case .nQuads:
            var parser = NQuadsParser(context: context)
            return try parser.parse(text)
        case .rdfXML:
            var parser = RDFXMLParser(context: context)
            return try parser.parse(text)
        case .jsonLD:
            var parser = JSONLDParser(context: context)
            return try parser.parse(text)
        }
    }

    /// Parse a streaming snapshot of `text` into whatever `KnowledgeGraph`
    /// can be extracted from its current prefix. Returns an empty graph
    /// rather than throwing on mid-stream input — partial extraction is the
    /// explicit goal here, and a failed parse is the normal "no complete
    /// triple yet" state. Real errors (malformed CURIEs, missing base IRI,
    /// etc.) still surface as thrown errors when the underlying parsers
    /// reach a structural impossibility.
    ///
    /// Per-format strategy:
    ///   - Turtle / TriG: feed the largest prefix that ends at a statement
    ///     terminator (`.`) into the standard parser. Triples mid-line are
    ///     deferred until their `.` arrives.
    ///   - N-Quads: feed the largest prefix that ends at a newline. Each
    ///     line is a self-contained quad.
    ///   - RDF/XML: framing pass collects every fully-closed top-level
    ///     element under `<rdf:RDF>` and parses them as a synthetic
    ///     document.
    ///   - JSON-LD: PartialJSON-based AST traversal emits triples for every
    ///     fully-typed property pair derivable from the current snapshot.
    /// Cheap probe for whether a partial payload has anything worth
    /// rendering. Used by `refine(_:)` on each renderer to decide between
    /// `.renderable` (we have at least one triple) and `.preRenderable`
    /// (still waiting). Runs the full partial pipeline so the answer is
    /// authoritative, then discards the graph.
    func hasRenderablePartial(_ text: String, baseIRI: String?) -> Bool {
        let outcome = parsePartial(text, scope: "preview", baseIRI: baseIRI)
        return !outcome.graph.nodes.isEmpty
    }

    /// Partial-mode parsing is non-throwing by contract — failure mid-stream
    /// is the expected state, not an exceptional one. The result is a
    /// `PartialParseOutcome` carrying both the graph extracted from the
    /// current prefix and a `failure` reason if the underlying parser
    /// rejected the prefix outright; the caller chooses what to do with
    /// the reason (e.g. show it once streaming completes).
    struct PartialParseOutcome: Sendable {
        let graph: KnowledgeGraph
        /// Non-nil when the underlying parser threw on the prefix that this
        /// partial pass selected. Higher layers use this to keep the prior
        /// valid snapshot on screen rather than clearing the view.
        let failure: PartialFailureReason?
    }

    /// Reason carried by a failed partial parse. The value is value-typed
    /// (`Sendable`) so it can cross actor hops; the original `Error` is
    /// represented as its localized description because the W3C parsers
    /// produce non-`Sendable` error values.
    struct PartialFailureReason: Sendable, Equatable {
        let message: String
    }

    func parsePartial(
        _ text: String,
        scope: String,
        baseIRI: String?
    ) -> PartialParseOutcome {
        switch self {
        case .turtle, .trig:
            return parseTripleTerminatedPrefix(text, scope: scope, baseIRI: baseIRI)
        case .nQuads:
            return parseLineTerminatedPrefix(text, scope: scope, baseIRI: baseIRI)
        case .rdfXML:
            let processor = PartialRDFXMLProcessor(scope: scope, baseIRI: baseIRI)
            do {
                return PartialParseOutcome(graph: try processor.process(text), failure: nil)
            } catch {
                return PartialParseOutcome(
                    graph: .empty,
                    failure: PartialFailureReason(message: "\(error)")
                )
            }
        case .jsonLD:
            let processor = PartialJSONLDProcessor(scope: scope, baseIRI: baseIRI)
            return PartialParseOutcome(graph: processor.process(text), failure: nil)
        }
    }

    /// Truncate `text` at the last `.` that is not inside a quoted literal,
    /// IRI reference, or comment, then parse with the matching W3C parser.
    /// The truncation guarantees the parser only ever sees fully-formed
    /// triples — never a half-written subject or predicate.
    private func parseTripleTerminatedPrefix(
        _ text: String,
        scope: String,
        baseIRI: String?
    ) -> PartialParseOutcome {
        guard let cut = lastTurtleTerminator(in: text) else {
            return PartialParseOutcome(graph: .empty, failure: nil)
        }
        let prefix = String(text[..<cut])
        var context = ParsingContext(blankScopeID: scope)
        if let baseIRI {
            context.setBaseIRI(IRI(baseIRI))
        }
        do {
            switch self {
            case .turtle:
                var parser = TurtleParser(context: context)
                return PartialParseOutcome(graph: try parser.parse(prefix), failure: nil)
            case .trig:
                var parser = TriGParser(context: context)
                return PartialParseOutcome(graph: try parser.parse(prefix), failure: nil)
            default:
                return PartialParseOutcome(graph: .empty, failure: nil)
            }
        } catch {
            return PartialParseOutcome(
                graph: .empty,
                failure: PartialFailureReason(message: "\(error)")
            )
        }
    }

    private func parseLineTerminatedPrefix(
        _ text: String,
        scope: String,
        baseIRI: String?
    ) -> PartialParseOutcome {
        guard let cut = text.lastIndex(of: "\n") else {
            return PartialParseOutcome(graph: .empty, failure: nil)
        }
        let prefix = String(text[..<text.index(after: cut)])
        var context = ParsingContext(blankScopeID: scope)
        if let baseIRI {
            context.setBaseIRI(IRI(baseIRI))
        }
        var parser = NQuadsParser(context: context)
        do {
            return PartialParseOutcome(graph: try parser.parse(prefix), failure: nil)
        } catch {
            return PartialParseOutcome(
                graph: .empty,
                failure: PartialFailureReason(message: "\(error)")
            )
        }
    }

    /// Find the index just past the last `.` that terminates a Turtle / TriG
    /// statement. `.` characters appearing inside `"..."` / `'...'` / `<...>`
    /// / `# comment` runs are skipped.
    private func lastTurtleTerminator(in text: String) -> String.Index? {
        var i = text.startIndex
        var last: String.Index? = nil
        while i < text.endIndex {
            let c = text[i]
            switch c {
            case "#":
                while i < text.endIndex, text[i] != "\n" {
                    i = text.index(after: i)
                }
            case "\"":
                // Detect triple-quoted long literals first.
                if matchesPrefix(text, at: i, "\"\"\"") {
                    i = text.index(i, offsetBy: 3)
                    while i < text.endIndex, !matchesPrefix(text, at: i, "\"\"\"") {
                        if text[i] == "\\" {
                            i = text.index(after: i)
                            if i < text.endIndex { i = text.index(after: i) }
                            continue
                        }
                        i = text.index(after: i)
                    }
                    if i < text.endIndex { i = text.index(i, offsetBy: 3) }
                } else {
                    i = text.index(after: i)
                    while i < text.endIndex, text[i] != "\"" {
                        if text[i] == "\\" {
                            i = text.index(after: i)
                            if i < text.endIndex { i = text.index(after: i) }
                            continue
                        }
                        i = text.index(after: i)
                    }
                    if i < text.endIndex { i = text.index(after: i) }
                }
            case "'":
                if matchesPrefix(text, at: i, "'''") {
                    i = text.index(i, offsetBy: 3)
                    while i < text.endIndex, !matchesPrefix(text, at: i, "'''") {
                        if text[i] == "\\" {
                            i = text.index(after: i)
                            if i < text.endIndex { i = text.index(after: i) }
                            continue
                        }
                        i = text.index(after: i)
                    }
                    if i < text.endIndex { i = text.index(i, offsetBy: 3) }
                } else {
                    i = text.index(after: i)
                    while i < text.endIndex, text[i] != "'" {
                        if text[i] == "\\" {
                            i = text.index(after: i)
                            if i < text.endIndex { i = text.index(after: i) }
                            continue
                        }
                        i = text.index(after: i)
                    }
                    if i < text.endIndex { i = text.index(after: i) }
                }
            case "<":
                i = text.index(after: i)
                while i < text.endIndex, text[i] != ">" {
                    i = text.index(after: i)
                }
                if i < text.endIndex { i = text.index(after: i) }
            case ".":
                let next = text.index(after: i)
                last = next
                i = next
            default:
                i = text.index(after: i)
            }
        }
        return last
    }

    private func matchesPrefix(_ text: String, at i: String.Index, _ prefix: String) -> Bool {
        var ti = i
        for ch in prefix {
            guard ti < text.endIndex, text[ti] == ch else { return false }
            ti = text.index(after: ti)
        }
        return true
    }
}
