import Foundation

/// A unique identifier for an artifact instance within a message.
///
/// Kept distinct from `ArtifactType` so that "kind" and "instance" are not conflated.
public struct ArtifactIdentifier: RawRepresentable, Hashable, Sendable, Codable,
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
