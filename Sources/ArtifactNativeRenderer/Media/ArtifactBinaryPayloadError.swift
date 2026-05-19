import Foundation

enum ArtifactBinaryPayloadError: Error, Equatable, LocalizedError {
    case empty
    case invalidDataURL
    case invalidBase64
    case unsupportedPayload

    var errorDescription: String? {
        switch self {
        case .empty:
            "The artifact payload is empty."
        case .invalidDataURL:
            "The artifact payload is not a valid data URL."
        case .invalidBase64:
            "The artifact payload is not valid base64 data."
        case .unsupportedPayload:
            "The artifact payload must be a URL, file path, data URL, or base64 data."
        }
    }
}
