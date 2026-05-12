import Testing
import Foundation
@testable import ArtifactCore

@Suite("ArtifactType")
struct ArtifactTypeTests {

    @Test func stringLiteralInit() {
        let t: ArtifactType = "application/vnd.example"
        #expect(t.rawValue == "application/vnd.example")
        #expect(t.description == "application/vnd.example")
    }

    @Test func equality() {
        #expect(ArtifactType("text/markdown") == .markdown)
        #expect(ArtifactType.html != ArtifactType.svg)
    }

    @Test func tier1Constants() {
        #expect(ArtifactType.html.rawValue == "text/html")
        #expect(ArtifactType.react.rawValue == "application/vnd.ant.react")
        #expect(ArtifactType.svg.rawValue == "image/svg+xml")
        #expect(ArtifactType.mermaid.rawValue == "application/vnd.ant.mermaid")
        #expect(ArtifactType.markdown.rawValue == "text/markdown")
        #expect(ArtifactType.code.rawValue == "application/vnd.ant.code")
    }

    @Test func tier2Constants() {
        #expect(ArtifactType.json.rawValue == "application/json")
        #expect(ArtifactType.csv.rawValue == "text/csv")
        #expect(ArtifactType.vegaLite.rawValue == "application/vnd.vegalite.v5+json")
        #expect(ArtifactType.gltf.rawValue == "model/gltf+json")
        #expect(ArtifactType.glb.rawValue == "model/gltf-binary")
        #expect(ArtifactType.usdz.rawValue == "model/vnd.usdz+zip")
        #expect(ArtifactType.geoJSON.rawValue == "application/geo+json")
        #expect(ArtifactType.latex.rawValue == "application/x-latex")
    }

    @Test func codable() throws {
        let t = ArtifactType("application/vnd.user.custom")
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(ArtifactType.self, from: data)
        #expect(decoded == t)
    }
}
