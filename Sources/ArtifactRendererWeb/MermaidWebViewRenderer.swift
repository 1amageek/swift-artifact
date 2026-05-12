import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders Mermaid diagrams in a WKWebView.
///
/// Demonstrates the spec's dynamic `renderingState` example: while bytes are
/// still arriving, the renderer pre-validates the partial source with
/// `MermaidValidator.canParse` and only declares `.partial` once a meaningful
/// fragment has been seen. Otherwise the streaming placeholder is shown.
public struct MermaidWebViewRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .mermaid

    public init() {}

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        if artifact.isComplete { return .complete }
        return MermaidValidator.canParse(artifact.payload) ? .partial : .streaming
    }

    public func body(artifact: AnyArtifact) -> some View {
        ArtifactWebView(html: WebRendererShells.mermaid(payload: artifact.payload))
            .frame(minHeight: 280)
    }
}

/// Lightweight syntactic check used to gate partial Mermaid renders. A real
/// implementation would call into mermaid.js's parse step; for the MVP the
/// validator looks for a recognised diagram header followed by at least one
/// edge or node line.
public enum MermaidValidator {
    private static let prefixes: [String] = [
        "graph",
        "flowchart",
        "sequencediagram",
        "classdiagram",
        "statediagram",
        "erdiagram",
        "gantt",
        "pie",
        "journey",
        "mindmap",
        "timeline",
        "quadrantchart"
    ]

    public static func canParse(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        guard prefixes.contains(where: { lowered.hasPrefix($0) }) else { return false }
        // Require at least one newline beyond the header.
        return trimmed.contains("\n")
    }
}

#Preview("Card — flowchart") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("md1"),
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
        renderer: MermaidWebViewRenderer()
    )
    .padding()
    .frame(width: 520, height: 420)
}

#Preview("Bare — streaming (no header yet)") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("md2"),
            type: .mermaid,
            payload: "flow",
            isComplete: false
        )
    )
    .artifactRenderer(MermaidWebViewRenderer())
    .padding()
    .frame(width: 420)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("md3"),
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
    }
    .artifactRenderer(MermaidWebViewRenderer())
    .padding()
    .frame(width: 520, height: 460)
}
