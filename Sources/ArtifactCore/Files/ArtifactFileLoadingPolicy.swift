import Foundation

/// Resource and transport limits applied when an artifact file is opened.
public struct ArtifactFileLoadingPolicy: Sendable, Hashable {
    /// Secure defaults suitable for interactive artifact display.
    public static let standard = ArtifactFileLoadingPolicy()

    public let maximumRemoteByteCount: Int64
    public let maximumTextByteCount: Int64
    public let allowsInsecureHTTP: Bool

    public init(
        maximumRemoteByteCount: Int64 = 128 * 1_024 * 1_024,
        maximumTextByteCount: Int64 = 8 * 1_024 * 1_024,
        allowsInsecureHTTP: Bool = false
    ) {
        self.maximumRemoteByteCount = maximumRemoteByteCount
        self.maximumTextByteCount = maximumTextByteCount
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }
}
