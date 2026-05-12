import Foundation

/// Tokenizes `key="value"` / `key='value'` attribute pairs out of an open-tag body.
struct AttributeScanner {
    private let input: String
    private var index: String.Index

    init(input: String) {
        self.input = input
        self.index = input.startIndex
    }

    mutating func nextAttribute() -> (key: String, value: String)? {
        skipWhitespace()
        guard index < input.endIndex else { return nil }

        // Read key until '=' or whitespace.
        let keyStart = index
        while index < input.endIndex,
              input[index] != "=",
              !input[index].isWhitespace {
            index = input.index(after: index)
        }
        let key = String(input[keyStart..<index])
        guard !key.isEmpty else { return nil }

        skipWhitespace()
        guard index < input.endIndex, input[index] == "=" else {
            // Boolean-style attribute (`disabled`) — not used by artifacts, skip.
            return nil
        }
        index = input.index(after: index)
        skipWhitespace()
        guard index < input.endIndex else { return nil }

        let quote = input[index]
        guard quote == "\"" || quote == "'" else { return nil }
        index = input.index(after: index)

        let valueStart = index
        while index < input.endIndex, input[index] != quote {
            index = input.index(after: index)
        }
        guard index < input.endIndex else { return nil }

        let value = String(input[valueStart..<index])
        index = input.index(after: index)  // consume closing quote
        return (key, decodeXMLEntities(value))
    }

    private mutating func skipWhitespace() {
        while index < input.endIndex, input[index].isWhitespace {
            index = input.index(after: index)
        }
    }

    private func decodeXMLEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        return raw
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
