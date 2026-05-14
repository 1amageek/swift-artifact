import Foundation
import KnowledgeGraph
import KnowledgeGraphParsers

/// Converts a *partial* RDF/XML document into a `KnowledgeGraph`.
///
/// Strategy: scan the source for the `<rdf:RDF ...>` opening element,
/// preserve every namespace / `xml:base` attribute declared on it, then
/// collect each *fully closed* child element (top-level `<rdf:Description>`,
/// typed-node, or any other RDF/XML node element) up to the current
/// streaming cursor. Those closed children are reassembled into a synthetic
/// well-formed document and handed to the underlying `RDFXMLParser`. An
/// unfinished trailing child is left out — it will be picked up on the next
/// snapshot, by which point it may itself be closed.
///
/// This preserves the W3C semantics of every triple we emit: each block is
/// parsed by the real RDF/XML parser, never by a heuristic. The partial
/// step is purely a "framing" pass that picks out spans the real parser is
/// guaranteed to accept.
struct PartialRDFXMLProcessor {

    let scope: String
    let baseIRI: String?

    init(scope: String, baseIRI: String?) {
        self.scope = scope
        self.baseIRI = baseIRI
    }

    /// Process `text` into a graph of every fully-formed triple visible in
    /// the current snapshot. Returns an empty graph if no `<rdf:RDF>`
    /// opening tag has arrived yet — this is the normal mid-stream state.
    func process(_ text: String) throws -> KnowledgeGraph {
        guard let header = findRDFHeader(in: text) else {
            return KnowledgeGraph(nodes: [], edges: [], namespaces: [], namedGraphs: [])
        }
        let children = collectClosedChildren(in: text, startingAt: header.bodyStart)
        if children.isEmpty {
            return KnowledgeGraph(nodes: [], edges: [], namespaces: [], namedGraphs: [])
        }
        let document = synthesizeDocument(
            prolog: header.prolog,
            rootOpen: header.openTag,
            rootName: header.rootName,
            body: children
        )
        var context = ParsingContext(blankScopeID: scope)
        if let baseIRI {
            context.setBaseIRI(IRI(baseIRI))
        }
        var parser = RDFXMLParser(context: context)
        return try parser.parse(document)
    }

    // MARK: - Header scan

    private struct Header {
        let prolog: String          // optional <?xml ...?> + xmlns prelude
        let openTag: String         // verbatim `<rdf:RDF ...>` (no trailing slash)
        let rootName: String        // e.g. "rdf:RDF"
        let bodyStart: String.Index // index immediately after the open tag
    }

    private func findRDFHeader(in text: String) -> Header? {
        var i = text.startIndex
        var prologEnd = i
        // Skip any leading whitespace, XML declaration, comments, and
        // processing instructions before the document root.
        while i < text.endIndex {
            skipWhitespace(text, &i)
            if i >= text.endIndex { return nil }
            if matchesPrefix(text, at: i, "<?") {
                guard let end = scanUntil(text, after: i, terminator: "?>") else { return nil }
                i = end
                prologEnd = i
                continue
            }
            if matchesPrefix(text, at: i, "<!--") {
                guard let end = scanUntil(text, after: i, terminator: "-->") else { return nil }
                i = end
                prologEnd = i
                continue
            }
            if matchesPrefix(text, at: i, "<!") {
                // DOCTYPE / other markup decl — find matching `>`.
                guard let end = scanUntil(text, after: i, terminator: ">") else { return nil }
                i = end
                prologEnd = i
                continue
            }
            break
        }
        guard i < text.endIndex, text[i] == "<" else { return nil }

        // Locate the closing `>` of the root open tag (must not be a
        // self-closing tag — RDF/XML's root never is).
        guard let openTagEnd = findOpenTagEnd(in: text, from: i) else { return nil }
        let openTag = String(text[i..<openTagEnd])
        // openTagEnd points one past the `>`.

        // Reject self-closing root tags — there can be no children to emit
        // in that case anyway.
        if openTag.hasSuffix("/>") { return nil }

        // Extract the element local name.
        let afterLT = text.index(after: i)
        var nameEnd = afterLT
        while nameEnd < openTagEnd, !text[nameEnd].isXMLNameTerminator {
            nameEnd = text.index(after: nameEnd)
        }
        let rootName = String(text[afterLT..<nameEnd])
        if rootName.isEmpty { return nil }

        return Header(
            prolog: String(text[text.startIndex..<prologEnd]),
            openTag: openTag,
            rootName: rootName,
            bodyStart: openTagEnd
        )
    }

    // MARK: - Body scan

    /// Collect every top-level child element of the RDF root that has its
    /// closing tag already in `text`. Comments and processing instructions
    /// inside the body are simply skipped (preserved into the synthesised
    /// document is not necessary — they carry no triples).
    private func collectClosedChildren(in text: String, startingAt: String.Index) -> [String] {
        var i = startingAt
        var children: [String] = []
        while i < text.endIndex {
            skipWhitespace(text, &i)
            guard i < text.endIndex else { break }
            if text[i] != "<" { break }
            if matchesPrefix(text, at: i, "<!--") {
                guard let end = scanUntil(text, after: i, terminator: "-->") else { break }
                i = end
                continue
            }
            if matchesPrefix(text, at: i, "<?") {
                guard let end = scanUntil(text, after: i, terminator: "?>") else { break }
                i = end
                continue
            }
            // End of root?
            if matchesPrefix(text, at: i, "</") {
                break
            }
            // Read the open tag.
            guard let openEnd = findOpenTagEnd(in: text, from: i) else { break }
            let openTag = String(text[i..<openEnd])
            if openTag.hasSuffix("/>") {
                // Self-closing child is itself a complete block.
                children.append(openTag)
                i = openEnd
                continue
            }
            let elementName = extractElementName(from: openTag)
            // Find the matching closing tag at depth zero.
            guard let blockEnd = findElementEnd(in: text, from: openEnd, name: elementName) else {
                break
            }
            children.append(String(text[i..<blockEnd]))
            i = blockEnd
        }
        return children
    }

    /// Find the index just past `>` of the open tag starting at `start` (the
    /// `<` character). Respects strings inside attribute values.
    private func findOpenTagEnd(in text: String, from start: String.Index) -> String.Index? {
        var i = text.index(after: start)
        var quote: Character? = nil
        while i < text.endIndex {
            let c = text[i]
            if let q = quote {
                if c == q { quote = nil }
            } else {
                if c == "\"" || c == "'" { quote = c }
                else if c == ">" { return text.index(after: i) }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Given the index right after the opening tag of an element named
    /// `name`, return the index right after its matching `</name>` closing
    /// tag, or `nil` if it has not arrived yet.
    private func findElementEnd(in text: String, from start: String.Index, name: String) -> String.Index? {
        var i = start
        var depth = 1
        while i < text.endIndex {
            if matchesPrefix(text, at: i, "<!--") {
                guard let end = scanUntil(text, after: i, terminator: "-->") else { return nil }
                i = end
                continue
            }
            if matchesPrefix(text, at: i, "<![CDATA[") {
                guard let end = scanUntil(text, after: i, terminator: "]]>") else { return nil }
                i = end
                continue
            }
            if matchesPrefix(text, at: i, "<?") {
                guard let end = scanUntil(text, after: i, terminator: "?>") else { return nil }
                i = end
                continue
            }
            if text[i] != "<" {
                i = text.index(after: i)
                continue
            }
            let afterLT = text.index(after: i)
            if afterLT < text.endIndex, text[afterLT] == "/" {
                // Closing tag.
                let nameStart = text.index(after: afterLT)
                var nameEnd = nameStart
                while nameEnd < text.endIndex, !text[nameEnd].isXMLNameTerminator {
                    nameEnd = text.index(after: nameEnd)
                }
                let closingName = String(text[nameStart..<nameEnd])
                guard let tagEnd = scanUntil(text, after: i, terminator: ">") else { return nil }
                if closingName == name {
                    depth -= 1
                    if depth == 0 { return tagEnd }
                }
                i = tagEnd
                continue
            }
            // Opening tag — find its end and decide if it is self-closing.
            guard let openEnd = findOpenTagEnd(in: text, from: i) else { return nil }
            let raw = text[i..<openEnd]
            if !raw.hasSuffix("/>") {
                depth += 1
            }
            i = openEnd
        }
        return nil
    }

    private func extractElementName(from openTag: String) -> String {
        var i = openTag.index(after: openTag.startIndex) // skip `<`
        let start = i
        while i < openTag.endIndex, !openTag[i].isXMLNameTerminator {
            i = openTag.index(after: i)
        }
        return String(openTag[start..<i])
    }

    // MARK: - Synthesis

    private func synthesizeDocument(
        prolog: String,
        rootOpen: String,
        rootName: String,
        body: [String]
    ) -> String {
        let joined = body.joined(separator: "\n")
        let trailing = "</\(rootName)>"
        // Some prologs end exactly at the start of the document root, with
        // no trailing whitespace — add a newline so the synthesised result
        // is easy to inspect during debugging.
        let separator = prolog.isEmpty || prolog.last == "\n" ? "" : "\n"
        return "\(prolog)\(separator)\(rootOpen)\n\(joined)\n\(trailing)"
    }

    // MARK: - String helpers

    private func skipWhitespace(_ text: String, _ i: inout String.Index) {
        while i < text.endIndex, text[i].isXMLWhitespace {
            i = text.index(after: i)
        }
    }

    private func matchesPrefix(_ text: String, at i: String.Index, _ prefix: String) -> Bool {
        var ti = i
        for ch in prefix {
            guard ti < text.endIndex, text[ti] == ch else { return false }
            ti = text.index(after: ti)
        }
        return true
    }

    /// Return the index immediately past the first occurrence of `terminator`
    /// at or after `start`. Used to skip comments / CDATA / PIs.
    private func scanUntil(_ text: String, after start: String.Index, terminator: String) -> String.Index? {
        var i = start
        let term = Array(terminator)
        while i < text.endIndex {
            var ti = i
            var match = true
            for ch in term {
                if ti >= text.endIndex || text[ti] != ch { match = false; break }
                ti = text.index(after: ti)
            }
            if match { return ti }
            i = text.index(after: i)
        }
        return nil
    }
}

private extension Character {
    var isXMLWhitespace: Bool { self == " " || self == "\n" || self == "\r" || self == "\t" }
    var isXMLNameTerminator: Bool {
        self == " " || self == "\n" || self == "\r" || self == "\t" ||
        self == ">" || self == "/" || self == "="
    }
}
