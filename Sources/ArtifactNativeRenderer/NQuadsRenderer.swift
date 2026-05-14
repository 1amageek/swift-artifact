import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders `application/n-quads` artifacts as a force-directed diagram.
///
/// N-Quads is strictly line-delimited (`subject predicate object [graph] .`),
/// so a per-line streaming attempt — try parsing each accumulated prefix —
/// surfaces parseable subsets as soon as a complete line arrives.
public struct NQuadsRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .nQuads
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        if let prefix = longestParseablePrefix(of: artifact.payload, baseIRI: artifact.attributes["base"]) {
            return .renderable(prefix)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first complete quad"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        KnowledgeGraphRendererBody(artifact: artifact, payload: payload, format: .nQuads)
    }

    /// Largest prefix terminating on a `\n` boundary that parses cleanly.
    /// Each line ends with `.\n` in N-Quads, so cutting at the last newline
    /// gives a complete-quad prefix without needing a tokenizer.
    private static func longestParseablePrefix(of source: String, baseIRI: String?) -> String? {
        guard let lastNewline = source.range(of: "\n", options: .backwards) else { return nil }
        let prefix = String(source[..<lastNewline.upperBound])
        guard !prefix.isEmpty else { return nil }
        do {
            _ = try KnowledgeGraphFormat.nQuads.parse(prefix, scope: "preview", baseIRI: baseIRI)
            return prefix
        } catch {
            return nil
        }
    }
}

#Preview("Card — small N-Quads graph") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("nq1"),
            type: .nQuads,
            title: "Quads",
            payload: """
            <http://example.org/alice> <http://example.org/knows> <http://example.org/bob> <http://example.org/g1> .
            <http://example.org/bob> <http://example.org/knows> <http://example.org/carol> <http://example.org/g1> .
            <http://example.org/carol> <http://example.org/name> "Carol" .

            """,
            isComplete: true
        ),
        renderer: NQuadsRenderer()
    )
    .padding()
    .frame(width: 520, height: 420)
}
