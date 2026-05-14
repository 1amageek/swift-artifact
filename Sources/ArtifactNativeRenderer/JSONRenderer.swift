import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders JSON payloads. Once parseable, the value is pretty-printed; until
/// then the raw bytes are shown so streaming output is still inspectable.
public struct JSONRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .json

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        if let valid = PartialJSONScanner.longestValidPrefix(artifact.payload) {
            return .renderable(valid)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first complete value"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(prettyPrint(payload))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .artifactContentHeightLimit()
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
        renderer: JSONRenderer()
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
    .artifactRenderer(JSONRenderer())
    .padding()
    .frame(width: 460)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("j3"),
        type: .json,
        title: "config.json",
        fullPayload: #"""
        {
          "name": "Bob",
          "version": "0.1.0",
          "modules": [
            "ArtifactCore",
            "ArtifactRenderer",
            "ArtifactView",
            "ArtifactNativeRenderer",
            "ArtifactWebRenderer"
          ],
          "platforms": {
            "iOS": 26,
            "macOS": 26,
            "visionOS": 26
          }
        }
        """#,
        chunkSize: 6,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(JSONRenderer())
    .padding()
    .frame(width: 480, height: 500)
}
