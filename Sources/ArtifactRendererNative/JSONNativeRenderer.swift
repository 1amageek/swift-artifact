import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders JSON payloads. Once parseable, the value is pretty-printed; until
/// then the raw bytes are shown so streaming output is still inspectable.
public struct JSONNativeRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .json

    public init() {}

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        return artifact.isComplete ? .complete : .partial
    }

    public func body(artifact: AnyArtifact) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(prettyPrint(artifact.payload))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 360)
    }

    private func prettyPrint(_ source: String) -> String {
        guard let data = source.data(using: .utf8) else { return source }
        do {
            let object = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
            let pretty = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(data: pretty, encoding: .utf8) ?? source
        } catch {
            return source
        }
    }
}

#Preview("Card — pretty-printed object") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("j1"),
            type: .json,
            title: "config.json",
            payload: #"{"name":"Bob","version":"0.1.0","tiers":[1,2,3]}"#,
            isComplete: true
        ),
        renderer: JSONNativeRenderer()
    )
    .padding()
    .frame(width: 460)
}

#Preview("Bare — partial JSON (raw fallback)") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("j2"),
            type: .json,
            payload: #"{"name":"Bob","ver"#,
            isComplete: false
        )
    )
    .artifactRenderer(JSONNativeRenderer())
    .padding()
    .frame(width: 460)
}
