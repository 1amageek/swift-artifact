import SwiftUI
import BeautifulMermaid
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Pure-Swift Mermaid renderer backed by `beautiful-mermaid-swift` (ELK-based
/// layout, Core Graphics drawing). No `WKWebView`, no JavaScript.
///
/// Streaming policy is conservative: `refine(_:)` holds at `.preRenderable`
/// until the artifact is complete. BeautifulMermaid renders a fully
/// laid-out graph in one pass — partial inputs would either fail to parse
/// or produce a layout that re-flows entirely on each new line, which is
/// worse for the eye than a single deferred render.
///
/// Diagram-type coverage matches BeautifulMermaid:
/// flowchart / graph / stateDiagram-v2 / sequenceDiagram / classDiagram /
/// erDiagram / xychart. Sources whose first line names an unsupported type
/// (gantt, pie, journey, mindmap, …) surface as a parse error.
public struct MermaidRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .mermaid

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for diagram to complete"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        MermaidBody(source: payload)
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
            let scaledWidth = max(diagramBounds.width * zoomScale, 1)
            let scaledHeight = max(diagramBounds.height * zoomScale, 1)

            ScrollView([.horizontal, .vertical]) {
                MermaidDiagramView(
                    source: source,
                    theme: theme,
                    parseError: $parseError,
                    diagramBounds: $diagramBounds
                )
                .frame(width: scaledWidth, height: scaledHeight)
                .padding(scrollPadding)
                .frame(
                    minWidth: geometry.size.width,
                    minHeight: geometry.size.height
                )
            }
            .defaultScrollAnchor(.center)
            .scrollBounceBehavior(.basedOnSize)
            .simultaneousGesture(magnifyGesture)
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
