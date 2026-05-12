import SwiftUI
import ArtifactCore
import ArtifactRenderer

/// A framed presentation for an artifact: header (title + type badge),
/// body slot, and a footer with affordances.
///
/// The card is chrome only — pair it with `ArtifactView<R>` (or any view)
/// to provide the body. Custom header buttons go into the `actions` slot;
/// they render between the streaming progress indicator and the built-in
/// disclosure button.
public struct ArtifactCard<Content: View, Actions: View>: View {
    public let artifact: AnyArtifact
    public let content: Content
    public let actions: Actions
    private let isEmpty: Bool

    @Environment(\.artifactCardContentInsets) private var contentInsets
    @Environment(\.artifactCardDisclosureVisibility) private var disclosureVisibility
    @State private var isExpanded: Bool = true

    public init(
        artifact: AnyArtifact,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.artifact = artifact
        self.content = content()
        self.actions = actions()
        self.isEmpty = false
    }

    fileprivate init(
        artifact: AnyArtifact,
        content: Content,
        actions: Actions,
        isEmpty: Bool
    ) {
        self.artifact = artifact
        self.content = content
        self.actions = actions
        self.isEmpty = isEmpty
    }

    public var body: some View {
        if isEmpty {
            EmptyView()
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(showsBody ? 1 : 0)
            if showsBody {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(contentInsets)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.callout.weight(.semibold))
                Text(artifact.type.rawValue)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !artifact.isComplete {
                ProgressView()
                    .controlSize(.mini)
            }
            actions
            if showsDisclosure {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse artifact" : "Expand artifact")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var showsDisclosure: Bool {
        disclosureVisibility != .hidden
    }

    private var showsBody: Bool {
        !showsDisclosure || isExpanded
    }

    private var displayTitle: String {
        artifact.title.isEmpty ? "Artifact" : artifact.title
    }
}

extension ArtifactCard where Actions == EmptyView {
    public init(
        artifact: AnyArtifact,
        @ViewBuilder content: () -> Content
    ) {
        self.init(artifact: artifact, content: content) { EmptyView() }
    }
}

extension ArtifactCard {
    /// Wraps an artifact rendered by an explicit renderer in card chrome.
    /// Hides the whole card while the artifact has no payload bytes and is
    /// still streaming — there is nothing useful to show yet, not even a
    /// title bar.
    public init<R: ArtifactRenderable>(
        _ artifact: AnyArtifact,
        renderer: R,
        @ViewBuilder actions: () -> Actions
    ) where Content == _ArtifactView<R> {
        let hideCard = artifact.payload.isEmpty && !artifact.isComplete
        self.init(
            artifact: artifact,
            content: _ArtifactView(artifact, renderer: renderer),
            actions: actions(),
            isEmpty: hideCard
        )
    }
}

extension ArtifactCard where Actions == EmptyView {
    public init<R: ArtifactRenderable>(
        _ artifact: AnyArtifact,
        renderer: R
    ) where Content == _ArtifactView<R> {
        self.init(artifact, renderer: renderer) { EmptyView() }
    }
}

extension ArtifactCard where Content == ArtifactView, Actions == EmptyView {
    /// Wraps an environment-resolved artifact in card chrome. Pair with
    /// `.artifactRenderer(_:)` somewhere above this view to provide the
    /// concrete renderer.
    public init(_ artifact: AnyArtifact) {
        self.init(artifact: artifact, content: ArtifactView(artifact), actions: EmptyView(), isEmpty: false)
    }
}

extension ArtifactCard where Content == ArtifactView {
    public init(
        _ artifact: AnyArtifact,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(artifact: artifact, content: ArtifactView(artifact), actions: actions(), isEmpty: false)
    }
}

private struct _PreviewMarkdownRenderer: ArtifactRenderable {
    static let artifactType: ArtifactType = .markdown
    func body(artifact: AnyArtifact, payload: String) -> some View {
        Text(payload).frame(maxWidth: .infinity, alignment: .leading)
    }
    static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.payload.isEmpty {
            return .preRenderable(PreRenderableProgress(receivedCharacters: 0))
        }
        return .renderable(artifact.payload)
    }
}

#Preview("Card via renderer") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("c1"),
            type: .markdown,
            title: "Release notes",
            payload: "**1.0** shipped today.",
            isComplete: true
        ),
        renderer: _PreviewMarkdownRenderer()
    )
    .padding()
    .frame(width: 420)
}

#Preview("Streaming") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("c2"),
            type: .markdown,
            title: "Mid-stream",
            payload: "in flight",
            isComplete: false
        ),
        renderer: _PreviewMarkdownRenderer()
    )
    .padding()
    .frame(width: 420)
}

#Preview("With custom actions") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("c3"),
            type: .markdown,
            title: "Release notes",
            payload: "Body content.",
            isComplete: true
        ),
        renderer: _PreviewMarkdownRenderer()
    ) {
        Button {
        } label: {
            Image(systemName: "square.and.arrow.up")
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Button {
        } label: {
            Image(systemName: "doc.on.doc")
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    .padding()
    .frame(width: 460)
}

#Preview("Generic content slot") {
    ArtifactCard(
        artifact: AnyArtifact(
            id: ArtifactIdentifier("c4"),
            type: .markdown,
            title: "Custom body",
            payload: "",
            isComplete: true
        )
    ) {
        Text("Hand-rolled body content")
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding()
    .frame(width: 420)
}
