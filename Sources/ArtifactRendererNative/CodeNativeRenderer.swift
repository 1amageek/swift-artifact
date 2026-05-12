import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders source code in a monospaced, scrollable container.
///
/// No external highlighter is bundled — this MVP shows uncolored source. Hook a
/// real highlighter (Splash / Highlightr / tree-sitter) by replacing this
/// renderer in your application.
public struct CodeNativeRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .code

    public init() {}

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        return artifact.isComplete ? .complete : .partial
    }

    public func body(artifact: AnyArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let language = artifact.attributes["language"], !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(artifact.payload)
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
        renderer: CodeNativeRenderer()
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
    .artifactRenderer(CodeNativeRenderer())
    .padding()
    .frame(width: 460)
}
