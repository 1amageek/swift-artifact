import ArtifactCore
import UniformTypeIdentifiers
/// The payload representation a renderer expects for URL-backed artifacts.
public enum ArtifactFileInput: Sendable, Equatable, Hashable {
    /// UTF-8 contents decoded by the file resolver.
    case text
    /// A resolved local `file://` URL string.
    case localFileURL

    public static func inferred(for type: ArtifactType) -> ArtifactFileInput {
        let mediaType = type.rawValue.lowercased()
        if mediaType.hasPrefix("text/")
            || mediaType.hasSuffix("+json")
            || mediaType.hasSuffix("+csv")
            || mediaType.hasSuffix("+xml")
            || textualApplicationTypes.contains(mediaType)
            || UTType(mimeType: mediaType)?.conforms(to: .text) == true {
            return .text
        }
        return .localFileURL
    }

    private static let textualApplicationTypes: Set<String> = [
        ArtifactType.react.rawValue,
        ArtifactType.mermaid.rawValue,
        ArtifactType.code.rawValue,
        ArtifactType.json.rawValue,
        ArtifactType.latex.rawValue,
        ArtifactType.trig.rawValue,
        ArtifactType.nQuads.rawValue,
        "application/javascript",
        "application/x-javascript",
        "application/xml",
        "application/yaml",
        "application/x-yaml",
        "application/toml",
        "application/x-ndjson",
    ]
}
