import Foundation

/// A concrete artifact type that knows how to round-trip through `RawArtifact`.
public protocol Artifactable: Sendable {
    static var artifactType: ArtifactType { get }

    init(from raw: RawArtifact) throws
    var rawArtifact: RawArtifact { get }
}
