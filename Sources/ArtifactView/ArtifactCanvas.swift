import SwiftUI
import ArtifactCore
import ArtifactRenderer

/// Renders one `ArtifactMessage` — alternating prose and embedded artifacts —
/// inside a chat bubble.
///
/// Generic over the view returned by `renderArtifact`, so the closure can
/// return `some View` without any `AnyView` erasure at the call site.
public struct ArtifactCanvas<ArtifactBody: View>: View {
    public let message: ArtifactMessage
    private let fileRequest: ArtifactFileRequest?
    private let renderArtifact: @MainActor (AnyArtifact) -> ArtifactBody

    public init(
        _ message: ArtifactMessage,
        @ViewBuilder renderArtifact: @escaping @MainActor (AnyArtifact) -> ArtifactBody
    ) {
        self.message = message
        self.fileRequest = nil
        self.renderArtifact = renderArtifact
    }

    public init(
        url: URL,
        type: ArtifactType? = nil,
        title: String? = nil,
        loadingPolicy: ArtifactFileLoadingPolicy = .standard,
        @ViewBuilder renderArtifact: @escaping @MainActor (AnyArtifact) -> ArtifactBody
    ) {
        self.message = .empty
        self.fileRequest = ArtifactFileRequest(
            url: url,
            declaredType: type,
            title: title,
            policy: loadingPolicy
        )
        self.renderArtifact = renderArtifact
    }

    public var body: some View {
        Group {
            if let fileRequest {
                ArtifactURLCanvas(
                    request: fileRequest,
                    renderArtifact: renderArtifact
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(message.segments) { segment in
                        switch segment {
                        case .text(let text):
                            Text(text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .artifact(let artifact):
                            renderArtifact(artifact)
                        }
                    }
                }
            }
        }
    }
}

extension ArtifactCanvas where ArtifactBody == ArtifactCard<ArtifactView, EmptyView> {
    /// Default canvas that wraps every artifact in `ArtifactCard` and resolves
    /// the renderer from the environment registry. Register concrete
    /// renderers with `.artifactRenderer(_:)` somewhere above this view; any
    /// unmapped artifact falls back to `DefaultArtifactView`.
    public init(_ message: ArtifactMessage) {
        self.init(message) { artifact in
            ArtifactCard(artifact)
        }
    }

    /// Parse a completed message and render any embedded artifacts. Malformed
    /// artifact markup remains visible as plain text instead of disappearing.
    public init(text: String) {
        let parsedMessage: ArtifactMessage
        do {
            parsedMessage = try ArtifactParser.parse(text)
        } catch {
            parsedMessage = ArtifactMessage(segments: [.text(text)])
        }
        self.init(parsedMessage)
    }

    /// Resolve a local or remote file and render it through the environment
    /// registry. The declared type is optional; the resolver otherwise uses
    /// magic bytes, filename, response metadata, and text detection.
    public init(
        url: URL,
        type: ArtifactType? = nil,
        title: String? = nil,
        loadingPolicy: ArtifactFileLoadingPolicy = .standard
    ) {
        self.init(
            url: url,
            type: type,
            title: title,
            loadingPolicy: loadingPolicy
        ) { artifact in
            ArtifactCard(artifact)
        }
    }
}

private struct ArtifactURLCanvas<ArtifactBody: View>: View {
    let request: ArtifactFileRequest
    let renderArtifact: @MainActor (AnyArtifact) -> ArtifactBody

    @Environment(\.artifactFileResolver) private var fileResolver
    @Environment(\.artifactRenderers) private var renderers
    @State private var state: ArtifactURLCanvasState = .loading
    @State private var retryAttempt = 0

    var body: some View {
        Group {
            switch state {
            case .loading:
                let title = ArtifactFileArtifactLoader.displayTitle(for: request)
                ProgressView("Loading \(title)")
                    .frame(maxWidth: .infinity, minHeight: 160)
            case let .loaded(artifact):
                renderArtifact(artifact)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Unable to render file", systemImage: "doc.badge.xmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        retryAttempt += 1
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task(
            id: ArtifactURLLoadID(
                request: request,
                attempt: retryAttempt,
                rendererInputs: rendererInputSignature
            )
        ) {
            await loadArtifact()
        }
    }

    @MainActor
    private func loadArtifact() async {
        state = .loading
        do {
            let loader = ArtifactFileArtifactLoader(resolver: fileResolver)
            let artifact = try await loader.load(request, renderers: renderers)
            guard !Task.isCancelled else { return }
            state = .loaded(artifact)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    private var rendererInputSignature: [ArtifactRendererInputID] {
        renderers
            .map { type, renderer in
                ArtifactRendererInputID(type: type, fileInput: renderer.fileInput)
            }
            .sorted { $0.type.rawValue < $1.type.rawValue }
    }
}

private enum ArtifactURLCanvasState {
    case loading
    case loaded(AnyArtifact)
    case failed(String)
}

private struct ArtifactURLLoadID: Hashable {
    let request: ArtifactFileRequest
    let attempt: Int
    let rendererInputs: [ArtifactRendererInputID]
}

private struct ArtifactRendererInputID: Hashable {
    let type: ArtifactType
    let fileInput: ArtifactFileInput
}

private struct _PreviewMarkdownRenderer: ArtifactRenderable, Sendable {
    static let artifactType: ArtifactType = .markdown
    func body(artifact: AnyArtifact, payload: String) -> some View {
        Text(payload)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.payload.isEmpty {
            return .preRenderable(PreRenderableProgress(receivedCharacters: 0))
        }
        return .renderable(artifact.payload)
    }
}

#Preview("Prose + artifact (integration)") {
    let artifact = AnyArtifact(
        id: ArtifactIdentifier("k1"),
        type: .markdown,
        title: "Quarterly summary",
        payload: """
        ## Highlights
        - Revenue up 12%
        - 4 new product launches
        - 87 NPS
        """,
        isComplete: true
    )
    let message = ArtifactMessage(segments: [
        .text("Here's a quick read on the quarter:"),
        .artifact(artifact),
        .text("Let me know if you want me to dig deeper on any of these."),
    ])
    return ScrollView {
        ArtifactCanvas(message)
            .padding()
    }
    .artifactRenderer(_PreviewMarkdownRenderer())
    .frame(width: 460, height: 480)
}

#Preview("Text only") {
    ArtifactCanvas(
        ArtifactMessage(segments: [
            .text("No artifacts in this message — just prose."),
        ])
    )
    .padding()
    .frame(width: 460)
}
