import Foundation

/// An immutable request to resolve a local or remote artifact file.
public struct ArtifactFileRequest: Sendable, Hashable {
    public let url: URL
    public let declaredType: ArtifactType?
    public let title: String?
    public let policy: ArtifactFileLoadingPolicy

    public init(
        url: URL,
        declaredType: ArtifactType? = nil,
        title: String? = nil,
        policy: ArtifactFileLoadingPolicy = .standard
    ) {
        self.url = url
        self.declaredType = declaredType
        self.title = title
        self.policy = policy
    }
}
