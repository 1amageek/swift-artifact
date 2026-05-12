import Testing
import ArtifactCore
import ArtifactRenderer
@testable import ArtifactNativeRenderer

@Suite("CSVRenderer.refine + PartialCSVScanner")
struct CSVRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("c"),
            type: .csv,
            payload: payload,
            isComplete: isComplete
        )
    }

    // MARK: - PartialCSVScanner — basic boundary detection

    @Test func sourceWithoutNewlineReturnsNil() {
        #expect(PartialCSVScanner.longestValidPrefix("Region,Q1,Q2") == nil)
    }

    @Test func sourceWithLeadingNewlineHasNoUsablePrefix() {
        #expect(PartialCSVScanner.longestValidPrefix("\nRegion") == nil)
    }

    @Test func emptySourceReturnsNil() {
        #expect(PartialCSVScanner.longestValidPrefix("") == nil)
    }

    @Test func trimAtLastUnquotedNewline() {
        let result = PartialCSVScanner.longestValidPrefix(
            "Region,Q1\nNorth,120\nSout"
        )
        #expect(result == "Region,Q1\nNorth,120")
    }

    @Test func crlfLineEndingsAreHandled() {
        // The trailing `\r` immediately before the row-terminating `\n` is
        // part of the CRLF terminator and is stripped from the prefix.
        // The `\r` belonging to the prior row (between Q1 and N) is kept.
        let result = PartialCSVScanner.longestValidPrefix(
            "Region,Q1\r\nNorth,120\r\nSout"
        )
        #expect(result == "Region,Q1\r\nNorth,120")
    }

    // MARK: - PartialCSVScanner — quoted fields

    @Test func newlineInsideQuotedFieldIsNotARowBoundary() {
        // The first `\n` is INSIDE the bio field — must not be treated as a
        // row terminator. Only the outer `\n` after the closing `"` counts.
        let result = PartialCSVScanner.longestValidPrefix(
            "name,bio\n\"Alice\",\"Loves\nhiking\"\nBob,Coo"
        )
        #expect(result == "name,bio\n\"Alice\",\"Loves\nhiking\"")
    }

    @Test func unclosedQuoteSuppressesEverythingAfterIt() {
        // The opening `"` is never closed — the trailing `\n` is still
        // inside the quoted field, so no boundary after row 1 is recorded.
        let result = PartialCSVScanner.longestValidPrefix(
            "name,bio\n\"Alice\",\"Loves\nhiking"
        )
        #expect(result == "name,bio")
    }

    @Test func escapedQuoteInsideFieldDoesNotCloseIt() {
        // `""` is a literal quote — the field continues. The first true
        // closing `"` is the one before the newline.
        let result = PartialCSVScanner.longestValidPrefix(
            #"name,quote\n"Alice","she said ""hi"""\nBob"#
                .replacingOccurrences(of: "\\n", with: "\n")
        )
        #expect(result == "name,quote\n\"Alice\",\"she said \"\"hi\"\"\"")
    }

    @Test func commaInsideQuotedFieldIsNotAFieldSeparator() {
        // The comma in "London, UK" is inside quotes — it is a literal
        // character, not a field separator. The scanner doesn't care
        // about column counts, but it must close the quoted field on the
        // proper `"` and only then recognize the next `\n`.
        let result = PartialCSVScanner.longestValidPrefix(
            "name,city\nAlice,\"London, UK\"\nBob"
        )
        #expect(result == "name,city\nAlice,\"London, UK\"")
    }

    @Test func quotedFieldFollowedByCRLFIsRecognized() {
        // `"...",\r\n` — the boundary is the `\n` after the closing quote,
        // and the CRLF's `\r` is stripped from the prefix.
        let result = PartialCSVScanner.longestValidPrefix(
            "name,bio\r\n\"Alice\",\"x\"\r\nBob"
        )
        #expect(result == "name,bio\r\n\"Alice\",\"x\"")
    }

    @Test func multipleEmbeddedNewlinesInQuotedFieldStayInside() {
        let result = PartialCSVScanner.longestValidPrefix(
            "name,bio\n\"Alice\",\"line1\nline2\nline3\"\nBob,Cool"
        )
        #expect(result == "name,bio\n\"Alice\",\"line1\nline2\nline3\"")
    }

    // MARK: - PartialCSVScanner — defensive behavior

    @Test func bareQuoteInUnquotedFieldIsTreatedAsLiteralCharacter() {
        // RFC 4180 forbids `"` mid-field outside quotes. The scanner is
        // lenient: it keeps walking and treats the next `\n` as a normal
        // row terminator.
        let result = PartialCSVScanner.longestValidPrefix(
            "a,b\nx\"y,z\nq"
        )
        #expect(result == "a,b\nx\"y,z")
    }

    @Test func trailingBytesAfterClosingQuoteAreTolerated() {
        // `"abc"def` — bytes after the closing quote are technically
        // malformed; the scanner stays tolerant until the next `,` or `\n`.
        let result = PartialCSVScanner.longestValidPrefix(
            "h\n\"abc\"def\nrow3"
        )
        #expect(result == "h\n\"abc\"def")
    }

    // MARK: - CSVRenderer.refine

    @Test func streamingWithoutNewlineIsPreRenderable() {
        let result = CSVRenderer.refine(artifact(payload: "Region,Q1,Q2", isComplete: false))
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable before the first newline")
        }
    }

    @Test func streamingTrimsAtLastNewline() {
        let result = CSVRenderer.refine(
            artifact(payload: "Region,Q1\nNorth,120\nSout", isComplete: false)
        )
        #expect(result == .renderable("Region,Q1\nNorth,120"))
    }

    @Test func streamingPreservesEmbeddedNewlineInQuotedField() {
        let result = CSVRenderer.refine(
            artifact(
                payload: "name,bio\n\"Alice\",\"Loves\nhiking\"\nBo",
                isComplete: false
            )
        )
        #expect(
            result == .renderable("name,bio\n\"Alice\",\"Loves\nhiking\"")
        )
    }

    @Test func streamingWithUnclosedQuoteFallsBackToPriorBoundary() {
        let result = CSVRenderer.refine(
            artifact(
                payload: "name,bio\n\"Alice\",\"Loves\nhiking",
                isComplete: false
            )
        )
        #expect(result == .renderable("name,bio"))
    }

    @Test func completePayloadIsReturned() {
        let result = CSVRenderer.refine(
            artifact(payload: "Region,Q1\nNorth,120", isComplete: true)
        )
        #expect(result == .renderable("Region,Q1\nNorth,120"))
    }

    // MARK: - CSVColumnAnalysis.inferTypes

    @Test func allNumericColumnDetectedAsNumeric() {
        let types = CSVColumnAnalysis.inferTypes(
            rows: [["120", "134"], ["98", "110"], ["75", "82"]],
            columnCount: 2
        )
        #expect(types == [.numeric, .numeric])
    }

    @Test func mixedColumnDowngradesToText() {
        let types = CSVColumnAnalysis.inferTypes(
            rows: [["North", "120"], ["South", "98"], ["East", "N/A"]],
            columnCount: 2
        )
        // First column has non-numeric values → text. Second column has one
        // non-numeric value ("N/A") → text.
        #expect(types == [.text, .text])
    }

    @Test func emptyCellsDoNotAffectInference() {
        // Blanks are skipped — they neither confirm nor reject numeric.
        let types = CSVColumnAnalysis.inferTypes(
            rows: [["", "120"], ["South", ""], ["", "82"]],
            columnCount: 2
        )
        #expect(types == [.text, .numeric])
    }

    @Test func columnWithNoValuesIsText() {
        // An entirely blank column has no signal — default to text rather
        // than claiming it's numeric.
        let types = CSVColumnAnalysis.inferTypes(
            rows: [["Alice", ""], ["Bob", ""]],
            columnCount: 2
        )
        #expect(types == [.text, .text])
    }

    @Test func negativeAndDecimalNumbersAreNumeric() {
        let types = CSVColumnAnalysis.inferTypes(
            rows: [["-1.5", "2e3"], ["0", "-4.2"]],
            columnCount: 2
        )
        #expect(types == [.numeric, .numeric])
    }

    @Test func columnTypeArraySizeMatchesRequestedColumnCount() {
        let types = CSVColumnAnalysis.inferTypes(
            rows: [["a", "b"]],
            columnCount: 4
        )
        #expect(types.count == 4)
    }
}
