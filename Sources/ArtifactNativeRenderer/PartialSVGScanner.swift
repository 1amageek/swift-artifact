import Foundation

/// Reduces a streaming SVG payload to the largest prefix that forms a
/// well-balanced `<svg>...</svg>` document.
///
/// SVG is XML, so a flat search for the next `</tagName>` is incorrect when
/// the same element is nested (`<g><g>...</g></g>`) — it would close the
/// outer element at the inner closing tag. The scanner therefore maintains
/// a depth-tracked stack of open element names and only releases an element
/// when its matching close tag is observed at the same depth.
///
/// XML quoting rules are also respected: `>` inside attribute strings is
/// treated as content, and three forms of structured content are skipped
/// without being interpreted as element markup —
///
/// - XML comments: `<!-- ... -->`
/// - CDATA sections: `<![CDATA[ ... ]]>`
/// - Processing instructions: `<?xxx ... ?>`
///
/// Each of those three forms is byte-skipped to its closing delimiter so any
/// `<` / `>` characters they contain do not perturb the tag stack.
public enum PartialSVGScanner {
    /// Returns the largest renderable prefix, framed as a self-contained
    /// `<svg ...>...</svg>` document, or `nil` until the opening `<svg>` tag
    /// has streamed in full.
    public static func longestValidPrefix(_ source: String) -> String? {
        guard let svgStart = source.range(of: "<svg", options: .caseInsensitive)?.lowerBound else {
            return nil
        }
        let afterSvgTagPrefix = source.index(svgStart, offsetBy: 4)
        guard let openTagEnd = Self.scanToClosingAngle(in: source, from: afterSvgTagPrefix) else {
            // The opening `<svg ...>` tag hasn't finished streaming yet.
            return nil
        }
        // A self-closed root <svg ... /> stands on its own — no walk needed.
        let charBeforeAngle = source[source.index(before: openTagEnd)]
        if charBeforeAngle == "/" {
            return String(source[svgStart...openTagEnd])
        }
        let openTag = source[svgStart...openTagEnd]
        let contentStart = source.index(after: openTagEnd)
        let result = Self.walk(in: source, from: contentStart)
        let content = source[contentStart..<result.lastCompleted]
        if result.rootClosed {
            // The walker swallowed `</svg>` already.
            return "\(openTag)\(content)"
        }
        return "\(openTag)\(content)</svg>"
    }

    // MARK: - Walk

    private struct WalkResult {
        let lastCompleted: String.Index
        let rootClosed: Bool
    }

    private static func walk(in source: String, from start: String.Index) -> WalkResult {
        var stack: [String] = []
        var lastCompleted = start
        var i = start

        while i < source.endIndex {
            let c = source[i]
            if c != "<" {
                i = source.index(after: i)
                continue
            }

            let remaining = source[i...]

            // <!-- comment -->
            if remaining.hasPrefix("<!--") {
                let inner = source.index(i, offsetBy: 4)
                guard inner <= source.endIndex,
                      let endRange = source.range(
                          of: "-->",
                          range: inner..<source.endIndex
                      )
                else { break }
                let after = endRange.upperBound
                if stack.isEmpty { lastCompleted = after }
                i = after
                continue
            }

            // <![CDATA[ ... ]]>
            if remaining.hasPrefix("<![CDATA[") {
                let inner = source.index(i, offsetBy: 9)
                guard inner <= source.endIndex,
                      let endRange = source.range(
                          of: "]]>",
                          range: inner..<source.endIndex
                      )
                else { break }
                let after = endRange.upperBound
                if stack.isEmpty { lastCompleted = after }
                i = after
                continue
            }

            // <? processing instruction ?>
            if remaining.hasPrefix("<?") {
                let inner = source.index(i, offsetBy: 2)
                guard inner <= source.endIndex,
                      let endRange = source.range(
                          of: "?>",
                          range: inner..<source.endIndex
                      )
                else { break }
                let after = endRange.upperBound
                if stack.isEmpty { lastCompleted = after }
                i = after
                continue
            }

            // Regular element. Find its closing `>` while respecting
            // attribute quoting.
            guard let tagEnd = Self.scanToClosingAngle(in: source, from: i) else {
                // Tag is still streaming — drop it and stop here.
                break
            }
            let tag = source[i...tagEnd]
            let afterTag = source.index(after: tagEnd)

            if tag.hasPrefix("</") {
                let name = Self.extractEndTagName(tag).lowercased()
                if stack.isEmpty {
                    if name == "svg" {
                        // The streaming root has just closed.
                        return WalkResult(lastCompleted: afterTag, rootClosed: true)
                    }
                    // Stray end tag with nothing open — malformed; stop.
                    break
                }
                if stack[stack.count - 1] != name {
                    // Mismatched nesting — stop at the last balanced point.
                    break
                }
                stack.removeLast()
                if stack.isEmpty { lastCompleted = afterTag }
                i = afterTag
                continue
            }

            if tag.dropLast().hasSuffix("/") {
                // Self-closing element.
                if stack.isEmpty { lastCompleted = afterTag }
                i = afterTag
                continue
            }

            // Opening tag for a container element.
            let name = Self.extractStartTagName(tag).lowercased()
            guard !name.isEmpty else { break }
            stack.append(name)
            i = afterTag
        }

        return WalkResult(lastCompleted: lastCompleted, rootClosed: false)
    }

    // MARK: - Helpers

    private static func scanToClosingAngle(
        in source: String,
        from start: String.Index
    ) -> String.Index? {
        var i = start
        var quote: Character? = nil
        while i < source.endIndex {
            let c = source[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            }
            i = source.index(after: i)
        }
        return nil
    }

    private static func extractStartTagName(_ tag: Substring) -> String {
        // tag form: "<name attr=..." or "<name>" or "<name/>"
        var iter = tag.makeIterator()
        guard let first = iter.next(), first == "<" else { return "" }
        var name = ""
        while let c = iter.next() {
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "/" || c == ">" {
                break
            }
            name.append(c)
        }
        return name
    }

    private static func extractEndTagName(_ tag: Substring) -> String {
        // tag form: "</name>" or "</name >"
        var iter = tag.makeIterator()
        guard iter.next() == "<", iter.next() == "/" else { return "" }
        var name = ""
        while let c = iter.next() {
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == ">" {
                break
            }
            name.append(c)
        }
        return name
    }
}
