import Testing
import SwiftUI
import ArtifactCore
@testable import ArtifactRenderer

@Suite("RefinedPayload")
struct RenderingStateTests {

    struct DefaultRenderer: ArtifactRenderable {
        static let artifactType: ArtifactType = .markdown
        func body(artifact: AnyArtifact, payload: String) -> some View { EmptyView() }
    }

    struct FileURLRenderer: ArtifactRenderable, Sendable {
        static let artifactType = ArtifactType("application/vnd.example.binary")
        static let fileInput: ArtifactFileInput = .localFileURL
        func body(artifact: AnyArtifact, payload: String) -> some View { EmptyView() }
    }

    struct JSONRendererStub: ArtifactRenderable, Sendable {
        static let artifactType: ArtifactType = .json
        func body(artifact: AnyArtifact, payload: String) -> some View { EmptyView() }
    }

    struct ExactJSONRendererStub: ArtifactRenderable, Sendable {
        static let artifactType = ArtifactType("application/vnd.example+json")
        static let fileInput: ArtifactFileInput = .localFileURL
        func body(artifact: AnyArtifact, payload: String) -> some View { EmptyView() }
    }

    @Test func defaultProtocolBehavior() {
        #expect(DefaultRenderer.fileInput == .text)

        let empty = AnyArtifact(id: .init("a"), type: .markdown)
        if case let .preRenderable(progress) = DefaultRenderer.refine(empty) {
            #expect(progress.receivedCharacters == 0)
        } else {
            Issue.record("Expected .preRenderable for empty artifact")
        }

        let streaming = AnyArtifact(id: .init("a"), type: .markdown, payload: "hi", isComplete: false)
        if case let .preRenderable(progress) = DefaultRenderer.refine(streaming) {
            #expect(progress.receivedCharacters == 2)
        } else {
            Issue.record("Expected .preRenderable for streaming artifact (default refiner)")
        }

        let complete = AnyArtifact(id: .init("a"), type: .markdown, payload: "hi", isComplete: true)
        #expect(DefaultRenderer.refine(complete) == .renderable("hi"))
    }

    struct PartialAwareRenderer: ArtifactRenderable {
        static let artifactType: ArtifactType = .markdown
        func body(artifact: AnyArtifact, payload: String) -> some View { EmptyView() }

        static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
            if artifact.payload.isEmpty {
                return .preRenderable(PreRenderableProgress(receivedCharacters: 0))
            }
            return .renderable(artifact.payload)
        }
    }

    @Test func customRendererCanOverrideToRenderable() {
        let streaming = AnyArtifact(id: .init("a"), type: .markdown, payload: "x", isComplete: false)
        #expect(PartialAwareRenderer.refine(streaming) == .renderable("x"))
    }

    @Test func typeErasurePreservesFileInputContract() {
        let renderer = AnyArtifactRenderer(FileURLRenderer())

        #expect(renderer.fileInput == .localFileURL)
    }

    @Test func registryFallsBackForStructuredJSONTypes() {
        let jsonRenderer = AnyArtifactRenderer(JSONRendererStub())
        let registry: [ArtifactType: AnyArtifactRenderer] = [.json: jsonRenderer]
        let customJSONType = ArtifactType("application/vnd.example+json")

        #expect(registry.artifactRenderer(for: customJSONType)?.artifactType == .json)
    }

    @Test func exactRegistrationTakesPriorityOverStructuredFallback() {
        let exactType = ExactJSONRendererStub.artifactType
        let registry: [ArtifactType: AnyArtifactRenderer] = [
            .json: AnyArtifactRenderer(JSONRendererStub()),
            exactType: AnyArtifactRenderer(ExactJSONRendererStub()),
        ]

        let resolved = registry.artifactRenderer(for: exactType)
        #expect(resolved?.artifactType == exactType)
        #expect(resolved?.fileInput == .localFileURL)
    }

    @Test func fileInputInferenceSeparatesTextAndBinaryMedia() {
        #expect(ArtifactFileInput.inferred(for: .markdown) == .text)
        #expect(ArtifactFileInput.inferred(for: .geoJSON) == .text)
        #expect(ArtifactFileInput.inferred(for: .png) == .localFileURL)
        #expect(ArtifactFileInput.inferred(for: .pdf) == .localFileURL)
        #expect(ArtifactFileInput.inferred(for: .octetStream) == .localFileURL)
        #expect(ArtifactFileInput.inferred(for: "application/zip") == .localFileURL)
        #expect(ArtifactFileInput.inferred(for: "application/javascript") == .text)
    }
}
