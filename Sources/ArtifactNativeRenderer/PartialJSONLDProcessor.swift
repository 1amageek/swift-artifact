import Foundation
import KnowledgeGraph

/// Converts a *partial* JSON-LD document into a `KnowledgeGraph`.
///
/// Unlike the full W3C JSON-LD algorithm, this processor is designed for the
/// streaming case where the source string may be truncated mid-token. It
/// works off a `PartialJSONValue` AST and emits exactly the triples that can
/// be derived from the currently-available portion of the document. Keys
/// whose predicate IRI cannot yet be resolved are *not silently dropped* —
/// they simply do not produce a triple this pass, and the next pass over a
/// longer prefix will pick them up. Failure to resolve does not propagate as
/// an error; it is the normal mid-stream state of the input.
///
/// JSON-LD subset supported:
///   - `@context` as an inline object (prefix / term map), including `@vocab`
///     and `@base`. External (string) contexts are noted but cannot be
///     dereferenced — keys gated on those terms will resolve lazily once the
///     stream provides an inline definition.
///   - `@id` (subject IRI, or blank-node label starting with `_:`).
///   - `@type` (one IRI or an array of IRIs → `rdf:type` triples).
///   - `@graph` (nested array of node objects).
///   - `@value`, `@type`, `@language` for typed / language-tagged literals.
///   - Plain key → value mappings, where values may be:
///     - string / number / boolean → literal
///     - object with `@id` → IRI reference
///     - object without `@id` → blank node, recursed into
///     - array → each element processed independently
///
/// Blank-node identifiers are derived from a stable AST-path so re-parsing a
/// longer prefix yields the same identifiers for nodes seen in both passes.
/// This is the precondition the layout engine relies on for warm restart.
struct PartialJSONLDProcessor {

    /// Stable namespace used for path-derived blank-node identifiers. The
    /// concrete value does not matter so long as it is constant across runs.
    private static let blankPrefix = "_:b"

    private static let rdfType = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    private static let xsdString = "http://www.w3.org/2001/XMLSchema#string"

    private struct TermMap: Sendable {
        var terms: [String: String] = [:]
        var vocab: String? = nil
        var base: String? = nil
    }

    let scope: String
    let baseIRI: String?

    init(scope: String, baseIRI: String?) {
        self.scope = scope
        self.baseIRI = baseIRI
    }

    /// Process `text` and return a `KnowledgeGraph` containing every triple
    /// derivable from its partial AST. Always returns a graph — never throws
    /// during partial processing — because mid-stream failure is the normal
    /// state and silent recovery is the explicit goal of this stage.
    func process(_ text: String) -> KnowledgeGraph {
        let ast = PartialJSON.parse(text)
        var builder = KnowledgeGraphBuilder()
        var context = TermMap()
        if let baseIRI {
            context.base = baseIRI
        }
        process(value: ast, parent: nil, predicate: nil, path: "", context: context, builder: &builder)
        return builder.build()
    }

    // MARK: - Core traversal

    /// Process a JSON-LD value and (optionally) emit a triple linking it to a
    /// parent node under `predicate`. Returns the `NodeIdentifier` of the
    /// object emitted, if any, for the caller to chain into further triples.
    @discardableResult
    private func process(
        value: PartialJSONValue,
        parent: NodeIdentifier?,
        predicate: String?,
        path: String,
        context: TermMap,
        builder: inout KnowledgeGraphBuilder
    ) -> NodeIdentifier? {
        switch value {
        case .object(let members, _):
            return processObject(
                members: members,
                parent: parent,
                predicate: predicate,
                path: path,
                context: context,
                builder: &builder
            )
        case .array(let elements, _):
            for (index, element) in elements.enumerated() {
                process(
                    value: element,
                    parent: parent,
                    predicate: predicate,
                    path: "\(path)[\(index)]",
                    context: context,
                    builder: &builder
                )
            }
            return nil
        case .string(let s):
            return emitLiteral(value: s, datatype: nil, language: nil,
                               parent: parent, predicate: predicate, builder: &builder)
        case .number(let n):
            let lexical: String
            if n.truncatingRemainder(dividingBy: 1) == 0, abs(n) < 1e15 {
                lexical = String(Int64(n))
            } else {
                lexical = String(n)
            }
            return emitLiteral(value: lexical, datatype: nil, language: nil,
                               parent: parent, predicate: predicate, builder: &builder)
        case .bool(let b):
            return emitLiteral(value: b ? "true" : "false", datatype: nil, language: nil,
                               parent: parent, predicate: predicate, builder: &builder)
        case .null:
            return nil
        }
    }

    private func processObject(
        members: [(key: String, value: PartialJSONValue)],
        parent: NodeIdentifier?,
        predicate: String?,
        path: String,
        context: TermMap,
        builder: inout KnowledgeGraphBuilder
    ) -> NodeIdentifier? {
        var localContext = context
        var idMember: String? = nil
        var typeMembers: [PartialJSONValue] = []
        var graphMembers: [PartialJSONValue] = []
        var valueLiteral: (value: PartialJSONValue, type: String?, language: String?)? = nil
        var attributes: [(key: String, value: PartialJSONValue)] = []

        var valueRaw: PartialJSONValue? = nil
        var valueType: String? = nil
        var valueLang: String? = nil
        var sawAtValue = false

        for (key, value) in members {
            switch key {
            case "@context":
                applyContext(value, into: &localContext)
            case "@id":
                if case .string(let s) = value { idMember = s }
            case "@type":
                typeMembers.append(value)
            case "@graph":
                graphMembers.append(value)
            case "@value":
                sawAtValue = true
                valueRaw = value
            case "@language":
                if case .string(let s) = value { valueLang = s }
            default:
                attributes.append((key, value))
            }
        }

        // `@value` containers may carry `@type` that should be read as the
        // literal datatype rather than as `rdf:type`.
        if sawAtValue, let firstType = typeMembers.first, case .string(let dt) = firstType {
            valueType = resolveIRI(dt, in: localContext)
            typeMembers.removeAll()
        }

        if sawAtValue, let raw = valueRaw {
            let lexical: String?
            switch raw {
            case .string(let s): lexical = s
            case .number(let n):
                lexical = n.truncatingRemainder(dividingBy: 1) == 0 && abs(n) < 1e15
                    ? String(Int64(n)) : String(n)
            case .bool(let b): lexical = b ? "true" : "false"
            default: lexical = nil
            }
            if let lexical {
                valueLiteral = (.string(lexical), valueType, valueLang)
            }
        }

        if let literal = valueLiteral {
            if case .string(let lex) = literal.value {
                return emitLiteral(
                    value: lex,
                    datatype: literal.type,
                    language: literal.language,
                    parent: parent,
                    predicate: predicate,
                    builder: &builder
                )
            }
        }

        let subject: NodeIdentifier
        if let id = idMember {
            if id.hasPrefix("_:") {
                subject = NodeIdentifier.blank(scopedBlankLabel(id))
            } else {
                subject = NodeIdentifier.iri(resolveIRI(id, in: localContext))
            }
        } else if !attributes.isEmpty || !typeMembers.isEmpty || !graphMembers.isEmpty {
            // Anonymous node — generate a deterministic blank label from the
            // AST path so warm-restart sees the same identifier on re-parse.
            subject = NodeIdentifier.blank(scopedBlankLabel("\(Self.blankPrefix)\(stableHash(path))"))
        } else {
            // Empty object: nothing to emit.
            return nil
        }

        do {
            try builder.insertNode(Node(id: subject))
        } catch {
            // Identifier validation is the only failure path here, and the
            // identifiers we construct above are well-formed by construction.
            // Re-raise as a runtime issue rather than silently dropping the
            // subject so genuine bugs surface in development.
            assertionFailure("PartialJSONLDProcessor: refused subject \(subject): \(error)")
        }

        if let parent, let predicate {
            try? builder.insertTriple(subject: parent, predicate: predicate, object: subject)
        }

        // `@type` → rdf:type triples.
        for typeNode in typeMembers {
            emitTypes(typeNode, subject: subject, context: localContext, builder: &builder)
        }

        // `@graph` → process nested node objects under the *same* context,
        // associating them with no parent (i.e. they stand alone).
        for graphNode in graphMembers {
            if case .array(let items, _) = graphNode {
                for (i, item) in items.enumerated() {
                    process(
                        value: item,
                        parent: nil,
                        predicate: nil,
                        path: "\(path).@graph[\(i)]",
                        context: localContext,
                        builder: &builder
                    )
                }
            } else {
                process(
                    value: graphNode,
                    parent: nil,
                    predicate: nil,
                    path: "\(path).@graph",
                    context: localContext,
                    builder: &builder
                )
            }
        }

        for (key, value) in attributes {
            guard let resolvedPredicate = resolvePredicate(key, in: localContext) else {
                // Predicate not resolvable yet — skip for this pass.
                continue
            }
            process(
                value: value,
                parent: subject,
                predicate: resolvedPredicate,
                path: "\(path).\(key)",
                context: localContext,
                builder: &builder
            )
        }

        return subject
    }

    // MARK: - Context

    private func applyContext(_ value: PartialJSONValue, into context: inout TermMap) {
        switch value {
        case .object(let members, _):
            for (key, value) in members {
                switch key {
                case "@vocab":
                    if case .string(let s) = value { context.vocab = s }
                case "@base":
                    if case .string(let s) = value { context.base = s }
                case "@version", "@protected", "@language", "@direction", "@import":
                    // No effect on IRI resolution in the partial path.
                    continue
                default:
                    if let iri = extractTermIRI(value, in: context) {
                        context.terms[key] = iri
                    }
                }
            }
        case .array(let items, _):
            // Compound context — apply each entry left to right.
            for item in items {
                applyContext(item, into: &context)
            }
        case .string:
            // External context reference. We cannot fetch it; leave the term
            // map unchanged so unresolved keys naturally skip this pass.
            return
        default:
            return
        }
    }

    /// Extract the IRI a JSON-LD term definition maps to. Supports both the
    /// short form `"foaf": "http://xmlns.com/foaf/0.1/"` and the expanded
    /// form `"name": { "@id": "foaf:name" }`.
    private func extractTermIRI(_ value: PartialJSONValue, in context: TermMap) -> String? {
        switch value {
        case .string(let s):
            return resolveIRI(s, in: context)
        case .object(let members, _):
            for (key, value) in members where key == "@id" {
                if case .string(let s) = value {
                    return resolveIRI(s, in: context)
                }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - IRI resolution

    private func resolveIRI(_ raw: String, in context: TermMap) -> String {
        if raw.hasPrefix("_:") { return raw }
        if let scheme = raw.range(of: ":"), scheme.lowerBound > raw.startIndex {
            // Looks like a CURIE or absolute IRI.
            let prefix = String(raw[..<scheme.lowerBound])
            let suffix = String(raw[raw.index(after: scheme.lowerBound)...])
            if let mapped = context.terms[prefix] {
                return mapped + suffix
            }
            return raw
        }
        if let vocab = context.vocab {
            return vocab + raw
        }
        if let mapped = context.terms[raw] {
            return mapped
        }
        if let base = context.base {
            return base + raw
        }
        return raw
    }

    private func resolvePredicate(_ key: String, in context: TermMap) -> String? {
        if let mapped = context.terms[key] {
            return mapped
        }
        if let vocab = context.vocab {
            return vocab + key
        }
        if key.range(of: ":") != nil {
            // CURIE / absolute IRI form — accept as-is (or after prefix
            // expansion via resolveIRI).
            return resolveIRI(key, in: context)
        }
        return nil
    }

    // MARK: - Emitters

    private func emitLiteral(
        value: String,
        datatype: String?,
        language: String?,
        parent: NodeIdentifier?,
        predicate: String?,
        builder: inout KnowledgeGraphBuilder
    ) -> NodeIdentifier? {
        let literal = NodeIdentifier.literal(value: value, datatype: datatype, language: language)
        try? builder.insertNode(Node(id: literal))
        if let parent, let predicate {
            try? builder.insertTriple(subject: parent, predicate: predicate, object: literal)
        }
        return literal
    }

    private func emitTypes(
        _ value: PartialJSONValue,
        subject: NodeIdentifier,
        context: TermMap,
        builder: inout KnowledgeGraphBuilder
    ) {
        switch value {
        case .string(let s):
            let iri = resolveIRI(s, in: context)
            let typeNode = NodeIdentifier.iri(iri)
            try? builder.insertNode(Node(id: typeNode))
            try? builder.insertTriple(subject: subject, predicate: Self.rdfType, object: typeNode)
        case .array(let items, _):
            for item in items {
                emitTypes(item, subject: subject, context: context, builder: &builder)
            }
        default:
            return
        }
    }

    // MARK: - Helpers

    /// Wrap a `_:foo` style label in the parser scope so blank identifiers
    /// emitted by different artifacts on the same canvas never collide.
    private func scopedBlankLabel(_ label: String) -> String {
        let trimmed = label.hasPrefix("_:") ? String(label.dropFirst(2)) : label
        return "\(scope).\(trimmed)"
    }

    /// Deterministic hash of an AST path. Built on `Hasher` with no seed so
    /// two runs of the same process *within one invocation* match, plus a
    /// fold over UnicodeScalars so the result is stable across processes —
    /// required for warm restart between consecutive stream snapshots.
    private func stableHash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for scalar in s.unicodeScalars {
            h ^= UInt64(scalar.value)
            h = h &* 1099511628211
        }
        return String(h, radix: 36)
    }
}
