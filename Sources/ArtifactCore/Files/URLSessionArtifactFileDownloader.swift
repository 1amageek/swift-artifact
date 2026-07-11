import Foundation

/// The standard artifact downloader backed by `URLSession`.
public struct URLSessionArtifactFileDownloader: ArtifactFileDownloading, Sendable {
    public init() {}

    public func download(from url: URL) async throws -> ArtifactFileDownload {
        let (temporaryFileURL, response) = try await URLSession.shared.download(from: url)
        return ArtifactFileDownload(
            temporaryFileURL: temporaryFileURL,
            statusCode: (response as? HTTPURLResponse)?.statusCode,
            expectedContentLength: response.expectedContentLength,
            mediaType: response.mimeType
        )
    }
}
