import Foundation

/// Reduces a streaming HTML payload to the largest prefix whose tail does
/// not bisect a token. Browsers tolerate unclosed elements, so the scanner
/// trusts them to keep rendering — element nesting is **not** validated and
/// close tags are **not** synthesized.
///
/// The cases the scanner does enforce:
///
/// - **Incomplete tag at the tail.** `<div class="hea` is dropped wholesale
///   until the matching `>` arrives. Browsers will otherwise keep reading
///   past the buffer looking for the close, swallowing later content.
/// - **Raw-text elements** (`<script>` / `<style>`). Their content is not
///   parsed as HTML by the browser — a half-streamed `<script>foo(` leaves
///   the parser in raw-text mode and every subsequent token becomes script
///   payload. The scanner therefore requires the matching `</script>` /
///   `</style>` end tag to be present in full before admitting the block.
/// - **Markup declarations** (`<!-- ... -->`, `<![CDATA[ ... ]]>`,
///   `<!DOCTYPE ...>`, `<? ... ?>`). Each is byte-skipped to its closing
///   delimiter; an unterminated one stops the walk so its body never leaks
///   into the renderable prefix.
/// - **Attribute quoting.** `>` inside `"..."` / `'...'` is treated as
///   content while locating the closing `>` of a tag.
///
/// The output is always a literal prefix of the input.
public enum PartialHTMLScanner {

    /// Returns the largest prefix of `source` that contains no half-typed
    /// token, or `nil` while nothing has streamed in yet.
    ///
    /// The prefix is intentionally not balanced: open tags inside it may
    /// still have no matching close. `WKWebView` handles unclosed
    /// containers gracefully, so the scanner errs on the side of emitting
    /// content the moment its own token completes.
    public static func longestValidPrefix(_ source: String) -> String? {
        var i = source.startIndex
        var lastCompleted = source.startIndex

        while i < source.endIndex {
            let c = source[i]

            if c != "<" {
                // Plain text is complete one character at a time. Browsers
                // happily render partial text nodes.
                i = source.index(after: i)
                lastCompleted = i
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
                i = endRange.upperBound
                lastCompleted = i
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
                i = endRange.upperBound
                lastCompleted = i
                continue
            }

            // <!DOCTYPE ...> and other markup declarations: ends at the
            // first `>`.
            if remaining.hasPrefix("<!") {
                let inner = source.index(i, offsetBy: 2)
                guard let tagEnd = Self.scanToClosingAngle(
                    in: source,
                    from: inner
                ) else { break }
                i = source.index(after: tagEnd)
                lastCompleted = i
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
                i = endRange.upperBound
                lastCompleted = i
                continue
            }

            // Regular element tag. Find its closing `>` while respecting
            // attribute quoting.
            guard let tagEnd = Self.scanToClosingAngle(
                in: source,
                from: i
            ) else {
                // Tag is still streaming — drop the half-typed tail.
                break
            }
            let tag = source[i...tagEnd]
            let afterTag = source.index(after: tagEnd)

            // Raw-text element guard. `<script>` / `<style>` switch the
            // browser into a mode where only the matching end tag can
            // close them, so we must keep them whole or drop the block.
            if !tag.hasPrefix("</") {
                let name = Self.extractStartTagName(tag).lowercased()
                let isXMLSelfClosing = tag.dropLast().hasSuffix("/")
                if !isXMLSelfClosing, Self.rawTextElements.contains(name) {
                    guard let closingRange = Self.findRawTextCloseTag(
                        name: name,
                        in: source,
                        from: afterTag
                    ) else {
                        // Matching close tag has not streamed in yet —
                        // drop the open tag and everything after it.
                        break
                    }
                    i = closingRange.upperBound
                    lastCompleted = i
                    continue
                }
            }

            // Normal complete tag. Element-stack validation is skipped on
            // purpose; `WKWebView` will handle implicit closes.
            i = afterTag
            lastCompleted = i
        }

        return lastCompleted == source.startIndex
            ? nil
            : String(source[..<lastCompleted])
    }

    // MARK: - Constants

    /// Elements whose content is parsed as raw text rather than as HTML.
    /// `textarea` and `title` are intentionally omitted from the MVP — a
    /// half-streamed text area renders as visible literal text rather than
    /// hijacking the parser, so it is not a correctness hazard.
    private static let rawTextElements: Set<String> = ["script", "style"]

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

    /// Locates the next `</name>` (case-insensitive) that the HTML
    /// tokenizer would accept as a raw-text end tag. The character that
    /// follows the name must be one of ` \t\n\r/>` so that `</styles>`
    /// does not accidentally close a `<style>` block.
    private static func findRawTextCloseTag(
        name: String,
        in source: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        let pattern = "</\(name)"
        var searchStart = start
        while searchStart < source.endIndex {
            guard let prefixRange = source.range(
                of: pattern,
                options: .caseInsensitive,
                range: searchStart..<source.endIndex
            ) else { return nil }
            let after = prefixRange.upperBound
            if after < source.endIndex {
                let next = source[after]
                let isBoundary = next == ">" || next == "/" ||
                    next == " " || next == "\t" ||
                    next == "\n" || next == "\r"
                if !isBoundary {
                    // `</styles>` for `style`, etc. Skip and keep looking.
                    searchStart = source.index(after: prefixRange.lowerBound)
                    continue
                }
            } else {
                // `</style` at EOF — close tag hasn't fully streamed.
                return nil
            }
            guard let angle = Self.scanToClosingAngle(
                in: source,
                from: after
            ) else { return nil }
            return prefixRange.lowerBound..<source.index(after: angle)
        }
        return nil
    }
}
