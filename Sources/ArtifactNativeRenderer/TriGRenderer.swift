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
        if parseSucceeds(artifact.payload, baseIRI: artifact.attributes["base"]) {
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

    private static func parseSucceeds(_ source: String, baseIRI: String?) -> Bool {
        do {
            _ = try KnowledgeGraphFormat.trig.parse(source, scope: "preview", baseIRI: baseIRI)
            return true
        } catch {
            return false
        }
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
