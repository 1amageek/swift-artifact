import Foundation

/// Typed failures produced while validating, downloading, caching, or decoding artifact files.
public enum ArtifactFileError: Error, Equatable, Sendable, LocalizedError {
    case invalidLimit(name: String, value: Int64)
    case unsupportedURLScheme(String)
    case fileNotFound(String)
    case notRegularFile(String)
    case metadataUnavailable(path: String, reason: String)
    case downloadFailed(url: String, reason: String)
    case httpFailure(url: String, statusCode: Int)
    case remoteFileTooLarge(url: String, byteCount: Int64, limit: Int64)
    case textFileTooLarge(path: String, byteCount: Int64, limit: Int64)
    case invalidUTF8(String)
    case cacheWriteFailed(path: String, reason: String)
    case readFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidLimit(name, value):
            return "Artifact file limit '\(name)' must be positive, got \(value)."
        case let .unsupportedURLScheme(scheme):
            return "Artifact URL scheme '\(scheme)' is not supported."
        case let .fileNotFound(path):
            return "Artifact file does not exist at \(path)."
        case let .notRegularFile(path):
            return "Artifact URL does not reference a regular file: \(path)."
        case let .metadataUnavailable(path, reason):
            return "Artifact metadata is unavailable for \(path): \(reason)"
        case let .downloadFailed(url, reason):
            return "Artifact download failed for \(url): \(reason)"
        case let .httpFailure(url, statusCode):
            return "Artifact download returned HTTP \(statusCode) for \(url)."
        case let .remoteFileTooLarge(url, byteCount, limit):
            return "Remote artifact at \(url) is \(byteCount) bytes, exceeding the \(limit)-byte limit."
        case let .textFileTooLarge(path, byteCount, limit):
            return "Text artifact at \(path) is \(byteCount) bytes, exceeding the \(limit)-byte limit."
        case let .invalidUTF8(path):
            return "Text artifact is not valid UTF-8: \(path)."
        case let .cacheWriteFailed(path, reason):
            return "Artifact cache write failed at \(path): \(reason)"
        case let .readFailed(path, reason):
            return "Artifact file could not be read at \(path): \(reason)"
        }
    }
}
