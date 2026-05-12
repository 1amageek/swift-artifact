import Foundation

/// Intermediate value used when converting between `AnyArtifact` and concrete
/// `Artifactable` types.
public struct RawArtifact: Sendable, Equatable, Hashable {
    public let identifier: ArtifactIdentifier
    public let type: ArtifactType
    public let title: String
    public let payload: String
    public let attributes: [String: String]

    public init(
        identifier: ArtifactIdentifier,
        type: ArtifactType,
        title: String = "",
        payload: String = "",
        attributes: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.type = type
        self.title = title
        self.payload = payload
        self.attributes = attributes
    }
}

extension AnyArtifact {
    /// Drop the streaming flag and view this artifact through the conversion type.
    public var raw: RawArtifact {
        RawArtifact(
            identifier: id,
            type: type,
            title: title,
            payload: payload,
            attributes: attributes
        )
    }

    /// Build an `AnyArtifact` from a `RawArtifact`. Marked complete by default.
    public init(raw: RawArtifact, isComplete: Bool = true) {
        self.init(
            id: raw.identifier,
            type: raw.type,
            title: raw.title,
            attributes: raw.attributes,
            payload: raw.payload,
            isComplete: isComplete
        )
    }
}
