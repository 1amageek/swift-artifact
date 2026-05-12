import Testing
import ArtifactCore
import ArtifactRenderer
import ArtifactNativeRenderer

@Suite("MermaidRenderer.refine")
struct MermaidRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("md"),
            type: .mermaid,
            payload: payload,
            isComplete: isComplete
        )
    }

    // MARK: - Complete payloads

    @Test func completePayloadIsReturnedRaw() {
        let payload = """
        flowchart LR
            A --> B
        """
        let result = MermaidRenderer.refine(
            artifact(payload: payload, isComplete: true)
        )
        #expect(result == .renderable(payload))
    }

    @Test func completeEmptyPayloadIsReturnedRaw() {
        // refine is intentionally simple: even an empty `isComplete` artifact
        // flows through. The view layer surfaces the "empty diagram" state.
        let result = MermaidRenderer.refine(
            artifact(payload: "", isComplete: true)
        )
        #expect(result == .renderable(""))
    }

    @Test func completeUnparseablePayloadIsReturnedRaw() {
        // The view layer reports the parse error via MermaidView's binding.
        // refine must not swallow the source.
        let payload = "totally not mermaid"
        let result = MermaidRenderer.refine(
            artifact(payload: payload, isComplete: true)
        )
        #expect(result == .renderable(payload))
    }

    // MARK: - Streaming: no parseable prefix yet → pre-renderable

    @Test func incompleteEmptyPayloadIsPreRenderable() {
        let result = MermaidRenderer.refine(
            artifact(payload: "", isComplete: false)
        )
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable for empty incomplete payload")
        }
    }

    @Test func incompleteTypeLineWithoutNewlineIsPreRenderable() {
        // `flowchart LR` with no trailing newline — the type declaration
        // itself is still being typed. Nothing to render yet.
        let result = MermaidRenderer.refine(
            artifact(payload: "flowchart LR", isComplete: false)
        )
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable for partial type line")
        }
    }

    // MARK: - Streaming: parseable prefix → renderable subset

    @Test func incompletePayloadEmitsParseablePrefix() {
        // Two complete edges plus a half-typed third line. The refiner
        // should emit the first two lines (which parse) without the
        // dangling `\n    C --` suffix. The trailing `C --` has no
        // terminating newline so it is treated as still-typing.
        let payload = "flowchart LR\n    A --> B\n    B --> C\n    C --"
        let result = MermaidRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        let expected = "flowchart LR\n    A --> B\n    B --> C"
        #expect(result == .renderable(expected))
    }

    @Test func incompletePayloadWithTrailingNewlineKeepsCompleteLines() {
        // Every line ends with a newline, so all complete lines should
        // pass through — refine should not drop the trailing empty line
        // unnecessarily and should still parse.
        let payload = "flowchart LR\n    A --> B\n    B --> C\n"
        let result = MermaidRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        #expect(result == .renderable(payload))
    }

    @Test func renderableOutputIsAlwaysAPrefixOfInput() {
        // The refiner only truncates — it never reorders, rewrites, or
        // synthesizes content. Whatever it emits must be a literal prefix
        // of the input chunk.
        let chunks = [
            "flowchart LR\n    A --> B\n    A --[\n",
            "flowchart LR\n    A --> B\n    (\n",
            "flowchart LR\n    A --> B\n    @@@bogus@@@\n",
            "flowchart LR\n    A --> B\n    B --> C\n    C --",
            "sequenceDiagram\n    participant U as User\n    [[[\n",
        ]
        for chunk in chunks {
            let result = MermaidRenderer.refine(
                artifact(payload: chunk, isComplete: false)
            )
            guard case let .renderable(prefix) = result else { continue }
            #expect(
                chunk.hasPrefix(prefix),
                "renderable output is not a prefix of input: \(prefix) vs \(chunk)"
            )
        }
    }

    @Test func incompletePayloadGrowsMonotonicallyByNonEmptyLineCount() {
        // Simulate a stream that emits one character at a time. The
        // renderable prefix's **non-empty** line count must never regress:
        // once a content line is emitted, later chunks must still contain
        // it (possibly plus more lines).
        //
        // Character count is NOT a monotonic invariant: `"flowchart LR\n"`
        // (13 chars, trailing newline preserved by the refiner) becomes
        // `"flowchart LR"` (12 chars) after one more character is added,
        // because the new trailing line is still being typed and gets
        // dropped. Splitting while keeping empties is also not monotonic
        // because trailing-newline presence toggles an empty terminal
        // element. The actual semantic invariant is the count of
        // non-empty lines, which corresponds to rendered content.
        let full = """
        flowchart LR
            A --> B
            B --> C
            C --> D
        """
        var lastLineCount = 0
        var sawRenderable = false
        for endIndex in 1...full.count {
            let chunk = String(full.prefix(endIndex))
            switch MermaidRenderer.refine(artifact(payload: chunk, isComplete: false)) {
            case let .renderable(prefix):
                sawRenderable = true
                let lineCount = prefix.split(separator: "\n", omittingEmptySubsequences: true).count
                #expect(
                    lineCount >= lastLineCount,
                    "renderable prefix non-empty line count regressed at chunk length \(endIndex): \(lastLineCount) -> \(lineCount)"
                )
                lastLineCount = lineCount
            case .preRenderable:
                break
            }
        }
        #expect(sawRenderable, "expected at least one renderable mid-stream prefix")
    }

    // MARK: - Diagram-type-specific streaming

    @Test func sequenceDiagramStreamsIncrementally() {
        // After the type line + one participant, the prefix should parse;
        // the half-typed second participant should be dropped.
        let payload = "sequenceDiagram\n    participant U as User\n    participant C as Cli"
        let result = MermaidRenderer.refine(
            artifact(payload: payload, isComplete: false)
        )
        let expected = "sequenceDiagram\n    participant U as User"
        #expect(result == .renderable(expected))
    }
}
