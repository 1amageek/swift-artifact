import ArtifactCore

extension Dictionary where Key == ArtifactType, Value == AnyArtifactRenderer {
    /// Resolves an exact renderer or a compatible structured-suffix fallback.
    public func artifactRenderer(for type: ArtifactType) -> AnyArtifactRenderer? {
        if let exact = self[type] {
            return exact
        }

        let mediaType = type.rawValue.lowercased()
        if mediaType.hasSuffix("+json") {
            return self[.json]
        }
        if mediaType.hasSuffix("+csv") {
            return self[.csv]
        }
        return nil
    }
}
