import SwiftUI
import MarkdownUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders Markdown payloads using `swift-markdown-ui`, which provides
/// block-level support (headings, lists, code blocks, block quotes, tables,
/// thematic breaks) on top of `swift-markdown`'s CommonMark parser.
public struct MarkdownNativeRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .markdown

    public init() {}

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        return artifact.isComplete ? .complete : .partial
    }

    public func body(artifact: AnyArtifact) -> some View {
        ScrollView(.vertical) {
            MarkdownView(artifact.payload)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 360)
    }
}

#Preview("Card — complete") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("m1"),
            type: .markdown,
            title: "Recipe",
            payload: """
            # Tomato pasta

            **Serves:** 2

            1. Boil pasta
            2. Sauté garlic
            3. Stir in tomatoes
            4. Combine and serve

            Garnish with *basil* and a pinch of salt.
            """,
            isComplete: true
        ),
        renderer: MarkdownNativeRenderer()
    )
    .padding()
    .frame(width: 420)
}

#Preview("Bare — partial") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("m2"),
            type: .markdown,
            title: "Mid-stream",
            payload: "## Heading\n\nThis is **bold** in flight",
            isComplete: false
        )
    )
    .artifactRenderer(MarkdownNativeRenderer())
    .padding()
    .frame(width: 420)
}

#Preview("Card — table + code block") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("m3"),
            type: .markdown,
            title: "Status report",
            payload: """
            ## Weekly summary

            | Service | Status | Owner |
            |---------|--------|-------|
            | API | **Healthy** | Alice |
            | Worker | Degraded | Bob |

            ```swift
            func ship() throws { try deploy() }
            ```
            """,
            isComplete: true
        ),
        renderer: MarkdownNativeRenderer()
    )
    .padding()
    .frame(width: 520, height: 460)
}
