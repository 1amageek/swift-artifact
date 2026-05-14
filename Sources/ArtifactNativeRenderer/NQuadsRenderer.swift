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
        if KnowledgeGraphFormat.nQuads.hasRenderablePartial(
            artifact.payload,
            baseIRI: artifact.attributes["base"]
        ) {
            return .renderable(artifact.payload)
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

#Preview("Bare — malformed N-Quads → error") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("nq2"),
            type: .nQuads,
            payload: """
            <http://example.org/alice> <http://example.org/knows>
            """,
            isComplete: true
        )
    )
    .artifactRenderer(NQuadsRenderer())
    .padding()
    .frame(width: 420, height: 360)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("nq3"),
        type: .nQuads,
        title: "Streaming quads",
        fullPayload: """
        <http://example.org/alice> <http://example.org/knows> <http://example.org/bob> <http://example.org/g1> .
        <http://example.org/bob> <http://example.org/knows> <http://example.org/carol> <http://example.org/g1> .
        <http://example.org/carol> <http://example.org/knows> <http://example.org/dave> <http://example.org/g1> .
        <http://example.org/alice> <http://example.org/name> "Alice" .
        <http://example.org/bob> <http://example.org/name> "Bob" .
        <http://example.org/carol> <http://example.org/name> "Carol" .

        """,
        chunkSize: 12,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(NQuadsRenderer())
    .padding()
    .frame(width: 520, height: 460)
}
