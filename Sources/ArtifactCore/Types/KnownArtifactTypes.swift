import Foundation

extension ArtifactType {

    // MARK: - Tier 1: Claude-compatible

    public static let html: ArtifactType = "text/html"
    public static let react: ArtifactType = "application/vnd.ant.react"
    public static let svg: ArtifactType = "image/svg+xml"
    public static let mermaid: ArtifactType = "application/vnd.ant.mermaid"
    public static let markdown: ArtifactType = "text/markdown"
    public static let code: ArtifactType = "application/vnd.ant.code"

    // MARK: - Tier 2: high-frequency agent outputs

    public static let json: ArtifactType = "application/json"
    public static let csv: ArtifactType = "text/csv"
    public static let vegaLite: ArtifactType = "application/vnd.vegalite.v5+json"
    public static let gltf: ArtifactType = "model/gltf+json"
    public static let glb: ArtifactType = "model/gltf-binary"
    public static let usdz: ArtifactType = "model/vnd.usdz+zip"
    public static let geoJSON: ArtifactType = "application/geo+json"
    public static let latex: ArtifactType = "application/x-latex"
}
