import Foundation

/// Tolerant JSON AST representation that distinguishes "container that is
/// still being populated" from "container whose closing token has been seen".
///
/// `array(_, complete:)` and `object(_, complete:)` carry an explicit
/// `complete` flag so a partial-aware consumer can reason about whether more
/// members may yet arrive without having to re-parse the source.
enum PartialJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    indirect case array([PartialJSONValue], complete: Bool)
    indirect case object([(key: String, value: PartialJSONValue)], complete: Bool)

    static func == (lhs: PartialJSONValue, rhs: PartialJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a, let ac), .array(let b, let bc)):
            return ac == bc && a == b
        case (.object(let a, let ac), .object(let b, let bc)):
            guard ac == bc, a.count == b.count else { return false }
            for (lhs, rhs) in zip(a, b) {
                if lhs.key != rhs.key || lhs.value != rhs.value { return false }
            }
            return true
        default:
            return false
        }
    }
}

/// Streaming-tolerant JSON parser.
///
/// The W3C JSON grammar requires every container to be closed; an LLM
/// streaming response trivially produces inputs that violate that. This
/// parser instead consumes as much of the source as it can interpret as a
/// well-formed prefix and reports whether each container saw its closing
/// token. The shape is adapted from `swift-generation`'s `GeneratedContent`
/// `PartialJSON`, generalised to return our own `PartialJSONValue` AST so
/// nothing in this module has to depend on `GeneratedContent`.
///
/// Guarantees:
///   - Calling `parse` on a longer prefix of the same source produces an AST
///     whose previously-seen members compare equal — letting the JSON-LD
///     stage downstream warm-restart over the partial graph.
///   - Strings whose closing `"` has not yet arrived are returned with the
///     characters seen so far (`allowPartial: true`). Numeric tails with
///     unfinished exponents are truncated to the last syntactically valid
///     prefix.
///   - Unsupported escape sequences or malformed unicode pairs terminate the
///     scan; no recovery is attempted past that point.
enum PartialJSON {

    /// Parse `source` into a partial AST. An empty / whitespace-only source
    /// returns `.null`.
    static func parse(_ source: String) -> PartialJSONValue {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .null }
        var i = trimmed.startIndex
        if let value = scanValue(trimmed, &i) {
            return value
        }
        return .null
    }

    // MARK: - Top-level extractors

    static func extractObject(_ source: String) -> (members: [(key: String, value: PartialJSONValue)], complete: Bool) {
        var i = source.startIndex
        skipWS(source, &i)
        guard peek(source, i) == "{" else { return ([], false) }
        bump(&i, in: source)
        return parseObjectBody(source, &i)
    }

    static func extractArray(_ source: String) -> (elements: [PartialJSONValue], complete: Bool) {
        var i = source.startIndex
        skipWS(source, &i)
        guard peek(source, i) == "[" else { return ([], false) }
        bump(&i, in: source)
        return parseArrayBody(source, &i)
    }

    // MARK: - Scanners

    private static func scanValue(_ s: String, _ i: inout String.Index) -> PartialJSONValue? {
        skipWS(s, &i)
        guard let c = peek(s, i) else { return nil }
        switch c {
        case "\"":
            if let str = scanString(s, &i, allowPartial: true) { return .string(str) }
            return nil
        case "-", "0"..."9":
            if let (num, consumedTo) = scanNumber(s, i) {
                i = consumedTo
                return .number(num)
            }
            return nil
        case "t":
            if scanLiteral(s, &i, "true") { return .bool(true) }
            return nil
        case "f":
            if scanLiteral(s, &i, "false") { return .bool(false) }
            return nil
        case "n":
            if scanLiteral(s, &i, "null") { return .null }
            return nil
        case "{":
            bump(&i, in: s)
            let body = parseObjectBody(s, &i)
            return .object(body.members, complete: body.complete)
        case "[":
            bump(&i, in: s)
            let body = parseArrayBody(s, &i)
            return .array(body.elements, complete: body.complete)
        default:
            return nil
        }
    }

    private static func parseObjectBody(
        _ s: String,
        _ i: inout String.Index
    ) -> (members: [(key: String, value: PartialJSONValue)], complete: Bool) {
        var members: [(String, PartialJSONValue)] = []
        skipWS(s, &i)
        if peek(s, i) == "}" {
            bump(&i, in: s)
            return (members, true)
        }
        while i < s.endIndex {
            skipWS(s, &i)
            guard let key = scanString(s, &i, allowPartial: false) else { break }
            skipWS(s, &i)
            guard peek(s, i) == ":" else { break }
            bump(&i, in: s)
            skipWS(s, &i)
            guard let value = scanValue(s, &i) else { break }
            members.append((key, value))
            skipWS(s, &i)
            if peek(s, i) == "," { bump(&i, in: s); continue }
            if peek(s, i) == "}" { bump(&i, in: s); return (members, true) }
            break
        }
        return (members, false)
    }

    private static func parseArrayBody(
        _ s: String,
        _ i: inout String.Index
    ) -> (elements: [PartialJSONValue], complete: Bool) {
        var elements: [PartialJSONValue] = []
        skipWS(s, &i)
        if peek(s, i) == "]" {
            bump(&i, in: s)
            return (elements, true)
        }
        while i < s.endIndex {
            guard let value = scanValue(s, &i) else { break }
            elements.append(value)
            skipWS(s, &i)
            if peek(s, i) == "," { bump(&i, in: s); continue }
            if peek(s, i) == "]" { bump(&i, in: s); return (elements, true) }
            break
        }
        return (elements, false)
    }

    private static func scanString(_ s: String, _ i: inout String.Index, allowPartial: Bool) -> String? {
        guard peek(s, i) == "\"" else { return nil }
        bump(&i, in: s)
        var out = ""
        while i < s.endIndex {
            let c = s[i]
            bump(&i, in: s)
            if c == "\"" { return out }
            if c == "\\" {
                guard i < s.endIndex else { return allowPartial ? out : nil }
                let e = s[i]
                bump(&i, in: s)
                switch e {
                case "\"", "\\", "/": out.append(e)
                case "b": out.append("\u{0008}")
                case "f": out.append("\u{000C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    var hex = ""
                    for _ in 0..<4 {
                        guard i < s.endIndex else { return allowPartial ? out : nil }
                        hex.append(s[i])
                        bump(&i, in: s)
                    }
                    guard let scalar = UInt32(hex, radix: 16) else { return allowPartial ? out : nil }
                    if (0xD800...0xDBFF).contains(scalar) {
                        let save = i
                        guard i < s.endIndex, s[i] == "\\" else { return allowPartial ? out : nil }
                        bump(&i, in: s)
                        guard i < s.endIndex, s[i] == "u" else {
                            i = save
                            return allowPartial ? out : nil
                        }
                        bump(&i, in: s)
                        var hex2 = ""
                        for _ in 0..<4 {
                            guard i < s.endIndex else { return allowPartial ? out : nil }
                            hex2.append(s[i])
                            bump(&i, in: s)
                        }
                        guard
                            let low = UInt32(hex2, radix: 16),
                            (0xDC00...0xDFFF).contains(low)
                        else { return allowPartial ? out : nil }
                        let highPart = scalar - 0xD800
                        let lowPart = low - 0xDC00
                        let codepoint = 0x10000 + (highPart << 10) + lowPart
                        if let u = UnicodeScalar(codepoint) {
                            out.append(Character(u))
                        } else {
                            return allowPartial ? out : nil
                        }
                    } else if let u = UnicodeScalar(scalar) {
                        out.append(Character(u))
                    } else {
                        return allowPartial ? out : nil
                    }
                default:
                    return allowPartial ? out : nil
                }
            } else {
                out.append(c)
            }
        }
        return allowPartial ? out : nil
    }

    private static func scanNumber(_ s: String, _ start: String.Index) -> (Double, String.Index)? {
        var i = start
        let begin = i
        if peek(s, i) == "-" { bump(&i, in: s) }
        guard let d0 = peek(s, i), d0.isJSONDigit else { return nil }
        if d0 == "0" {
            bump(&i, in: s)
        } else {
            while let d = peek(s, i), d.isJSONDigit { bump(&i, in: s) }
        }
        var lastValid = i
        if peek(s, i) == "." {
            let dot = i
            bump(&i, in: s)
            guard let d = peek(s, i), d.isJSONDigit else {
                if let v = Double(String(s[begin..<dot])) { return (v, dot) }
                return nil
            }
            while let d = peek(s, i), d.isJSONDigit { bump(&i, in: s) }
            lastValid = i
        }
        if let e = peek(s, i), e == "e" || e == "E" {
            let epos = i
            bump(&i, in: s)
            if let sign = peek(s, i), sign == "+" || sign == "-" { bump(&i, in: s) }
            guard let d = peek(s, i), d.isJSONDigit else {
                if lastValid > begin, let v = Double(String(s[begin..<lastValid])) {
                    return (v, lastValid)
                }
                if let v = Double(String(s[begin..<epos])) { return (v, epos) }
                return nil
            }
            while let d = peek(s, i), d.isJSONDigit { bump(&i, in: s) }
            lastValid = i
        }
        let slice = String(s[begin..<lastValid])
        if let v = Double(slice) { return (v, lastValid) }
        return nil
    }

    private static func scanLiteral(_ s: String, _ i: inout String.Index, _ lit: String) -> Bool {
        var j = i
        for ch in lit {
            guard let c = peek(s, j), c == ch else { return false }
            bump(&j, in: s)
        }
        i = j
        return true
    }

    // MARK: - Cursor primitives

    private static func peek(_ s: String, _ i: String.Index) -> Character? {
        i < s.endIndex ? s[i] : nil
    }

    private static func bump(_ i: inout String.Index, in s: String) {
        i = s.index(after: i)
    }

    private static func skipWS(_ s: String, _ i: inout String.Index) {
        while let c = peek(s, i), c.isJSONWhitespace { bump(&i, in: s) }
    }
}

private extension Character {
    var isJSONDigit: Bool { ("0"..."9").contains(self) }
    var isJSONWhitespace: Bool { self == " " || self == "\n" || self == "\r" || self == "\t" }
}
