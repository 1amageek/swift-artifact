import Testing
import Foundation
import ArtifactCore
import ArtifactRenderer
import ArtifactNativeRenderer

@Suite("JSONRenderer.refine + PartialJSONScanner")
struct JSONRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("j"),
            type: .json,
            payload: payload,
            isComplete: isComplete
        )
    }

    private func parsedObject(_ source: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: Data(source.utf8),
            options: []
        )
        return try #require(object as? [String: Any])
    }

    private func parsedArray(_ source: String) throws -> [Any] {
        let object = try JSONSerialization.jsonObject(
            with: Data(source.utf8),
            options: []
        )
        return try #require(object as? [Any])
    }

    // MARK: - PartialJSONScanner — fast path

    @Test func fullyValidObjectIsReturnedAsIs() {
        let valid = PartialJSONScanner.longestValidPrefix(#"{"a":1,"b":2}"#)
        #expect(valid == #"{"a":1,"b":2}"#)
    }

    @Test func fullyValidArrayIsReturnedAsIs() {
        let valid = PartialJSONScanner.longestValidPrefix(#"[1,2,3]"#)
        #expect(valid == #"[1,2,3]"#)
    }

    @Test func leadingWhitespaceIsTrimmedOnFastPath() {
        let valid = PartialJSONScanner.longestValidPrefix("   {\"a\":1}   ")
        #expect(valid == #"{"a":1}"#)
    }

    @Test func emptyOrWhitespaceInputReturnsNil() {
        #expect(PartialJSONScanner.longestValidPrefix("") == nil)
        #expect(PartialJSONScanner.longestValidPrefix("   \n  ") == nil)
    }

    // MARK: - PartialJSONScanner — bare top-level values are rejected while streaming

    @Test func bareNumberDoesNotTakeFastPath() {
        // `42` could still extend to `423`; the fast path must only fire for
        // structural roots (`{` or `[`).
        #expect(PartialJSONScanner.longestValidPrefix("42") == nil)
    }

    @Test func bareLiteralDoesNotTakeFastPath() {
        // `true` looks complete but the walker is the authority. Since the
        // walker confirms literal completion only after consuming all four
        // expected bytes, `true` actually does become renderable here. The
        // critical case is the partial form below.
        #expect(PartialJSONScanner.longestValidPrefix("true") == "true")
        #expect(PartialJSONScanner.longestValidPrefix("tru") == nil)
        #expect(PartialJSONScanner.longestValidPrefix("nul") == nil)
        #expect(PartialJSONScanner.longestValidPrefix("fals") == nil)
    }

    @Test func bareStringAcceptedOnceQuoteClosed() {
        // Top-level strings complete on the closing quote.
        #expect(PartialJSONScanner.longestValidPrefix(#""hello""#) == #""hello""#)
        #expect(PartialJSONScanner.longestValidPrefix(#""hel"#) == nil)
    }

    // MARK: - PartialJSONScanner — number handling

    @Test func truncatedNumberInObjectIsDropped() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"{"a":1,"b":2"#)
        )
        // `2` might still be `25`, so the second pair must not appear.
        let parsed = try parsedObject(valid)
        #expect(parsed["a"] as? Int == 1)
        #expect(parsed.count == 1)
    }

    @Test func truncatedNumberInArrayIsDropped() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"[1,2,3,4"#)
        )
        let parsed = try parsedArray(valid)
        let numbers = parsed.compactMap { $0 as? Int }
        #expect(numbers == [1, 2, 3])
    }

    @Test func numberWithDecimalAndExponentIsHandled() throws {
        // `1.5e2` — once followed by a comma the value is confirmed; the
        // trailing `7` is still streaming.
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"{"a":1.5e2,"b":7"#)
        )
        let parsed = try parsedObject(valid)
        #expect(parsed["a"] as? Double == 150.0)
        #expect(parsed.count == 1)
    }

    @Test func negativeNumberIsHandled() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"[-1,-2,-3"#)
        )
        let parsed = try parsedArray(valid)
        #expect(parsed.compactMap { $0 as? Int } == [-1, -2])
    }

    // MARK: - PartialJSONScanner — literal handling

    @Test func completedTrueLiteralIsAccepted() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"{"a":true,"b":1"#)
        )
        let parsed = try parsedObject(valid)
        #expect(parsed["a"] as? Bool == true)
        // `1` is still streaming so `b` is dropped.
        #expect(parsed.count == 1)
    }

    @Test func completedFalseAndNullLiteralsAreAccepted() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"{"a":false,"b":null,"c":1"#)
        )
        let parsed = try parsedObject(valid)
        #expect(parsed["a"] as? Bool == false)
        #expect(parsed["b"] is NSNull)
        #expect(parsed.count == 2)
    }

    @Test func partialLiteralBlocksProgress() {
        // `tru` is not yet `true`; the pair shouldn't appear.
        #expect(PartialJSONScanner.longestValidPrefix(#"{"a":tru"#) == nil)
    }

    @Test func malformedLiteralStopsAtLastConfirmedPair() throws {
        // `truu` is invalid. Everything before the `,` is salvageable.
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"{"a":1,"b":truu"#)
        )
        let parsed = try parsedObject(valid)
        #expect(parsed["a"] as? Int == 1)
        #expect(parsed.count == 1)
    }

    // MARK: - PartialJSONScanner — string handling

    @Test func unterminatedStringValueIsDropped() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"{"a":"first","b":"sec"#)
        )
        let parsed = try parsedObject(valid)
        #expect(parsed["a"] as? String == "first")
        #expect(parsed.count == 1)
    }

    @Test func escapedQuoteInStringDoesNotTerminate() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(##"{"msg":"he said \"hi\"","next":1"##)
        )
        let parsed = try parsedObject(valid)
        #expect(parsed["msg"] as? String == #"he said "hi""#)
        // `1` is still streaming.
        #expect(parsed.count == 1)
    }

    @Test func unicodeEscapeInsideStringIsParsed() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(##"{"a":"éclair","b":1"##)
        )
        let parsed = try parsedObject(valid)
        #expect(parsed["a"] as? String == "éclair")
    }

    @Test func backslashAtEndOfStringDoesNotProduceClosingQuoteEarly() {
        // `\"` is one escaped quote — the string isn't closed.
        #expect(
            PartialJSONScanner.longestValidPrefix(##"{"a":"abc\""##) == nil
        )
    }

    // MARK: - PartialJSONScanner — nesting

    @Test func nestedArrayInsideObjectIsTruncatedAtDeepestFrame() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"{"a":[1,2,3], "b":[10,20"#)
        )
        let parsed = try parsedObject(valid)
        let aArray = try #require(parsed["a"] as? [Int])
        let bArray = try #require(parsed["b"] as? [Int])
        #expect(aArray == [1, 2, 3])
        // Trailing `20` may still extend to `200`, so only `10` is safe.
        #expect(bArray == [10])
    }

    @Test func nestedObjectInsideArrayIsHandled() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"[{"x":1},{"y":2"#)
        )
        let parsed = try parsedArray(valid)
        let first = try #require(parsed.first as? [String: Any])
        #expect(first["x"] as? Int == 1)
        #expect(parsed.count == 1)
    }

    @Test func deeplyNestedStructureIsHandled() throws {
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"{"a":{"b":{"c":[1,2,3"#)
        )
        let parsed = try parsedObject(valid)
        let a = try #require(parsed["a"] as? [String: Any])
        let b = try #require(a["b"] as? [String: Any])
        let c = try #require(b["c"] as? [Int])
        #expect(c == [1, 2])
    }

    // MARK: - PartialJSONScanner — defensive against malformed input

    @Test func mismatchedClosingBracketDoesNotProduceInvalidPrefix() {
        // `]` while the most recent open is `{` — the scanner stops and
        // either returns a re-validated prefix or nil.
        if let result = PartialJSONScanner.longestValidPrefix(#"{"a":1]"#) {
            // Whatever comes back must be valid JSON.
            let parsed = try? JSONSerialization.jsonObject(
                with: Data(result.utf8),
                options: []
            )
            #expect(parsed != nil)
        }
    }

    @Test func garbageAtRootAfterCompletionDoesNotInvalidatePrefix() throws {
        // `42` is a valid root, followed by an extra `x` byte. Today the
        // walker reports the `42` as the safe prefix — but the fast path
        // (which rejects bare numbers) means the walker handles it.
        let valid = try #require(
            PartialJSONScanner.longestValidPrefix(#"{"a":1} junk"#)
        )
        #expect(valid == #"{"a":1}"#)
    }

    @Test func nonStringInKeySlotStopsScanner() {
        // `{1:2}` — keys must be strings.
        #expect(PartialJSONScanner.longestValidPrefix(#"{1:2}"#) == nil)
    }

    @Test func sourceWithoutAnyCompletedPairReturnsNil() {
        #expect(PartialJSONScanner.longestValidPrefix(#"{"par"#) == nil)
        #expect(PartialJSONScanner.longestValidPrefix(#"{"a":"#) == nil)
    }

    // MARK: - JSONRenderer.refine

    @Test func refineFallsBackToPreRenderableWhenNothingComplete() {
        let result = JSONRenderer.refine(artifact(payload: #"{"par"#, isComplete: false))
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable for incomplete leading key")
        }
    }

    @Test func refineSurfacesValidPrefix() throws {
        // Both `1` and `2` are confirmed because each is followed by a
        // non-numeric byte (`,`). The trailing `"par` is an unterminated
        // string and gets dropped.
        let result = JSONRenderer.refine(artifact(
            payload: #"{"a":1,"b":2,"c":"par"#,
            isComplete: false
        ))
        guard case let .renderable(prefix) = result else {
            Issue.record("Expected .renderable")
            return
        }
        let parsed = try parsedObject(prefix)
        #expect(parsed["a"] as? Int == 1)
        #expect(parsed["b"] as? Int == 2)
        #expect(parsed.count == 2)
    }

    @Test func refineWithCompleteFlagReturnsRaw() {
        let result = JSONRenderer.refine(artifact(payload: #"{"a":1}"#, isComplete: true))
        #expect(result == .renderable(#"{"a":1}"#))
    }
}
