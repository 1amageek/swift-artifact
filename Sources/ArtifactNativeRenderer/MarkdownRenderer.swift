import SwiftUI
import MarkdownUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders Markdown payloads using `swift-markdown-ui`, which provides
/// block-level support (headings, lists, code blocks, block quotes, tables,
/// thematic breaks) on top of `swift-markdown`'s CommonMark parser.
public struct MarkdownRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .markdown
    /// Markdown owns its reading inset internally so it renders with the same
    /// typography spacing both inside and outside `ArtifactCard`.
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        // While streaming, only feed the parser up through the last newline
        // — partial block constructs (e.g. half-written table rows) confuse
        // CommonMark and produce flickering renders.
        if let newlineIndex = artifact.payload.lastIndex(of: "\n") {
            let prefix = String(artifact.payload[..<newlineIndex])
            if prefix.isEmpty {
                return .preRenderable(
                    PreRenderableProgress(
                        receivedCharacters: artifact.payload.count,
                        hint: "waiting for first complete line"
                    )
                )
            }
            return .renderable(prefix)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first newline"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        ArtifactBoundedScrollView(.vertical) {
            MarkdownView(payload)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(defaultArtifactCardContentInsets)
        }
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
        renderer: MarkdownRenderer()
    )
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
    .artifactRenderer(MarkdownRenderer())
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
        renderer: MarkdownRenderer()
    )
    .frame(width: 520, height: 460)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("m4"),
        type: .markdown,
        title: "Streaming notes",
        fullPayload: """
        # Quarterly review

        ## Highlights

        - Shipped **v0.1** with five modules
        - Onboarded *three* new contributors
        - Migrated CI to the new runner pool

        ## Risks

        1. Markdown table rendering needs cross-platform validation
        2. WKWebView pool sizing under load is unverified
        3. Vision Pro rendering parity is pending

        > Net: on track for the next milestone.

        ```swift
        struct Shipping { let date: Date }
        ```
        """,
        chunkSize: 8,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(MarkdownRenderer())
    .frame(width: 480, height: 520)
}
