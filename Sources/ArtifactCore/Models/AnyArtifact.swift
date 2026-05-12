import Foundation

/// A parsed artifact, complete or mid-stream.
///
/// The same type represents both finalized artifacts and ones still being streamed.
/// Streaming progress is encoded in `payload` (which grows) and `isComplete` (which
/// flips when the closing tag is observed). Renderers decide how to interpret these.
public struct AnyArtifact: Identifiable, Sendable, Equatable, Hashable {
    public typealias ID = ArtifactIdentifier

    public let id: ArtifactIdentifier
    public let type: ArtifactType
    public let title: String
    public let attributes: [String: String]

    /// Body text accumulated between `<artifact ...>` and `</artifact>`.
    public let payload: String

    /// `true` once the closing tag has been observed.
    public let isComplete: Bool

    public init(
        id: ArtifactIdentifier,
        type: ArtifactType,
        title: String = "",
        attributes: [String: String] = [:],
        payload: String = "",
        isComplete: Bool = false
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.attributes = attributes
        self.payload = payload
        self.isComplete = isComplete
    }
}
