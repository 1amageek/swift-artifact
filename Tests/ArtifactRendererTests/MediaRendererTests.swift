import Foundation
import CoreGraphics
import Testing
import ArtifactCore
import ArtifactRenderer
@testable import ArtifactNativeRenderer

#if canImport(ImageIO)
import ImageIO
#endif

@Suite("Media renderers")
struct MediaRendererTests {

    @Test func rendererTypesMatchMediaMIMEs() {
        #expect(PDFRenderer.artifactType == .pdf)
        #expect(PNGRenderer.artifactType == .png)
        #expect(JPEGRenderer.artifactType == .jpeg)
        #expect(WebPRenderer.artifactType == .webp)
        #expect(GIFRenderer.artifactType == .gif)
        #expect(TIFFRenderer.artifactType == .tiff)
        #expect(HEICRenderer.artifactType == .heic)
        #expect(BMPRenderer.artifactType == .bmp)
    }

    @Test func mediaRenderersConsumeResolvedFileURLs() {
        #expect(PDFRenderer.fileInput == .localFileURL)
        #expect(PNGRenderer.fileInput == .localFileURL)
        #expect(JPEGRenderer.fileInput == .localFileURL)
        #expect(WebPRenderer.fileInput == .localFileURL)
        #expect(GIFRenderer.fileInput == .localFileURL)
        #expect(TIFFRenderer.fileInput == .localFileURL)
        #expect(HEICRenderer.fileInput == .localFileURL)
        #expect(BMPRenderer.fileInput == .localFileURL)
    }

    @Test func completePayloadIsRenderable() {
        let artifact = AnyArtifact(
            id: ArtifactIdentifier("image"),
            type: .jpeg,
            payload: "https://example.com/photo.jpg",
            isComplete: true
        )
        #expect(JPEGRenderer.refine(artifact) == .renderable("https://example.com/photo.jpg"))
    }

    @Test func incompleteImagePayloadWaitsForCompletion() {
        let artifact = AnyArtifact(
            id: ArtifactIdentifier("image"),
            type: .png,
            payload: "https://example.com/photo",
            isComplete: false
        )
        if case .preRenderable = PNGRenderer.refine(artifact) {
            // OK
        } else {
            Issue.record("Expected image renderer to wait for a complete payload")
        }
    }

    @Test func dataURLPayloadDecodes() throws {
        let data = try ArtifactBinaryPayloadResolver.data(
            from: "data:text/plain;base64,SGVsbG8="
        )
        #expect(String(data: data, encoding: .utf8) == "Hello")
    }

    @Test func binaryDataLoaderReadsResolvedLocalFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "swift-artifact-media-\(UUID().uuidString)")
        defer {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                Issue.record("Failed to remove temporary media file: \(error)")
            }
        }
        try Data("artifact".utf8).write(to: fileURL)

        let data = try await ArtifactBinaryDataLoader.shared.data(
            from: fileURL.absoluteString
        )

        #expect(String(data: data, encoding: .utf8) == "artifact")
    }

    @Test func previewPayloadsDecodeToBytes() throws {
        let payloads = [
            MediaRendererTestFixtures.pngDataURL,
            MediaRendererTestFixtures.jpegDataURL,
            MediaRendererTestFixtures.webpDataURL,
            MediaRendererTestFixtures.gifDataURL,
            MediaRendererTestFixtures.tiffDataURL,
            MediaRendererTestFixtures.heicDataURL,
            MediaRendererTestFixtures.bmpDataURL,
            MediaRendererTestFixtures.pdfDataURL,
        ]
        for payload in payloads {
            let data = try ArtifactBinaryPayloadResolver.data(from: payload)
            #expect(data.isEmpty == false)
        }
    }

    @Test func rasterPreviewPayloadsDecodeAsImages() throws {
        #if canImport(ImageIO)
        let payloads = [
            MediaRendererTestFixtures.pngDataURL,
            MediaRendererTestFixtures.jpegDataURL,
            MediaRendererTestFixtures.webpDataURL,
            MediaRendererTestFixtures.gifDataURL,
            MediaRendererTestFixtures.tiffDataURL,
            MediaRendererTestFixtures.heicDataURL,
            MediaRendererTestFixtures.bmpDataURL,
        ]
        for payload in payloads {
            let data = try ArtifactBinaryPayloadResolver.data(from: payload)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
            let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
            #expect(width > 0)
            #expect(height > 0)
        }
        #endif
    }

    @Test func plainBase64PayloadDecodes() throws {
        let data = try ArtifactBinaryPayloadResolver.data(from: "SGVsbG8=")
        #expect(String(data: data, encoding: .utf8) == "Hello")
    }

    @Test func remoteURLIsDetected() throws {
        let url = try #require(ArtifactBinaryPayloadResolver.remoteURL(
            from: "https://example.com/file.pdf"
        ))
        #expect(url.scheme == "https")
        #expect(url.lastPathComponent == "file.pdf")
    }

    @Test func rasterImageLayoutUsesSourceAspectRatio() {
        #expect(RasterImageLayout.aspectRatio(for: CGSize(width: 320, height: 160)) == 2)
        #expect(RasterImageLayout.aspectRatio(for: CGSize(width: 120, height: 240)) == 0.5)
        #expect(RasterImageLayout.aspectRatio(for: .zero) == 1)
    }

    @Test func rasterImageLayoutFitsContentWidthToSourceAspectRatio() {
        #expect(RasterImageLayout.contentSize(forWidth: 320, aspectRatio: 2) == CGSize(width: 320, height: 160))
        #expect(RasterImageLayout.contentSize(forWidth: 240, aspectRatio: 0.5) == CGSize(width: 240, height: 480))
        #expect(RasterImageLayout.contentSize(forWidth: 0, aspectRatio: 1) == .zero)
        #expect(RasterImageLayout.contentSize(forWidth: 120, aspectRatio: 0) == .zero)
    }
}
