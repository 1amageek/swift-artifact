import Foundation

public enum ArtifactError: Error, Equatable, Sendable {
    /// Tried to extract a single artifact but none was present.
    case noArtifactFound

    /// `<artifact ...>` was opened but never closed before end-of-input
    /// (synchronous parser only).
    case unterminatedArtifact(ArtifactIdentifier)

    /// Malformed open tag could not be parsed into attributes.
    case malformedOpenTag(String)

    /// Required attribute missing from open tag.
    case missingRequiredAttribute(String)

    /// `RawArtifact.type` did not match the expected `Artifactable.artifactType`.
    case typeMismatch(expected: ArtifactType, actual: ArtifactType)
}
