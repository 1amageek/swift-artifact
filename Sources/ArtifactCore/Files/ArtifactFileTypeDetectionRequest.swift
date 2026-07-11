import Foundation

/// Inputs available to an artifact file type detector.
public struct ArtifactFileTypeDetectionRequest: Sendable, Hashable {
    public let sourceURL: URL
    public let localFileURL: URL
    public let declaredType: ArtifactType?
    public let responseMediaType: String?

    public init(
        sourceURL: URL,
        localFileURL: URL,
        declaredType: ArtifactType? = nil,
        responseMediaType: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.localFileURL = localFileURL
        self.declaredType = declaredType
        self.responseMediaType = responseMediaType
    }
}
