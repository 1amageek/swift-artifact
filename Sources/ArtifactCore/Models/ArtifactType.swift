import Foundation

/// An identifier in MIME-type space describing the payload format of an artifact.
///
/// `ArtifactType` is a `RawRepresentable` struct rather than an enum so that the
/// value space stays open — `Notification.Name` / `SwiftUI.Font.Design` follow the
/// same shape. Users can introduce private `ArtifactType` constants in extensions
/// without having to fork the library.
public struct ArtifactType: RawRepresentable, Hashable, Sendable, Codable,
                            ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}
