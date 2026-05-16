import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders a JSX payload by transpiling it via Babel standalone inside a
/// WKWebView and mounting it with React 18.
///
/// React is mount-once, so partial JSX cannot be displayed meaningfully. The
/// renderer shows the streaming progress placeholder until the artifact closes.
public struct ReactWebViewRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .react
    /// The React document shell owns its body padding.
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for complete JSX source"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        ArtifactWebView(html: WebRendererShells.react(payload: payload))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Card — counter component") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("r1"),
            type: .react,
            title: "Counter.jsx",
            payload: """
            function Counter() {
              const [n, setN] = React.useState(0);
              return (
                <div style={{padding: 24, fontFamily: '-apple-system'}}>
                  <h2>Count: {n}</h2>
                  <button onClick={() => setN(n + 1)}>Increment</button>
                </div>
              );
            }
            ReactDOM.createRoot(document.getElementById('root')).render(<Counter/>);
            """,
            isComplete: true
        ),
        renderer: ReactWebViewRenderer()
    )
    .frame(width: 480, height: 440)
}

#Preview("Bare — streaming placeholder") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("r2"),
            type: .react,
            title: "Streaming JSX",
            payload: "function Half() { retur",
            isComplete: false
        )
    )
    .artifactRenderer(ReactWebViewRenderer())
    .frame(width: 420)
}
