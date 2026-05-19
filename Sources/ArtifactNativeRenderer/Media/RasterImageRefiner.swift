import ArtifactCore
import ArtifactRenderer

enum RasterImageRefiner {
    static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        let payload = ArtifactBinaryPayloadResolver.trimmedPayload(artifact.payload)
        guard artifact.isComplete, payload.isEmpty == false else {
            return .preRenderable(
                PreRenderableProgress(
                    receivedCharacters: payload.count,
                    hint: "waiting for complete image payload"
                )
            )
        }
        return .renderable(payload)
    }
}
