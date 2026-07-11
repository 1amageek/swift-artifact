import Foundation

/// A source file resolved to a validated local URL with a canonical artifact type.
public struct ResolvedArtifactFile: Sendable, Hashable {
    public let sourceURL: URL
    public let localFileURL: URL
    public let type: ArtifactType
    public let byteCount: Int64
    public let responseMediaType: String?
    public let isRemote: Bool

    public init(
        sourceURL: URL,
        localFileURL: URL,
        type: ArtifactType,
        byteCount: Int64,
        responseMediaType: String? = nil,
        isRemote: Bool
    ) {
        self.sourceURL = sourceURL
        self.localFileURL = localFileURL
        self.type = type
        self.byteCount = byteCount
        self.responseMediaType = responseMediaType
        self.isRemote = isRemote
    }
}
