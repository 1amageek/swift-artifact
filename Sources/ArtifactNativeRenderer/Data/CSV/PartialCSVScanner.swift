import Foundation

/// Reduces a streaming CSV payload to the largest prefix that ends on a
/// quote-aware row boundary.
///
/// The naive approach — cutting at the last `\n` — corrupts RFC 4180 CSV
/// because newlines are legal *inside* a quoted field:
///
/// ```
/// name,bio
/// "Alice","Loves
/// hiking"
/// ```
///
/// Truncating at any `\n` would split the second logical row in half and
/// leave an unclosed quote in the prefix. This scanner walks the source
/// byte by byte, tracking whether each byte is inside a quoted field, and
/// only records row terminators that appear at quote depth zero. The
/// escape sequence `""` (a literal quote inside a quoted field) is honored
/// as well.
///
/// Byte-level iteration is required because Swift treats `\r\n` as a single
/// extended grapheme cluster — a `Character` walk would see `"\r\n"` as one
/// element and miss both the `\r` and the `\n` cases. All structural CSV
/// bytes (`,` `"` `\r` `\n`) are single-byte ASCII so this is safe.
public enum PartialCSVScanner {
    public static func longestValidPrefix(_ source: String) -> String? {
        let bytes = Array(source.utf8)
        var state: State = .between
        var lastRowEnd: Int? = nil
        var i = 0

        while i < bytes.count {
            let b = bytes[i]
            switch state {
            case .between:
                switch b {
                case 0x22:                    // "
                    state = .inQuotedField
                case 0x2C:                    // ,
                    state = .between
                case 0x0A:                    // \n
                    lastRowEnd = i
                    state = .between
                case 0x0D:                    // \r
                    break
                default:
                    state = .inField
                }

            case .inField:
                switch b {
                case 0x2C:                    // ,
                    state = .between
                case 0x0A:                    // \n
                    lastRowEnd = i
                    state = .between
                case 0x0D:                    // \r
                    break
                default:
                    break
                }

            case .inQuotedField:
                if b == 0x22 {                // "
                    state = .maybeEscapedQuote
                }

            case .maybeEscapedQuote:
                switch b {
                case 0x22:                    // ""
                    state = .inQuotedField
                case 0x2C:                    // ,
                    state = .between
                case 0x0A:                    // \n
                    lastRowEnd = i
                    state = .between
                case 0x0D:                    // \r
                    break
                default:
                    // A bare byte after a closing quote is malformed per
                    // RFC 4180. Stay tolerant and treat the field as
                    // continuing — the next `,` or `\n` still closes it.
                    state = .inField
                }
            }
            i += 1
        }

        guard let end = lastRowEnd else { return nil }
        // CRLF: when the row terminator is `\r\n`, exclude the trailing
        // `\r` from the prefix so the visible output isn't littered with
        // stray carriage returns.
        var trimmedEnd = end
        if trimmedEnd > 0 && bytes[trimmedEnd - 1] == 0x0D {
            trimmedEnd -= 1
        }
        guard trimmedEnd > 0 else { return nil }
        return String(decoding: bytes[0..<trimmedEnd], as: UTF8.self)
    }

    private enum State {
        case between           // at the start of a field
        case inField           // inside an unquoted field
        case inQuotedField     // inside a quoted field
        case maybeEscapedQuote // just saw `"` while inside a quoted field
    }
}
