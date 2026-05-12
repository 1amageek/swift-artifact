import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders LaTeX source via KaTeX inside a WKWebView. `displayMode` attribute
/// (`"block"` or `"inline"`, default `"block"`) chooses block vs inline math.
public struct LaTeXWebViewRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .latex

    public init() {}

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        // KaTeX's `throwOnError: false` tolerates incomplete input.
        return artifact.isComplete ? .complete : .partial
    }

    public func body(artifact: AnyArtifact) -> some View {
        let displayMode = (artifact.attributes["displayMode"] ?? "block") != "inline"
        return ArtifactWebView(
            html: WebRendererShells.latex(payload: artifact.payload, displayMode: displayMode)
        )
        .frame(minHeight: 120)
    }
}

#Preview("Card — block math") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("tex1"),
            type: .latex,
            title: "Quadratic formula",
            payload: #"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#,
            isComplete: true
        ),
        renderer: LaTeXWebViewRenderer()
    )
    .padding()
    .frame(width: 460)
}

#Preview("Bare — inline math") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("tex2"),
            type: .latex,
            title: "Pythagoras",
            attributes: ["displayMode": "inline"],
            payload: #"a^2 + b^2 = c^2"#,
            isComplete: true
        )
    )
    .artifactRenderer(LaTeXWebViewRenderer())
    .padding()
    .frame(width: 460)
}
