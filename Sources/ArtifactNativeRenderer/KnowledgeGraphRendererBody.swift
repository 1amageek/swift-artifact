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

    private var parseKey: String {
        // The task id mixes the completion flag in so that the final
        // (complete) parse re-runs after streaming concludes, even when the
        // payload byte sequence happens to match a previous partial snapshot.
        "\(artifact.isComplete ? "F" : "P")\u{0001}\(payload)"
    }

    private var currentGraph: KnowledgeGraph? {
        if case .success(let graph) = parseResult { return graph }
        return nil
    }

    var body: some View {
        Group {
            switch parseResult {
            case .pending:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .success(let graph):
                KnowledgeGraphView(graph: graph)
            case .failure(let error):
                KnowledgeGraphErrorView(error: error, source: payload)
            }
        }
        .task(id: parseKey) {
            let captured = payload
            let captureFormat = format
            let isComplete = artifact.isComplete
            let scope = artifact.id.rawValue
            let baseIRI = artifact.attributes["base"]
            let previousGraph = currentGraph
            let result: ParseResult = await Task.detached(priority: .userInitiated) {
                if isComplete {
                    do {
                        let graph = try captureFormat.parse(captured, scope: scope, baseIRI: baseIRI)
                        return .success(graph)
                    } catch {
                        return .failure(error)
                    }
                }
                let outcome = captureFormat.parsePartial(captured, scope: scope, baseIRI: baseIRI)
                if outcome.graph.nodes.isEmpty, let previousGraph {
                    // Underlying parser rejected the current prefix outright.
                    // Hold the previous valid snapshot so the diagram stays
                    // stable across snapshots — the next chunk usually
                    // resolves the issue.
                    return .success(previousGraph)
                }
                return .success(outcome.graph)
            }.value
            if Task.isCancelled { return }
            parseResult = result
        }
    }
}
