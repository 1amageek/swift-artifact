import Testing
import ArtifactCore
import ArtifactRenderer
import ArtifactWebRenderer

@Suite("HTMLWebViewRenderer.refine + PartialHTMLScanner")
struct HTMLRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("h"),
            type: .html,
            payload: payload,
            isComplete: isComplete
        )
    }

    // MARK: - Complete payloads pass through unchanged

    @Test func completePayloadIsReturnedRaw() {
        let payload = "<!DOCTYPE html><html><body><p>Hi</p></body></html>"
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: true)
        )
        #expect(result == .renderable(payload))
    }

    @Test func completeEmptyPayloadIsReturnedRaw() {
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: "", isComplete: true)
        )
        #expect(result == .renderable(""))
    }

    // MARK: - Streaming gates

    @Test func incompleteEmptyPayloadIsPreRenderable() {
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: "", isComplete: false)
        )
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable for empty incomplete payload")
        }
    }

    @Test func incompleteTagAtStartIsPreRenderable() {
        // The `<` has started but `>` has not arrived. There is nothing
        // safe to render yet.
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: "<!DOCTY", isComplete: false)
        )
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable while the first tag is still streaming")
        }
    }

    @Test func leadingTextOnlyPayloadIsRenderable() {
        // No tags at all — browser still renders plain text.
        let payload = "Hello"
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    // MARK: - Tag boundary handling

    @Test func incompleteTrailingTagIsTrimmed() {
        // `<p>` completed and was added to the prefix; the half-typed
        // `<div class="hea` after it must be dropped.
        let payload = #"<p>Hi</p><div class="hea"#
        guard case let .renderable(prefix) = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        #expect(prefix == "<p>Hi</p>")
    }

    @Test func attributeContainingAngleBracketIsRespected() {
        // The `>` inside the attribute string must not be mistaken for
        // the tag close.
        let payload = #"<a title="3 > 2">link</a>"#
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    @Test func singleQuotedAttributeIsRespected() {
        let payload = #"<a title='a > b'>link</a>"#
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    @Test func unclosedElementSurvivesBrowserTolerance() {
        // We deliberately do not synthesize close tags — browsers handle
        // unclosed containers themselves. So `<div><p>Hi` should pass
        // through verbatim.
        let payload = "<div><p>Hi"
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    // MARK: - Markup declarations & comments

    @Test func doctypePassesThroughOnceComplete() {
        let payload = "<!DOCTYPE html><html>"
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    @Test func incompleteDoctypeIsDropped() {
        let payload = "<!DOCTYPE htm"
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable for unterminated doctype")
        }
    }

    @Test func commentContainingAngleBracketsIsSkipped() {
        let payload = "<!-- <fake/> not a real tag --><p>Hi</p>"
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    @Test func unterminatedCommentSuppressesEverythingAfterIt() {
        let payload = "<p>Hi</p><!-- still streaming"
        guard case let .renderable(prefix) = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        #expect(prefix == "<p>Hi</p>")
        #expect(prefix.contains("<!--") == false)
    }

    @Test func cdataSectionIsSkipped() {
        let payload = "<!-- prelude --><![CDATA[ <fake/> ]]><p>Hi</p>"
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    @Test func processingInstructionIsSkipped() {
        let payload = #"<?xml-stylesheet href="a.css"?><p>Hi</p>"#
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    // MARK: - Raw-text element guard

    @Test func unclosedScriptIsDroppedEntirely() {
        // Mid-streamed `<script>foo(` would otherwise leave the WebView's
        // tokenizer in raw-text mode and swallow every later token.
        let payload = "<p>before</p><script>function f() { return 1"
        guard case let .renderable(prefix) = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        #expect(prefix == "<p>before</p>")
        #expect(prefix.contains("<script") == false)
    }

    @Test func unclosedStyleIsDroppedEntirely() {
        let payload = "<p>before</p><style>.a { color: red"
        guard case let .renderable(prefix) = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        #expect(prefix == "<p>before</p>")
        #expect(prefix.contains("<style") == false)
    }

    @Test func closedScriptBlockIsRetained() {
        let payload = "<script>console.log('ok')</script><p>Hi</p>"
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    @Test func closedStyleBlockIsRetained() {
        let payload = "<style>p { color: red; }</style><p>Hi</p>"
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    @Test func scriptCloseTagIsCaseInsensitive() {
        let payload = "<SCRIPT>foo()</Script><p>Hi</p>"
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    @Test func nonBoundaryCharAfterRawCloseDoesNotTerminateBlock() {
        // `</styles>` is NOT a valid close for `<style>` — the char after
        // the name must be one of ` \t\n\r/>`. Until a real `</style>`
        // arrives the entire block must be withheld.
        let payload = "<p>ok</p><style>.a { content: '</styles>'"
        guard case let .renderable(prefix) = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        #expect(prefix == "<p>ok</p>")
    }

    @Test func selfClosingScriptIsTreatedAsClosed() {
        // `<script src="..." />` is XML-style and unusual, but if it
        // streams as a self-closing tag the scanner should not block on
        // a missing `</script>`.
        let payload = #"<script src="a.js"/><p>Hi</p>"#
        let result = HTMLWebViewRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    // MARK: - Structural invariants

    @Test func renderableOutputIsAlwaysAPrefixOfInput() {
        // The scanner only truncates — it never rewrites or synthesizes.
        // Whatever it emits must be a literal prefix of the chunk.
        let chunks = [
            "<p>partial</p><sc",
            "<!--",
            "<!DOCTY",
            "<style>.a { col",
            "<script>foo(",
            #"<a title="3 > 2">link</a><div class="hea"#,
            "<p>ok</p><![CDATA[ <not-a-tag> ",
            "Hello <",
        ]
        for chunk in chunks {
            let result = HTMLWebViewRenderer.refine(
                artifact(payload: chunk, isComplete: false)
            )
            guard case let .renderable(prefix) = result else { continue }
            #expect(
                chunk.hasPrefix(prefix),
                "renderable output is not a prefix of input: \(prefix) vs \(chunk)"
            )
        }
    }

    @Test func prefixLengthGrowsMonotonicallyDuringStreaming() {
        // Replay a complete document one character at a time. The
        // renderable prefix's length must never regress as the stream
        // grows. This is the invariant that protects the UI from flicker
        // where content briefly disappears between chunks.
        let full = """
        <!DOCTYPE html>
        <html>
          <head><style>p { color: red; }</style></head>
          <body>
            <h1>Streaming</h1>
            <p>Partial output is drawn as it arrives.</p>
            <script>console.log("done")</script>
          </body>
        </html>
        """
        var lastLength = 0
        var sawRenderable = false
        for endIndex in 1...full.count {
            let chunk = String(full.prefix(endIndex))
            switch HTMLWebViewRenderer.refine(
                artifact(payload: chunk, isComplete: false)
            ) {
            case let .renderable(prefix):
                sawRenderable = true
                #expect(
                    prefix.count >= lastLength,
                    "renderable prefix length regressed at chunk length \(endIndex): \(lastLength) -> \(prefix.count)"
                )
                lastLength = prefix.count
            case .preRenderable:
                break
            }
        }
        #expect(sawRenderable, "expected at least one renderable mid-stream prefix")
    }
}
