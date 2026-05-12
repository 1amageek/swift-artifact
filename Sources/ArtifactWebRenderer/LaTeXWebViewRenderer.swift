import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders LaTeX source via KaTeX inside a WKWebView. `displayMode` attribute
/// (`"block"` or `"inline"`, default `"block"`) chooses block vs inline math.
public struct LaTeXWebViewRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .latex

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        // KaTeX with `throwOnError: false` tolerates incomplete input, but
        // trailing backslashes / unbalanced braces cause flicker. Drop the
        // suffix from the last brace-balanced or word-boundary cut.
        let trimmed = LatexRefiner.trimTrailingIncomplete(artifact.payload)
        if trimmed.isEmpty {
            return .preRenderable(
                PreRenderableProgress(
                    receivedCharacters: artifact.payload.count,
                    hint: "waiting for first complete token"
                )
            )
        }
        return .renderable(trimmed)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        let displayMode = (artifact.attributes["displayMode"] ?? "block") != "inline"
        return ArtifactWebView(
            html: WebRendererShells.latex(payload: payload, displayMode: displayMode)
        )
        .frame(minHeight: 120)
    }
}

enum LatexRefiner {
    /// Drops trailing fragments that KaTeX would render mid-flight as glitchy:
    /// an unclosed brace group, or a dangling backslash command name. Returns
    /// the source unchanged once the structure balances out.
    static func trimTrailingIncomplete(_ source: String) -> String {
        // Step 1: cut at the last position where `{` / `}` are balanced.
        var depth = 0
        var lastBalanced = source.startIndex
        var index = source.startIndex
        while index < source.endIndex {
            let char = source[index]
            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth = max(0, depth - 1)
            }
            index = source.index(after: index)
            if depth == 0 {
                lastBalanced = index
            }
        }
        var prefix = String(source[..<lastBalanced])
        // Step 2: drop a trailing `\foo` command whose argument has not been
        // emitted yet (no whitespace / brace closes the name).
        if let backslash = prefix.lastIndex(of: "\\") {
            let suffix = prefix[prefix.index(after: backslash)...]
            if !suffix.isEmpty, suffix.allSatisfy({ $0.isLetter }) {
                prefix = String(prefix[..<backslash])
            }
        }
        return prefix
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

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("tex3"),
        type: .latex,
        title: "Quadratic formula",
        fullPayload: #"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#,
        chunkSize: 3,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(LaTeXWebViewRenderer())
    .padding()
    .frame(width: 460, height: 320)
}
