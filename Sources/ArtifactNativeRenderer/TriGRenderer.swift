import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders `application/trig` artifacts as a force-directed diagram.
///
/// TriG is Turtle plus named-graph blocks. The view layer treats every quad
/// as a triple for visualisation; named-graph membership is not currently
/// drawn as a distinct visual region.
public struct TriGRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .trig
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        if KnowledgeGraphFormat.trig.hasRenderablePartial(
            artifact.payload,
            baseIRI: artifact.attributes["base"]
        ) {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first complete block"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        KnowledgeGraphRendererBody(artifact: artifact, payload: payload, format: .trig)
    }
}

#Preview("Card — small TriG graph") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("tg1"),
            type: .trig,
            title: "Named graphs",
            payload: """
            @prefix ex: <http://example.org/> .
            ex:g1 {
                ex:alice ex:knows ex:bob .
                ex:bob ex:knows ex:carol .
            }
            ex:g2 {
                ex:x ex:y ex:z .
            }
            """,
            isComplete: true
        ),
        renderer: TriGRenderer()
    )
    .padding()
    .frame(width: 520, height: 420)
}

#Preview("Bare — malformed TriG → error") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("tg2"),
            type: .trig,
            payload: """
            @prefix ex: <http://example.org/> .
            ex:g1 { ex:s ex:p
            """,
            isComplete: true
        )
    )
    .artifactRenderer(TriGRenderer())
    .padding()
    .frame(width: 420, height: 360)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("tg3"),
        type: .trig,
        title: "Streaming named graphs",
        fullPayload: """
        @prefix ex: <http://example.org/> .
        ex:friends {
            ex:alice ex:knows ex:bob .
            ex:bob ex:knows ex:carol .
            ex:carol ex:knows ex:dave .
        }
        ex:facts {
            ex:alice ex:name "Alice" .
            ex:bob ex:name "Bob" .
        }
        """,
        chunkSize: 8,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(TriGRenderer())
    .padding()
    .frame(width: 520, height: 460)
}
