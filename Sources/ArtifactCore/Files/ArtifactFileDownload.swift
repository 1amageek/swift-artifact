import Foundation

/// A downloaded file and the response metadata needed for validation and type detection.
public struct ArtifactFileDownload: Sendable, Hashable {
    public let temporaryFileURL: URL
    public let statusCode: Int?
    public let expectedContentLength: Int64
    public let mediaType: String?

    public init(
        temporaryFileURL: URL,
        statusCode: Int? = nil,
        expectedContentLength: Int64 = NSURLSessionTransferSizeUnknown,
        mediaType: String? = nil
    ) {
        self.temporaryFileURL = temporaryFileURL
        self.statusCode = statusCode
        self.expectedContentLength = expectedContentLength
        self.mediaType = mediaType
    }
}
