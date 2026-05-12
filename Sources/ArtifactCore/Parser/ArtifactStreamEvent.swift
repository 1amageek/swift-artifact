import Foundation

/// Low-level streaming event emitted by `ArtifactStreamParser.feedEvents(_:)`.
public enum ArtifactStreamEvent: Sendable, Equatable, Hashable {
    /// A run of prose text.
    case text(String)

    /// An artifact opening tag was parsed; payload may still be empty.
    case opened(AnyArtifact)

    /// A new chunk of payload was appended to the named artifact.
    case delta(id: ArtifactIdentifier, chunk: String)

    /// The closing tag was observed for the named artifact.
    case closed(id: ArtifactIdentifier)
}
