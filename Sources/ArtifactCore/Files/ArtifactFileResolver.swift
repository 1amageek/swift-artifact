import Foundation
import UniformTypeIdentifiers

/// Resolves local and HTTP(S) source URLs into validated local files.
///
/// The actor serializes cache mutation while callers await network and file I/O.
public actor ArtifactFileResolver: ArtifactFileResolving {
    public static let shared = ArtifactFileResolver()

    private struct CachedRemoteFile: Sendable {
        let localFileURL: URL
        let responseMediaType: String?
    }

    private let downloader: any ArtifactFileDownloading
    private let typeDetector: any ArtifactFileTypeDetecting
    private let cacheNamespace = UUID()
    private var cachedRemoteFiles: [URL: CachedRemoteFile] = [:]
    private var cacheDirectory: URL?

    public init(
        downloader: any ArtifactFileDownloading = URLSessionArtifactFileDownloader(),
        typeDetector: any ArtifactFileTypeDetecting = DefaultArtifactFileTypeDetector()
    ) {
        self.downloader = downloader
        self.typeDetector = typeDetector
    }

    public func resolve(
        _ request: ArtifactFileRequest
    ) async throws -> ResolvedArtifactFile {
        try validate(request.policy)

        if request.url.isFileURL {
            return try resolveLocalFile(request)
        }

        let scheme = request.url.scheme?.lowercased() ?? ""
        let isAllowedHTTP = scheme == "http" && request.policy.allowsInsecureHTTP
        guard scheme == "https" || isAllowedHTTP else {
            let reportedScheme = scheme.isEmpty ? "none" : scheme
            throw ArtifactFileError.unsupportedURLScheme(reportedScheme)
        }

        let cached = try await cachedOrDownloadedFile(for: request)
        let byteCount = try regularFileByteCount(at: cached.localFileURL)
        guard byteCount <= request.policy.maximumRemoteByteCount else {
            throw ArtifactFileError.remoteFileTooLarge(
                url: request.url.absoluteString,
                byteCount: byteCount,
                limit: request.policy.maximumRemoteByteCount
            )
        }
        return try resolvedFile(
            request: request,
            localFileURL: cached.localFileURL,
            byteCount: byteCount,
            responseMediaType: cached.responseMediaType,
            isRemote: true
        )
    }

    public func textContents(
        of file: ResolvedArtifactFile,
        maximumByteCount: Int64
    ) async throws -> String {
        guard maximumByteCount > 0 else {
            throw ArtifactFileError.invalidLimit(
                name: "maximumTextByteCount",
                value: maximumByteCount
            )
        }

        let currentByteCount = try regularFileByteCount(at: file.localFileURL)
        guard currentByteCount <= maximumByteCount else {
            throw ArtifactFileError.textFileTooLarge(
                path: file.localFileURL.path(percentEncoded: false),
                byteCount: currentByteCount,
                limit: maximumByteCount
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: file.localFileURL, options: [.mappedIfSafe])
        } catch {
            throw ArtifactFileError.readFailed(
                path: file.localFileURL.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ArtifactFileError.invalidUTF8(
                file.localFileURL.path(percentEncoded: false)
            )
        }
        return text
    }

    /// Removes files cached by this resolver instance.
    public func clearCache() throws {
        cachedRemoteFiles.removeAll()
        guard let cacheDirectory else { return }
        let cachePath = cacheDirectory.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: cachePath) {
            do {
                try FileManager.default.removeItem(at: cacheDirectory)
            } catch {
                throw ArtifactFileError.cacheWriteFailed(
                    path: cacheDirectory.path(percentEncoded: false),
                    reason: error.localizedDescription
                )
            }
        }
        self.cacheDirectory = nil
    }

    private func validate(_ policy: ArtifactFileLoadingPolicy) throws {
        guard policy.maximumRemoteByteCount > 0 else {
            throw ArtifactFileError.invalidLimit(
                name: "maximumRemoteByteCount",
                value: policy.maximumRemoteByteCount
            )
        }
        guard policy.maximumTextByteCount > 0 else {
            throw ArtifactFileError.invalidLimit(
                name: "maximumTextByteCount",
                value: policy.maximumTextByteCount
            )
        }
    }

    private func resolveLocalFile(
        _ request: ArtifactFileRequest
    ) throws -> ResolvedArtifactFile {
        let sourceURL = request.url.standardizedFileURL
        do {
            return try resolvedLocalFile(
                request: request,
                localFileURL: sourceURL
            )
        } catch let initialError as ArtifactFileError {
            guard shouldRetryWithSecurityScopedAccess(initialError),
                  sourceURL.startAccessingSecurityScopedResource()
            else {
                throw initialError
            }
            defer {
                sourceURL.stopAccessingSecurityScopedResource()
            }

            let byteCount = try regularFileByteCount(at: sourceURL)
            let cachedURL = try cachedDestination(
                for: sourceURL,
                declaredType: request.declaredType
            )
            do {
                try FileManager.default.copyItem(at: sourceURL, to: cachedURL)
            } catch {
                throw ArtifactFileError.cacheWriteFailed(
                    path: cachedURL.path(percentEncoded: false),
                    reason: error.localizedDescription
                )
            }
            return try resolvedFile(
                request: request,
                localFileURL: cachedURL,
                byteCount: byteCount,
                responseMediaType: nil,
                isRemote: false
            )
        }
    }

    private func resolvedLocalFile(
        request: ArtifactFileRequest,
        localFileURL: URL
    ) throws -> ResolvedArtifactFile {
        let byteCount = try regularFileByteCount(at: localFileURL)
        return try resolvedFile(
            request: request,
            localFileURL: localFileURL,
            byteCount: byteCount,
            responseMediaType: nil,
            isRemote: false
        )
    }

    private func shouldRetryWithSecurityScopedAccess(
        _ error: ArtifactFileError
    ) -> Bool {
        switch error {
        case .fileNotFound, .metadataUnavailable, .readFailed:
            return true
        default:
            return false
        }
    }

    private func cachedOrDownloadedFile(
        for request: ArtifactFileRequest
    ) async throws -> CachedRemoteFile {
        if let cached = cachedRemoteFiles[request.url],
           FileManager.default.fileExists(
               atPath: cached.localFileURL.path(percentEncoded: false)
           ) {
            return cached
        }

        let download: ArtifactFileDownload
        do {
            download = try await downloader.download(from: request.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw ArtifactFileError.downloadFailed(
                url: request.url.absoluteString,
                reason: error.localizedDescription
            )
        }
        let temporaryURL = download.temporaryFileURL

        if let statusCode = download.statusCode,
           !(200..<300).contains(statusCode) {
            try removeTemporaryDownload(at: temporaryURL)
            throw ArtifactFileError.httpFailure(
                url: request.url.absoluteString,
                statusCode: statusCode
            )
        }

        if download.expectedContentLength > request.policy.maximumRemoteByteCount {
            try removeTemporaryDownload(at: temporaryURL)
            throw ArtifactFileError.remoteFileTooLarge(
                url: request.url.absoluteString,
                byteCount: download.expectedContentLength,
                limit: request.policy.maximumRemoteByteCount
            )
        }

        let downloadedByteCount = try regularFileByteCount(at: temporaryURL)
        guard downloadedByteCount <= request.policy.maximumRemoteByteCount else {
            try removeTemporaryDownload(at: temporaryURL)
            throw ArtifactFileError.remoteFileTooLarge(
                url: request.url.absoluteString,
                byteCount: downloadedByteCount,
                limit: request.policy.maximumRemoteByteCount
            )
        }

        let destination = try cachedDestination(
            for: request.url,
            declaredType: request.declaredType,
            responseMediaType: download.mediaType
        )
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw ArtifactFileError.cacheWriteFailed(
                path: destination.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }

        let cached = CachedRemoteFile(
            localFileURL: destination,
            responseMediaType: download.mediaType
        )
        cachedRemoteFiles[request.url] = cached
        return cached
    }

    private func resolvedFile(
        request: ArtifactFileRequest,
        localFileURL: URL,
        byteCount: Int64,
        responseMediaType: String?,
        isRemote: Bool
    ) throws -> ResolvedArtifactFile {
        let type = try typeDetector.detectType(
            for: ArtifactFileTypeDetectionRequest(
                sourceURL: request.url,
                localFileURL: localFileURL,
                declaredType: request.declaredType,
                responseMediaType: responseMediaType
            )
        )
        return ResolvedArtifactFile(
            sourceURL: request.url,
            localFileURL: localFileURL,
            type: type,
            byteCount: byteCount,
            responseMediaType: responseMediaType,
            isRemote: isRemote
        )
    }

    private func regularFileByteCount(at url: URL) throws -> Int64 {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ArtifactFileError.fileNotFound(url.path(percentEncoded: false))
        }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw ArtifactFileError.metadataUnavailable(
                path: url.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }
        guard values.isRegularFile == true else {
            throw ArtifactFileError.notRegularFile(url.path(percentEncoded: false))
        }
        guard let fileSize = values.fileSize else {
            throw ArtifactFileError.metadataUnavailable(
                path: url.path(percentEncoded: false),
                reason: "File size is unavailable."
            )
        }
        return Int64(fileSize)
    }

    private func cachedDestination(
        for sourceURL: URL,
        declaredType: ArtifactType? = nil,
        responseMediaType: String? = nil
    ) throws -> URL {
        let directory = try resolvedCacheDirectory()
        let pathExtension = preferredPathExtension(
            for: sourceURL,
            declaredType: declaredType,
            responseMediaType: responseMediaType
        )
        let filename = pathExtension.isEmpty
            ? UUID().uuidString
            : "\(UUID().uuidString).\(pathExtension)"
        return directory.appending(path: filename)
    }

    private func preferredPathExtension(
        for sourceURL: URL,
        declaredType: ArtifactType?,
        responseMediaType: String?
    ) -> String {
        if let declaredType,
           let declaredExtension = UTType(mimeType: declaredType.rawValue)?
               .preferredFilenameExtension {
            return declaredExtension
        }
        if !sourceURL.pathExtension.isEmpty {
            return sourceURL.pathExtension
        }
        guard let responseMediaType else { return "" }
        let normalizedMediaType = responseMediaType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedMediaType else { return "" }
        return UTType(mimeType: normalizedMediaType)?.preferredFilenameExtension ?? ""
    }

    private func resolvedCacheDirectory() throws -> URL {
        if let cacheDirectory {
            return cacheDirectory
        }
        let cacheName = "swift-artifact-files-\(ProcessInfo.processInfo.processIdentifier)"
            + "-\(cacheNamespace.uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: cacheName,
                directoryHint: .isDirectory
            )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ArtifactFileError.cacheWriteFailed(
                path: directory.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }
        cacheDirectory = directory
        return directory
    }

    private func removeTemporaryDownload(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ArtifactFileError.cacheWriteFailed(
                path: url.path(percentEncoded: false),
                reason: "Failed to remove rejected download: "
                    + error.localizedDescription
            )
        }
    }
}
