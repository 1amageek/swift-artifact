import Foundation

/// Returns the longest prefix of `source` that parses as valid JSON, or `nil`
/// if no prefix parses.
///
/// Strategy: walk forward, tracking string-quote, escape and container depth.
/// Each frame remembers the most recent index where its content was at a
/// "safe to truncate" boundary — just after a completed key-value pair
/// (object) or completed element (array). At end-of-input we pick the deepest
/// frame that has *any* completed child and rebuild a valid JSON document by
/// closing the frames at and above that depth.
public enum PartialJSONScanner {
    public static func longestValidPrefix(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Fast path: the full payload is already valid.
        if let _ = try? JSONSerialization.jsonObject(
            with: Data(trimmed.utf8),
            options: [.fragmentsAllowed]
        ) {
            return trimmed
        }
        return walk(trimmed)
    }

    private enum Container {
        case object
        case array
    }

    private struct Frame {
        var kind: Container
        /// Byte offset (into `bytes`) of the last position where this frame's
        /// content was at a "safe to truncate" boundary. `-1` means no
        /// completed child yet — cutting here would yield an empty container.
        var lastSafeBoundary: Int
    }

    private static func walk(_ source: String) -> String? {
        let bytes = Array(source.utf8)
        var stack: [Frame] = []
        var inString = false
        var escape = false
        var awaitingValue = false
        var lastCompleteRootEnd: Int? = nil
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escape {
                    escape = false
                } else if byte == 0x5C { // backslash
                    escape = true
                } else if byte == 0x22 { // closing quote
                    inString = false
                    if let last = stack.last, last.kind == .object, !awaitingValue {
                        // Just read a key string. Now awaiting `:` then a value.
                        awaitingValue = true
                    } else if let last = stack.last, last.kind == .object, awaitingValue {
                        // Just read a string value — pair complete.
                        stack[stack.count - 1].lastSafeBoundary = index + 1
                        awaitingValue = false
                    } else if stack.last?.kind == .array {
                        stack[stack.count - 1].lastSafeBoundary = index + 1
                    } else if stack.isEmpty {
                        lastCompleteRootEnd = index + 1
                    }
                }
                index += 1
                continue
            }

            switch byte {
            case 0x22: // "
                inString = true
            case 0x7B: // {
                stack.append(Frame(kind: .object, lastSafeBoundary: -1))
                awaitingValue = false
            case 0x5B: // [
                stack.append(Frame(kind: .array, lastSafeBoundary: -1))
            case 0x7D, 0x5D: // } ]
                if stack.isEmpty { return nil }
                stack.removeLast()
                if stack.isEmpty {
                    lastCompleteRootEnd = index + 1
                } else {
                    stack[stack.count - 1].lastSafeBoundary = index + 1
                    if stack.last?.kind == .object {
                        awaitingValue = false
                    }
                }
            case 0x2C: // ,
                if let last = stack.last {
                    stack[stack.count - 1].lastSafeBoundary = index
                    awaitingValue = (last.kind == .object) ? false : awaitingValue
                }
            case 0x3A: // :
                awaitingValue = true
            default:
                break
            }
            index += 1
        }

        if stack.isEmpty {
            if let end = lastCompleteRootEnd {
                return String(decoding: bytes[0..<end], as: UTF8.self)
            }
            return nil
        }

        // Find the deepest frame with at least one completed child. Outer
        // frames cannot have progressed past the opening of an inner frame, so
        // the deepest progressed frame yields the latest safe cut position.
        var cutDepth = -1
        for i in 0..<stack.count {
            if stack[i].lastSafeBoundary >= 0 {
                cutDepth = i
            }
        }
        guard cutDepth >= 0 else { return nil }

        let cutAt = stack[cutDepth].lastSafeBoundary
        var rebuilt = Array(bytes[0..<cutAt])
        while let tail = rebuilt.last, tail == 0x2C || tail == 0x3A || isWhitespace(tail) {
            rebuilt.removeLast()
        }
        for i in stride(from: cutDepth, through: 0, by: -1) {
            rebuilt.append(stack[i].kind == .object ? 0x7D : 0x5D)
        }
        let candidate = String(decoding: rebuilt, as: UTF8.self)
        if let _ = try? JSONSerialization.jsonObject(
            with: Data(candidate.utf8),
            options: [.fragmentsAllowed]
        ) {
            return candidate
        }
        return nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
