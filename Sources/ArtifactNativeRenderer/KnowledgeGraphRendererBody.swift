import SwiftUI
import ArtifactCore
import KnowledgeGraph

/// Shared `body` host for every RDF artifact renderer.
///
/// Each format-specific renderer (`TurtleRenderer`, `JSONLDRenderer`, …) is a
/// thin wrapper that wires the right `KnowledgeGraphFormat` to this view. The
/// view owns the parse + error state so the parse runs on a background task
/// and the SwiftUI tree only re-evaluates when `.parseResult` flips.
///
/// Parsing happens inside `.task(id: payload)` rather than synchronously in
/// `body` because the W3C-compliant parsers walk the entire input on each
/// snapshot — too costly for the main actor at streaming speeds.
struct KnowledgeGraphRendererBody: View {
    let artifact: AnyArtifact
    let payload: String
    let format: KnowledgeGraphFormat

    @State private var parseResult: ParseResult = .pending

    private enum ParseResult: Sendable {
        case pending
        case success(KnowledgeGraph)
        case failure(Error)
    }

    var body: some View {
        Group {
            switch parseResult {
            case .pending:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 360)
            case .success(let graph):
                KnowledgeGraphView(graph: graph)
            case .failure(let error):
                KnowledgeGraphErrorView(error: error, source: payload)
            }
        }
        .task(id: payload) {
            let captured = payload
            let captureFormat = format
            let scope = artifact.id.rawValue
            let baseIRI = artifact.attributes["base"]
            let result: ParseResult = await Task.detached(priority: .userInitiated) {
                do {
                    let graph = try captureFormat.parse(captured, scope: scope, baseIRI: baseIRI)
                    return .success(graph)
                } catch {
                    return .failure(error)
                }
            }.value
            if Task.isCancelled { return }
            parseResult = result
        }
    }
}
