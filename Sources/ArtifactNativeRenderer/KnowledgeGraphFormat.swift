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
}
