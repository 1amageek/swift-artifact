import Foundation

/// One chat-bubble worth of content: prose text and embedded artifacts in the
/// order they were produced.
public struct ArtifactMessage: Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let segments: [Segment]

    public init(id: UUID = UUID(), segments: [Segment] = []) {
        self.id = id
        self.segments = segments
    }

    public enum Segment: Identifiable, Sendable, Equatable, Hashable {
        case text(String)
        case artifact(AnyArtifact)

        public var id: String {
            switch self {
            case .text(let value):
                // Text segments use a content hash so identity is stable across
                // re-renders of the same prose.
                return "text:\(value.hashValue)"
            case .artifact(let artifact):
                return "artifact:\(artifact.id.rawValue)"
            }
        }
    }
}

extension ArtifactMessage {
    public static let empty: ArtifactMessage = ArtifactMessage(segments: [])

    /// All artifacts contained in the message, in document order.
    public var artifacts: [AnyArtifact] {
        segments.compactMap { segment in
            if case .artifact(let artifact) = segment { return artifact }
            return nil
        }
    }

    /// All text segments concatenated in document order.
    public var plainText: String {
        segments.compactMap { segment -> String? in
            if case .text(let value) = segment { return value }
            return nil
        }.joined()
    }
}
