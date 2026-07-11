import SwiftUI
import ArtifactCore
import ArtifactRenderer

/// Generic fallback view used when no renderer is registered for the artifact's
/// type. Shows the raw payload in a monospaced scroll. Pair with `ArtifactCard`
/// if you want header chrome.
public struct DefaultArtifactView: View {
    public let artifact: AnyArtifact

    public init(_ artifact: AnyArtifact) {
        self.artifact = artifact
    }

    public var body: some View {
        Group {
            if let localFileURL {
                fileFallback(localFileURL)
            } else {
                ArtifactBoundedScrollView(
                    .vertical,
                    contentInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
                ) {
                    Text(artifact.payload)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func fileFallback(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.lastPathComponent)
                        .font(.callout.weight(.semibold))
                    Text(artifact.type.rawValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let byteCount = artifact.attributes["byteCount"] {
                        Text("\(byteCount) bytes")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Link(destination: url) {
                Label("Open File", systemImage: "arrow.up.right.square")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localFileURL: URL? {
        let payload = artifact.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: payload), url.isFileURL else { return nil }
        return url
    }
}

#Preview("Bare") {
    DefaultArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("u1"),
            type: "application/vnd.example.unknown",
            title: "Unrecognised payload",
            payload: """
            {
              "kind": "fallback",
              "note": "No registered renderer for this MIME type."
            }
            """,
            isComplete: true
        )
    )
    .padding()
    .frame(width: 420)
}

#Preview("Wrapped in card") {
    let artifact = AnyArtifact(
        id: ArtifactIdentifier("u2"),
        type: "application/vnd.example.unknown",
        title: "Unrecognised payload",
        payload: """
        {
          "kind": "fallback",
          "note": "No registered renderer for this MIME type."
        }
        """,
        isComplete: true
    )
    return ArtifactCard(artifact: artifact) {
        DefaultArtifactView(artifact)
    }
    .padding()
    .frame(width: 420)
}
