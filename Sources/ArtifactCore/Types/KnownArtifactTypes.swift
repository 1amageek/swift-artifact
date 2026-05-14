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

    // MARK: - Knowledge graph (RDF)

    /// W3C RDF 1.1 Turtle. See <https://www.w3.org/TR/turtle/>.
    public static let turtle: ArtifactType = "text/turtle"
    /// W3C RDF 1.1 TriG (named-graph extension of Turtle).
    /// See <https://www.w3.org/TR/trig/>.
    public static let trig: ArtifactType = "application/trig"
    /// W3C RDF 1.1 N-Quads. See <https://www.w3.org/TR/n-quads/>.
    public static let nQuads: ArtifactType = "application/n-quads"
    /// W3C RDF 1.1 XML Syntax. See <https://www.w3.org/TR/rdf-syntax-grammar/>.
    public static let rdfXML: ArtifactType = "application/rdf+xml"
    /// W3C JSON-LD 1.1. Distinct from `.json` because the toRDF interpretation
    /// requires the JSON-LD context machinery.
    /// See <https://www.w3.org/TR/json-ld11/>.
    public static let jsonLD: ArtifactType = "application/ld+json"
}
