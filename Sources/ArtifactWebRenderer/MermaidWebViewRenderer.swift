import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders Mermaid diagrams in a WKWebView.
///
/// Demonstrates the spec's dynamic refiner example: while bytes are still
/// arriving, `refine(_:)` repeatedly drops the trailing line until the partial
/// source passes `MermaidValidator.canParse`. The first prefix that parses
/// becomes the renderable subset; until then the placeholder is shown.
public struct MermaidWebViewRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .mermaid

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        // Iteratively drop trailing lines until the validator accepts the
        // remaining prefix. That keeps a half-written edge from causing the
        // mermaid.js parser to error and reset the rendered diagram.
        var lines = artifact.payload.split(separator: "\n", omittingEmptySubsequences: false)
        while !lines.isEmpty {
            let candidate = lines.joined(separator: "\n")
            if MermaidValidator.canParse(candidate) {
                return .renderable(candidate)
            }
            lines.removeLast()
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for diagram header"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        ArtifactWebView(html: WebRendererShells.mermaid(payload: payload))
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
        guard trimmed.contains("\n") else { return false }
        // Reject sources with an unclosed quoted label or unbalanced grouping.
        return hasBalancedTokens(trimmed)
    }

    private static func hasBalancedTokens(_ source: String) -> Bool {
        var inQuote = false
        var escape = false
        var paren = 0
        var bracket = 0
        var brace = 0
        for char in source {
            if escape {
                escape = false
                continue
            }
            if inQuote {
                if char == "\\" {
                    escape = true
                } else if char == "\"" {
                    inQuote = false
                }
                continue
            }
            switch char {
            case "\"": inQuote = true
            case "(": paren += 1
            case ")": paren -= 1
            case "[": bracket += 1
            case "]": bracket -= 1
            case "{": brace += 1
            case "}": brace -= 1
            default: break
            }
            if paren < 0 || bracket < 0 || brace < 0 { return false }
        }
        return !inQuote && paren == 0 && bracket == 0 && brace == 0
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
