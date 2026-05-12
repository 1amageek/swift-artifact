import Foundation

/// Reduces a streaming JSON payload to the longest prefix that parses as a
/// complete JSON document.
///
/// The scanner runs a tokenizer that distinguishes structural bytes, strings
/// (with escape sequences), numbers, and the three keyword literals
/// (`true` / `false` / `null`). It tracks per-container completion: each frame
/// remembers the byte offset immediately after the most recently completed
/// value, so trailing incomplete content can be dropped and the open frames
/// re-closed with synthetic `}` / `]` bytes.
///
/// Key correctness properties:
///
/// - A bare top-level number, boolean, or null is rejected while streaming —
///   the next byte could extend the literal (`42` → `423`, `tru` → `true`).
///   Only structural roots (`{` or `[`) take the fast path.
/// - Keyword literals (`true` / `false` / `null`) are recognized exactly so
///   `{"a":true,"b":1` becomes `{"a":true}` instead of being held back.
/// - Numbers complete only when followed by a non-numeric byte. The trailing
///   number in `{"a":1,"b":2` is dropped because we cannot prove `2` isn't
///   `25`.
/// - Every returned prefix is re-validated via `JSONSerialization` so any
///   scanner bug downgrades to "not yet renderable" rather than to invalid
///   output.
public enum PartialJSONScanner {
    public static func longestValidPrefix(_ source: String) -> String? {
        let bytes = Array(source.utf8)
        guard let firstIdx = bytes.firstIndex(where: { !Self.isWhitespace($0) }) else {
            return nil
        }
        // Fast path: only structural roots can be returned wholesale. Bare
        // values (numbers, literals, strings) at the top level might still be
        // streaming, so they must go through the walker which is conservative
        // about open-ended tokens.
        let firstByte = bytes[firstIdx]
        if (firstByte == 0x7B || firstByte == 0x5B), Self.isValidJSON(bytes: bytes) {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return Self.walk(bytes: bytes)
    }

    // MARK: - State

    private enum Container {
        case object
        case array
    }

    private struct Frame {
        var kind: Container
        /// Byte offset of the position immediately AFTER the most recently
        /// completed value within this container. `-1` means "nothing inside
        /// this frame is renderable yet".
        var lastSafeBoundary: Int
        /// For object frames: `true` after the `:` separator, indicating the
        /// next value to appear belongs to the current key. Array frames
        /// never look at this field.
        var awaitingValue: Bool
    }

    private enum LiteralKind {
        case `true`, `false`, null

        var bytes: [UInt8] {
            switch self {
            case .true:  return [0x74, 0x72, 0x75, 0x65]                   // "true"
            case .false: return [0x66, 0x61, 0x6C, 0x73, 0x65]             // "false"
            case .null:  return [0x6E, 0x75, 0x6C, 0x6C]                   // "null"
            }
        }
    }

    private enum Mode {
        case between
        case inString
        case inEscape
        case inNumber
        case inLiteral(kind: LiteralKind, offset: Int)
    }

    // MARK: - Walker

    private static func walk(bytes: [UInt8]) -> String? {
        var stack: [Frame] = []
        var rootEnd: Int? = nil
        var mode: Mode = .between
        var i = 0
        var stop = false

        func completeStringValue(endingAt end: Int) {
            if stack.isEmpty {
                rootEnd = end
                return
            }
            let depth = stack.count - 1
            switch stack[depth].kind {
            case .object:
                if stack[depth].awaitingValue {
                    stack[depth].lastSafeBoundary = end
                    stack[depth].awaitingValue = false
                }
                // Otherwise the string was a key — nothing to mark; we
                // remain in "awaiting `:`" semantics (awaitingValue stays
                // false until the colon flips it).
            case .array:
                stack[depth].lastSafeBoundary = end
            }
        }

        func completeNonStringValue(endingAt end: Int) {
            if stack.isEmpty {
                rootEnd = end
                return
            }
            let depth = stack.count - 1
            switch stack[depth].kind {
            case .object:
                if stack[depth].awaitingValue {
                    stack[depth].lastSafeBoundary = end
                    stack[depth].awaitingValue = false
                } else {
                    // Non-string in a key slot — malformed JSON. Stop and
                    // let the recovery path emit whatever was confirmed
                    // before this point.
                    stop = true
                }
            case .array:
                stack[depth].lastSafeBoundary = end
            }
        }

        while i < bytes.count && !stop {
            let b = bytes[i]
            switch mode {
            case .inString:
                if b == 0x22 {                       // closing "
                    mode = .between
                    completeStringValue(endingAt: i + 1)
                    i += 1
                } else if b == 0x5C {                // backslash
                    mode = .inEscape
                    i += 1
                } else {
                    i += 1
                }

            case .inEscape:
                // Consume any single byte as the escaped char. JSON allows
                // \" \\ \/ \b \f \n \r \t and \uXXXX; we don't need to
                // validate the escape, only ensure the next byte isn't
                // interpreted as a string terminator.
                mode = .inString
                i += 1

            case .inNumber:
                if Self.isNumberContinuation(b) {
                    i += 1
                } else {
                    // Number ended at index i (the current byte is the
                    // separator and is reprocessed below).
                    mode = .between
                    completeNonStringValue(endingAt: i)
                }

            case .inLiteral(let kind, let offset):
                let expected = kind.bytes
                if offset >= expected.count {
                    // Defensive: shouldn't be reachable.
                    mode = .between
                    completeNonStringValue(endingAt: i)
                    continue
                }
                if expected[offset] == b {
                    let next = offset + 1
                    if next == expected.count {
                        mode = .between
                        completeNonStringValue(endingAt: i + 1)
                    } else {
                        mode = .inLiteral(kind: kind, offset: next)
                    }
                    i += 1
                } else {
                    stop = true
                }

            case .between:
                if Self.isWhitespace(b) { i += 1; continue }
                switch b {
                case 0x7B:                           // {
                    stack.append(Frame(kind: .object, lastSafeBoundary: -1, awaitingValue: false))
                    i += 1
                case 0x5B:                           // [
                    stack.append(Frame(kind: .array, lastSafeBoundary: -1, awaitingValue: false))
                    i += 1
                case 0x7D:                           // }
                    guard let last = stack.last, last.kind == .object else {
                        stop = true
                        continue
                    }
                    stack.removeLast()
                    completeNonStringValue(endingAt: i + 1)
                    i += 1
                case 0x5D:                           // ]
                    guard let last = stack.last, last.kind == .array else {
                        stop = true
                        continue
                    }
                    stack.removeLast()
                    completeNonStringValue(endingAt: i + 1)
                    i += 1
                case 0x2C:                           // ,
                    guard let last = stack.last else { stop = true; continue }
                    if last.kind == .object && stack[stack.count - 1].awaitingValue {
                        // `:` was seen but no value arrived before the
                        // comma — malformed.
                        stop = true
                        continue
                    }
                    // In objects a comma transitions us back to "awaiting
                    // key" (awaitingValue=false). It already is false at
                    // this point because completing the previous value
                    // cleared it. Array commas are pure separators.
                    i += 1
                case 0x3A:                           // :
                    guard let last = stack.last, last.kind == .object else {
                        stop = true
                        continue
                    }
                    if stack[stack.count - 1].awaitingValue {
                        // `::` or `: :` — malformed.
                        stop = true
                        continue
                    }
                    stack[stack.count - 1].awaitingValue = true
                    i += 1
                case 0x22:                           // "
                    mode = .inString
                    i += 1
                case 0x74:                           // t
                    mode = .inLiteral(kind: .true, offset: 1)
                    i += 1
                case 0x66:                           // f
                    mode = .inLiteral(kind: .false, offset: 1)
                    i += 1
                case 0x6E:                           // n
                    mode = .inLiteral(kind: .null, offset: 1)
                    i += 1
                case 0x30...0x39, 0x2D:              // 0-9, -
                    mode = .inNumber
                    i += 1
                default:
                    stop = true
                }
            }
        }

        // Recovery: either the root is fully closed or we have at least one
        // frame on the stack with a confirmed value to truncate at.
        if stack.isEmpty, let end = rootEnd {
            let candidate = String(decoding: bytes[0..<end], as: UTF8.self)
            return Self.isValidJSON(bytes: Array(candidate.utf8)) ? candidate : nil
        }

        var cutDepth = -1
        for d in 0..<stack.count where stack[d].lastSafeBoundary >= 0 {
            cutDepth = d
        }
        guard cutDepth >= 0 else { return nil }

        let cutAt = stack[cutDepth].lastSafeBoundary
        var rebuilt = Array(bytes[0..<cutAt])
        while let tail = rebuilt.last, Self.isWhitespace(tail) {
            rebuilt.removeLast()
        }
        for d in stride(from: cutDepth, through: 0, by: -1) {
            rebuilt.append(stack[d].kind == .object ? 0x7D : 0x5D)
        }
        return Self.isValidJSON(bytes: rebuilt)
            ? String(decoding: rebuilt, as: UTF8.self)
            : nil
    }

    // MARK: - Helpers

    private static func isWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    private static func isNumberContinuation(_ b: UInt8) -> Bool {
        // digits, decimal point, exponent marker, sign
        (b >= 0x30 && b <= 0x39) || b == 0x2E || b == 0x65 || b == 0x45 || b == 0x2B || b == 0x2D
    }

    private static func isValidJSON(bytes: [UInt8]) -> Bool {
        do {
            _ = try JSONSerialization.jsonObject(
                with: Data(bytes),
                options: [.fragmentsAllowed]
            )
            return true
        } catch {
            return false
        }
    }
}
