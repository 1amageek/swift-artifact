import Foundation

/// Synchronous parser for completed LLM output.
public enum ArtifactParser {

    /// Parse a complete LLM response containing zero or more `<artifact>` tags.
    ///
    /// - Throws: `ArtifactError.unterminatedArtifact` if the input ends inside
    ///   an artifact body without a closing tag.
    public static func parse(_ source: String) throws -> ArtifactMessage {
        var core = ArtifactStreamParserCore()
        _ = core.feed(source)
        return try core.finalize()
    }

    /// Parse a single artifact and discard surrounding prose.
    ///
    /// - Throws: `ArtifactError.noArtifactFound` if no `<artifact>` tag is
    ///   present in `source`, or any error thrown by `parse(_:)`.
    public static func parseOne(_ source: String) throws -> AnyArtifact {
        let message = try parse(source)
        for segment in message.segments {
            if case .artifact(let artifact) = segment {
                return artifact
            }
        }
        throw ArtifactError.noArtifactFound
    }
}
