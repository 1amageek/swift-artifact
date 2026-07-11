import Foundation

/// Determines an artifact MIME type from declared and observed file metadata.
public protocol ArtifactFileTypeDetecting: Sendable {
    func detectType(for request: ArtifactFileTypeDetectionRequest) throws -> ArtifactType
}
