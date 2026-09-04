import Testing
import Foundation
@testable import ArtifactCore

@Suite("ArtifactType")
struct ArtifactTypeTests {

    @Test func genericFileFallbackConstants() {
        #expect(ArtifactType.plainText.rawValue == "text/plain")
        #expect(ArtifactType.octetStream.rawValue == "application/octet-stream")
    }

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
        #expect(ArtifactType.swiftCharts.rawValue == "application/vnd.swiftartifact.chart+json")
        #expect(ArtifactType.gltf.rawValue == "model/gltf+json")
        #expect(ArtifactType.glb.rawValue == "model/gltf-binary")
        #expect(ArtifactType.usdz.rawValue == "model/vnd.usdz+zip")
        #expect(ArtifactType.geoJSON.rawValue == "application/geo+json")
        #expect(ArtifactType.latex.rawValue == "application/x-latex")
    }

    @Test func documentAndRasterImageConstants() {
        #expect(ArtifactType.pdf.rawValue == "application/pdf")
        #expect(ArtifactType.png.rawValue == "image/png")
        #expect(ArtifactType.jpeg.rawValue == "image/jpeg")
        #expect(ArtifactType.jpg == .jpeg)
        #expect(ArtifactType.webp.rawValue == "image/webp")
        #expect(ArtifactType.gif.rawValue == "image/gif")
        #expect(ArtifactType.tiff.rawValue == "image/tiff")
        #expect(ArtifactType.heic.rawValue == "image/heic")
        #expect(ArtifactType.bmp.rawValue == "image/bmp")
    }

    @Test func codable() throws {
        let t = ArtifactType("application/vnd.user.custom")
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(ArtifactType.self, from: data)
        #expect(decoded == t)
    }
}
