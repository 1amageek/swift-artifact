import Foundation

/// Downloads a source URL to a temporary regular file.
///
/// Ownership of the returned file transfers to the resolver, which moves or removes it.
public protocol ArtifactFileDownloading: Sendable {
    func download(from url: URL) async throws -> ArtifactFileDownload
}
