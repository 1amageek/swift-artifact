import SwiftUI
import ArtifactCore

/// Drives an `AnyArtifact` payload from empty to the supplied final string in
/// timed chunks. Designed for SwiftUI Previews — wraps any view that consumes
/// an `AnyArtifact` and replays a streaming session so partial / complete
/// rendering paths can be inspected visually.
///
/// The harness tracks the number of characters revealed so far. On each tick
/// (`interval`) it advances by `chunkSize` characters, marking the artifact
/// `isComplete` only on the final tick. Tap the harness to restart playback.
public struct StreamingPreviewHarness<Content: View>: View {
    public let id: ArtifactIdentifier
    public let type: ArtifactType
    public let title: String
    public let attributes: [String: String]
    public let fullPayload: String
    public let chunkSize: Int
    public let interval: Duration
    private let content: (AnyArtifact) -> Content

    @State private var revealedCount: Int = 0
    @State private var runID: UUID = UUID()

    public init(
        id: ArtifactIdentifier,
        type: ArtifactType,
        title: String = "",
        attributes: [String: String] = [:],
        fullPayload: String,
        chunkSize: Int = 16,
        interval: Duration = .milliseconds(300),
        @ViewBuilder content: @escaping (AnyArtifact) -> Content
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.attributes = attributes
        self.fullPayload = fullPayload
        self.chunkSize = max(1, chunkSize)
        self.interval = interval
        self.content = content
    }

    public var body: some View {
        let totalCount = fullPayload.count
        let clamped = min(revealedCount, totalCount)
        let prefix = String(fullPayload.prefix(clamped))
        let isComplete = clamped >= totalCount
        let artifact = AnyArtifact(
            id: id,
            type: type,
            title: title,
            attributes: attributes,
            payload: prefix,
            isComplete: isComplete
        )

        return VStack(alignment: .leading, spacing: 8) {
            content(artifact)
            statusBar(revealed: clamped, total: totalCount, isComplete: isComplete)
        }
        .contentShape(Rectangle())
        .onTapGesture { runID = UUID() }
        .task(id: runID) {
            revealedCount = 0
            await play(totalCount: totalCount)
        }
    }

    private func play(totalCount: Int) async {
        guard totalCount > 0 else {
            revealedCount = 0
            return
        }
        while revealedCount < totalCount {
            do {
                try await Task.sleep(for: interval)
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unexpected sleep error: \(error)")
                return
            }
            revealedCount = min(revealedCount + chunkSize, totalCount)
        }
    }

    private func statusBar(revealed: Int, total: Int, isComplete: Bool) -> some View {
        HStack(spacing: 8) {
            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text("\(revealed)/\(total) chars · tap to replay")
                .font(.caption2)
                .monospaced()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
