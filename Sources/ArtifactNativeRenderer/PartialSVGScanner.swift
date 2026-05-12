import Foundation

/// Reduces a streaming SVG payload to the largest valid prefix the renderer
/// can draw.
///
/// A streaming SVG might be received as `<svg ...><circle.../><rec` — the
/// trailing `<rec` is a half-emitted element that browsers / decoders treat
/// as malformed. The scanner trims everything after the last fully closed
/// element inside the root `<svg>` and re-appends `</svg>`.
public enum PartialSVGScanner {
    /// Returns `nil` until the opening `<svg ...>` tag has been seen in full.
    /// Once it has, returns a self-contained SVG string: the opening tag, the
    /// completed child elements, and a synthetic `</svg>` close.
    public static func longestValidPrefix(_ source: String) -> String? {
        guard let openRange = source.range(of: "<svg", options: .caseInsensitive) else {
            return nil
        }
        guard let openEnd = closingAngleOfTag(in: source, from: openRange.lowerBound) else {
            // The opening tag itself is still streaming.
            return nil
        }
        // If the closing </svg> is already present, hand back the full slice.
        if let closeRange = source.range(of: "</svg>", options: .caseInsensitive) {
            return String(source[openRange.lowerBound...closeRange.upperBound])
        }

        let contentStart = source.index(after: openEnd)
        let content = source[contentStart...]
        // Walk the children, tracking the last index after a completed element.
        var index = content.startIndex
        var lastCompleted = index
        while index < content.endIndex {
            let char = content[index]
            if char == "<" {
                // Look for matching `>` that is not inside an attribute string.
                guard let closeIndex = closingAngleOfTag(in: content, from: index) else {
                    // Tag is incomplete — stop here.
                    break
                }
                let tag = content[index...closeIndex]
                if tag.hasPrefix("</") {
                    // End tag for the most recently opened element.
                    lastCompleted = content.index(after: closeIndex)
                } else if tag.hasSuffix("/>") {
                    // Self-closing element.
                    lastCompleted = content.index(after: closeIndex)
                } else {
                    // Open tag for a container. Skip ahead to the matching
                    // closing tag if it has fully arrived; otherwise stop.
                    let tagName = extractTagName(tag)
                    guard !tagName.isEmpty else {
                        break
                    }
                    let closingNeedle = "</\(tagName)>"
                    let searchStart = content.index(after: closeIndex)
                    guard let endRange = content.range(
                        of: closingNeedle,
                        options: .caseInsensitive,
                        range: searchStart..<content.endIndex
                    ) else {
                        break
                    }
                    lastCompleted = endRange.upperBound
                    index = endRange.upperBound
                    continue
                }
                index = content.index(after: closeIndex)
            } else {
                // Treat whitespace / text content as part of the previous
                // element — only flush lastCompleted when we close a tag.
                index = content.index(after: index)
            }
        }
        let trimmedChildren = content[..<lastCompleted]
        return "\(source[openRange.lowerBound...openEnd])\(trimmedChildren)</svg>"
    }

    private static func closingAngleOfTag(
        in source: some StringProtocol,
        from start: String.Index
    ) -> String.Index? {
        var index = start
        var insideAttribute = false
        var quoteChar: Character = " "
        while index < source.endIndex {
            let char = source[index]
            if insideAttribute {
                if char == quoteChar { insideAttribute = false }
            } else if char == "\"" || char == "'" {
                insideAttribute = true
                quoteChar = char
            } else if char == ">" {
                return index
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func extractTagName(_ tag: Substring) -> String {
        // tag form: "<name attr=..." or "<name>" — strip leading '<' and stop
        // at the first whitespace / '>' / '/'.
        var iterator = tag.makeIterator()
        guard let first = iterator.next(), first == "<" else { return "" }
        var name = ""
        while let char = iterator.next() {
            if char == " " || char == "\t" || char == "\n" || char == "\r" || char == "/" || char == ">" {
                break
            }
            name.append(char)
        }
        return name
    }
}
