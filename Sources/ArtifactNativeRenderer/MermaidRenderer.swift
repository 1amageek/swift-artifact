import SwiftUI
import BeautifulMermaid
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Pure-Swift Mermaid renderer backed by `beautiful-mermaid-swift` (ELK-based
/// layout, Core Graphics drawing). No `WKWebView`, no JavaScript.
///
/// Streaming: `refine(_:)` emits the **longest line-aligned prefix** of the
/// payload that parses cleanly through `MermaidParser`. Each new chunk
/// triggers a re-layout, so the diagram grows node-by-node as the source
/// arrives. The trailing partial line (no newline yet) is always dropped
/// before parsing; if the next-most-recent complete line is also unparseable
/// (a half-typed edge, a dangling label), the refiner backtracks one line at
/// a time up to `streamingBacktrackLimit` lines before falling back to
/// `.preRenderable`. The complete payload is always returned as-is so a
/// final parse error surfaces via the view layer rather than being hidden.
///
/// Diagram-type coverage matches BeautifulMermaid:
/// flowchart / graph / stateDiagram-v2 / sequenceDiagram / classDiagram /
/// erDiagram / xychart. Sources whose first line names an unsupported type
/// (gantt, pie, journey, mindmap, …) surface as a parse error.
public struct MermaidRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .mermaid

    /// Maximum number of trailing complete lines to drop when looking for a
    /// parseable prefix during streaming. Bounded so each `refine` call runs
    /// at most `1 + streamingBacktrackLimit` parser invocations.
    static let streamingBacktrackLimit: Int = 5

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        if let prefix = longestParseablePrefix(of: artifact.payload) {
            return .renderable(prefix)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for parseable diagram prefix"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        MermaidBody(source: payload)
    }

    /// Returns the longest line-aligned prefix of `source` that
    /// `MermaidParser.parse` accepts, or `nil` if no such prefix exists.
    ///
    /// Strategy: split on `\n`, drop the trailing partial line (one with no
    /// terminating newline — it is still being typed), then attempt to parse.
    /// On failure, drop one more complete line and retry, up to
    /// `streamingBacktrackLimit` retries. Empty input and prefixes that
    /// reduce to nothing return `nil`.
    static func longestParseablePrefix(of source: String) -> String? {
        guard !source.isEmpty else { return nil }

        let lines = source.components(separatedBy: "\n")
        let hasTrailingNewline = source.hasSuffix("\n")
        let lastCompleteIndex = hasTrailingNewline ? lines.count : lines.count - 1
        guard lastCompleteIndex >= 1 else { return nil }

        let lowerBound = max(1, lastCompleteIndex - streamingBacktrackLimit)
        for count in stride(from: lastCompleteIndex, through: lowerBound, by: -1) {
            let candidate = lines.prefix(count).joined(separator: "\n")
            if parseSucceeds(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func parseSucceeds(_ source: String) -> Bool {
        do {
            _ = try MermaidParser.parse(source)
            return true
        } catch {
            return false
        }
    }
}

/// Internal host view. Splits "empty payload" / "parse error" / "render"
/// states so the SwiftUI tree can swap cleanly when BeautifulMermaid
/// reports an error via its parseError binding.
///
/// Theme: BeautifulMermaid requires an explicit `DiagramTheme`. The default
/// (`zincLight`) hard-codes a white background, which clashes with dark
/// SwiftUI surroundings. We track `@Environment(\.colorScheme)` and switch
/// between `zincLight` / `zincDark` so the diagram visually matches the
/// host card.
///
/// Scroll + zoom: BeautifulMermaid lays out at the diagram's intrinsic size,
/// which is often wider than the card. The renderer sizes the representable
/// to `diagramBounds × zoom` (natural resolution at any zoom) and lets a
/// `ScrollView` provide horizontal + vertical pan. `MagnifyGesture` provides
/// pinch zoom in the 0.25 — 4.0 range.
///
/// We deliberately do NOT auto-fit the diagram to the viewport. Auto-fit
/// collapses the scroll content to viewport size, leaving no scroll range
/// when the diagram is naturally larger — and BeautifulMermaid's
/// `diagramBounds` does not include label overhang, so fit-scaled content
/// can still clip at the edges. Rendering at natural size keeps the diagram
/// scrollable end-to-end; the user can pinch to zoom out for an overview.
///
/// An outer 24pt scroll-content padding adds slack around the rendered
/// frame so the user can pan slightly past the diagram edges, matching the
/// affordance of a PDF / image viewer.
private struct MermaidBody: View {
    let source: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var parseError: Error?
    @State private var diagramBounds: CGRect = .zero
    @State private var zoomScale: CGFloat = 1.0
    @State private var committedZoomScale: CGFloat = 1.0

    private let minZoom: CGFloat = 0.25
    private let maxZoom: CGFloat = 4.0
    private let scrollPadding: CGFloat = 24

    var body: some View {
        Group {
            if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "Empty diagram",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
            } else if let parseError {
                ContentUnavailableView {
                    Label("Cannot render diagram", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(parseError.localizedDescription)
                        .font(.footnote)
                        .monospaced()
                        .multilineTextAlignment(.leading)
                }
            } else {
                diagramScroller
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 360)
    }

    private var diagramScroller: some View {
        GeometryReader { geometry in
            // `MermaidDiagramView` lays out at its natural `diagramBounds`
            // and does not honor a smaller frame on its own — shrinking the
            // frame alone leaves the diagram drawing at full size and
            // overflowing. To actually visually scale, render the
            // representable at natural size and apply `.scaleEffect`, then
            // wrap with an outer frame whose dimensions reflect the scaled
            // visual extent so the ScrollView sees correct contentSize.
            let naturalWidth = max(diagramBounds.width, 1)
            let naturalHeight = max(diagramBounds.height, 1)
            let scaledWidth = naturalWidth * zoomScale
            let scaledHeight = naturalHeight * zoomScale
            let contentWidth = max(scaledWidth + scrollPadding * 2, geometry.size.width)
            let contentHeight = max(scaledHeight + scrollPadding * 2, geometry.size.height)

            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    Color.clear
                        .frame(width: contentWidth, height: contentHeight)

                    MermaidDiagramView(
                        source: source,
                        theme: theme,
                        parseError: $parseError,
                        diagramBounds: $diagramBounds
                    )
                    .frame(width: naturalWidth, height: naturalHeight)
                    .scaleEffect(zoomScale, anchor: .topLeading)
                    .frame(width: scaledWidth, height: scaledHeight, alignment: .topLeading)
                }
            }
            .defaultScrollAnchor(.center)
            .scrollBounceBehavior(.basedOnSize)
            // `.highPriorityGesture` on macOS/iOS lets the pinch win against
            // a long-press, while ScrollView's intrinsic pan remains
            // recognized via a different gesture stream. macCatalyst routes
            // touch through UIKit, where `.simultaneousGesture` is the
            // documented pattern for coexisting magnify + scroll.
            #if targetEnvironment(macCatalyst)
            .simultaneousGesture(magnifyGesture)
            #else
            .highPriorityGesture(magnifyGesture)
            #endif
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let next = committedZoomScale * value.magnification
                zoomScale = clamp(next)
            }
            .onEnded { _ in
                committedZoomScale = zoomScale
            }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        max(minZoom, min(maxZoom, value))
    }

    private var theme: DiagramTheme {
        colorScheme == .dark ? .zincDark : .zincLight
    }
}

#Preview("Card — flowchart") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("mn1"),
            type: .mermaid,
            title: "Build pipeline",
            payload: """
            flowchart LR
                A[Source] --> B[Compile]
                B --> C{Tests pass?}
                C -- yes --> D[Ship]
                C -- no --> E[Fix]
                E --> B
            """,
            isComplete: true
        ),
        renderer: MermaidRenderer()
    )
    .artifactCardContentInsets(EdgeInsets())
    .padding()
    .frame(width: 520, height: 420)
}

#Preview("Card — sequence diagram") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("mn2"),
            type: .mermaid,
            title: "OAuth flow",
            payload: """
            sequenceDiagram
                participant U as User
                participant C as Client
                participant A as Auth
                U->>C: Click login
                C->>A: Authorization request
                A-->>C: Authorization code
                C->>A: Exchange code
                A-->>C: Access token
            """,
            isComplete: true
        ),
        renderer: MermaidRenderer()
    )
    .artifactCardContentInsets(EdgeInsets())
    .padding()
    .frame(width: 520, height: 420)
}

#Preview("Bare — unsupported diagram type → error") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("mn3"),
            type: .mermaid,
            payload: """
            pie title Languages
                "Swift" : 50
                "Kotlin" : 30
                "Other" : 20
            """,
            isComplete: true
        )
    )
    .artifactRenderer(MermaidRenderer())
    .padding()
    .frame(width: 420, height: 240)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("mn4"),
        type: .mermaid,
        title: "Pipeline",
        fullPayload: """
        flowchart LR
            A[Source] --> B[Compile]
            B --> C{Tests pass?}
            C -- yes --> D[Ship]
            C -- no --> E[Fix]
            E --> B
        """,
        chunkSize: 4,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
            .artifactCardContentInsets(EdgeInsets())
    }
    .artifactRenderer(MermaidRenderer())
    .padding()
    .frame(width: 520, height: 460)
}
