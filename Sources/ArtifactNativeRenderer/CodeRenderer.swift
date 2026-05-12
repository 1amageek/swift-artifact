import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders source code in a monospaced, scrollable container.
///
/// No external highlighter is bundled — this MVP shows uncolored source. Hook a
/// real highlighter (Splash / Highlightr / tree-sitter) by replacing this
/// renderer in your application.
public struct CodeRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .code

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.payload.isEmpty {
            return .preRenderable(PreRenderableProgress(receivedCharacters: 0))
        }
        return .renderable(artifact.payload)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let language = artifact.attributes["language"], !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(payload)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
    }
}

#Preview("Card — Swift") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("c1"),
            type: .code,
            title: "fib.swift",
            attributes: ["language": "swift"],
            payload: """
            func fib(_ n: Int) -> Int {
                if n < 2 { return n }
                return fib(n - 1) + fib(n - 2)
            }

            print(fib(10))
            """,
            isComplete: true
        ),
        renderer: CodeRenderer()
    )
    .padding()
    .frame(width: 460)
}

#Preview("Bare — no language tag") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("c2"),
            type: .code,
            title: "snippet",
            payload: "hello = lambda x: x * 2\nprint(hello(21))",
            isComplete: true
        )
    )
    .artifactRenderer(CodeRenderer())
    .padding()
    .frame(width: 460)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("c3"),
        type: .code,
        title: "fizzbuzz.swift",
        attributes: ["language": "swift"],
        fullPayload: """
        func fizzbuzz(upTo limit: Int) {
            for n in 1...limit {
                switch (n % 3, n % 5) {
                case (0, 0): print("FizzBuzz")
                case (0, _): print("Fizz")
                case (_, 0): print("Buzz")
                default:     print(n)
                }
            }
        }

        fizzbuzz(upTo: 30)
        """,
        chunkSize: 6,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(CodeRenderer())
    .padding()
    .frame(width: 480, height: 480)
}
