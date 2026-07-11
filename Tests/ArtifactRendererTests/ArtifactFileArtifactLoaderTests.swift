import ArtifactCore
import ArtifactRenderer
import Foundation
import SwiftUI
import Testing
@testable import ArtifactView

@Suite("Artifact file artifact loading")
struct ArtifactFileArtifactLoaderTests {
    private enum StubError: Error {
        case unexpectedTextRead
    }

    private struct StubResolver: ArtifactFileResolving, Sendable {
        let file: ResolvedArtifactFile
        let text: String
        let allowsTextRead: Bool

        func resolve(_ request: ArtifactFileRequest) async throws -> ResolvedArtifactFile {
            file
        }

        func textContents(
            of file: ResolvedArtifactFile,
            maximumByteCount: Int64
        ) async throws -> String {
            guard allowsTextRead else {
                throw StubError.unexpectedTextRead
            }
            return text
        }
    }

    private struct LocalFileRenderer: ArtifactRenderable, Sendable {
        static let artifactType = ArtifactType("application/vnd.example.binary")
        static let fileInput: ArtifactFileInput = .localFileURL

        func body(artifact: AnyArtifact, payload: String) -> some View {
            EmptyView()
        }
    }

    @MainActor
    @Test func canvasConvenienceInitializersExposeMessageAndURLInputs() {
        let textCanvas = ArtifactCanvas(text: "plain text")
        let urlCanvas = ArtifactCanvas(url: URL(filePath: "/tmp/artifact.json"))

        #expect(textCanvas.message.segments == [.text("plain text")])
        #expect(urlCanvas.message == .empty)
    }

    @Test func materializesTextFileAsCompleteArtifact() async throws {
        let sourceURL = try #require(URL(string: "https://example.com/results/report.json"))
        let localURL = URL(filePath: "/tmp/swift-artifact-report.json")
        let file = ResolvedArtifactFile(
            sourceURL: sourceURL,
            localFileURL: localURL,
            type: .json,
            byteCount: 17,
            responseMediaType: "application/json",
            isRemote: true
        )
        let request = ArtifactFileRequest(url: sourceURL, title: "  Simulation report  ")
        let loader = ArtifactFileArtifactLoader(
            resolver: StubResolver(file: file, text: #"{"status":"ok"}"#, allowsTextRead: true)
        )

        let artifact = try await loader.load(request, renderers: [:])

        #expect(artifact.type == .json)
        #expect(artifact.title == "Simulation report")
        #expect(artifact.payload == #"{"status":"ok"}"#)
        #expect(artifact.isComplete)
        #expect(artifact.attributes["sourceURL"] == sourceURL.absoluteString)
        #expect(artifact.attributes["localFileURL"] == localURL.absoluteString)
        #expect(artifact.attributes["filename"] == "report.json")
        #expect(artifact.attributes["fileExtension"] == "json")
        #expect(artifact.attributes["byteCount"] == "17")
        #expect(artifact.attributes["isRemote"] == "true")
        #expect(artifact.attributes["responseMediaType"] == "application/json")
    }

    @Test func rendererCanRequireResolvedLocalFileURL() async throws {
        let sourceURL = try #require(URL(string: "https://example.com/output"))
        let localURL = URL(filePath: "/tmp/swift-artifact-output")
        let file = ResolvedArtifactFile(
            sourceURL: sourceURL,
            localFileURL: localURL,
            type: LocalFileRenderer.artifactType,
            byteCount: 42,
            isRemote: true
        )
        let loader = ArtifactFileArtifactLoader(
            resolver: StubResolver(file: file, text: "", allowsTextRead: false)
        )
        let renderers = [
            LocalFileRenderer.artifactType: AnyArtifactRenderer(LocalFileRenderer()),
        ]

        let artifact = try await loader.load(
            ArtifactFileRequest(url: sourceURL),
            renderers: renderers
        )

        #expect(artifact.title == "output")
        #expect(artifact.payload == localURL.absoluteString)
        #expect(artifact.attributes["filename"] == "output")
        #expect(artifact.attributes["fileExtension"] == nil)
    }
}
