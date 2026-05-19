import Foundation
import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

#if canImport(PDFKit)
import PDFKit
#endif

public struct PDFRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .pdf
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        let payload = ArtifactBinaryPayloadResolver.trimmedPayload(artifact.payload)
        guard artifact.isComplete, payload.isEmpty == false else {
            return .preRenderable(
                PreRenderableProgress(
                    receivedCharacters: payload.count,
                    hint: "waiting for complete PDF payload"
                )
            )
        }
        return .renderable(payload)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        PDFRendererBody(payload: payload, title: artifact.title)
    }
}

#if canImport(PDFKit)
private struct PDFRendererBody: View {
    let payload: String
    let title: String

    @State private var document: PDFDocument?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let document {
                PDFDocumentView(document: document)
            } else if let errorMessage {
                ContentUnavailableView(
                    title.isEmpty ? "PDF document" : title,
                    systemImage: "doc.richtext",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView()
            }
        }
        .artifactViewport(minHeight: 320)
        .task(id: payload) {
            await loadDocument()
        }
    }

    @MainActor
    private func loadDocument() async {
        document = nil
        errorMessage = nil
        do {
            let data: Data
            if let url = ArtifactBinaryPayloadResolver.remoteURL(from: payload) {
                let (remoteData, _) = try await URLSession.shared.data(from: url)
                data = remoteData
            } else {
                data = try ArtifactBinaryPayloadResolver.data(from: payload)
            }
            guard let loaded = PDFDocument(data: data) else {
                errorMessage = "The payload is not a valid PDF document."
                return
            }
            document = loaded
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if os(macOS)
private struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        view.document = document
    }
}
#else
private struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.document = document
    }
}
#endif

#if DEBUG
#Preview("Card — PDF data URL") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("pdf1"),
            type: .pdf,
            title: "Preview.pdf",
            payload: MediaRendererDebugPreviewSamples.pdfDataURL,
            isComplete: true
        ),
        renderer: PDFRenderer()
    )
    .frame(width: 420, height: 360)
}

#Preview("Bare — invalid PDF payload") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("pdf2"),
            type: .pdf,
            title: "Broken.pdf",
            payload: MediaRendererDebugPreviewSamples.invalidPayload,
            isComplete: true
        )
    )
    .artifactRenderer(PDFRenderer())
    .frame(width: 420, height: 280)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("pdf3"),
        type: .pdf,
        title: "Streaming PDF",
        fullPayload: MediaRendererDebugPreviewSamples.pdfDataURL,
        chunkSize: 36,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(PDFRenderer())
    .frame(width: 420, height: 320)
}
#endif
#else
private struct PDFRendererBody: View {
    let payload: String
    let title: String

    var body: some View {
        ContentUnavailableView(
            title.isEmpty ? "PDF document" : title,
            systemImage: "doc.richtext",
            description: Text("PDF rendering is not available on this platform.")
        )
        .artifactViewport(minHeight: 240)
    }
}
#endif
