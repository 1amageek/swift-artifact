import Foundation

/// Resolves source URLs and performs bounded text decoding for the view layer.
public protocol ArtifactFileResolving: Sendable {
    func resolve(_ request: ArtifactFileRequest) async throws -> ResolvedArtifactFile

    func textContents(
        of file: ResolvedArtifactFile,
        maximumByteCount: Int64
    ) async throws -> String
}
