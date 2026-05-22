import SwiftUI
import ArtifactCore
import KnowledgeGraph
import KnowledgeGraphParsers

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
        case success(KnowledgeGraph, GraphPresentation?)
        case failure(Error)
    }

    private var parseKey: String {
        // The task id mixes the completion flag in so that the final
        // (complete) parse re-runs after streaming concludes, even when the
        // payload byte sequence happens to match a previous partial snapshot.
        "\(artifact.isComplete ? "F" : "P")\u{0001}\(payload)"
    }

    private var currentGraph: KnowledgeGraph? {
        if case .success(let graph, _) = parseResult { return graph }
        return nil
    }

    var body: some View {
        Group {
            switch parseResult {
            case .pending:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .success(let graph, let presentation):
                KnowledgeGraphView(
                    graph: graph,
                    groupingStrategy: groupingStrategy(for: payload, presentation: presentation),
                    presentation: presentation
                )
            case .failure(let error):
                KnowledgeGraphErrorView(error: error, source: payload)
            }
        }
        .artifactViewport(minHeight: 320)
        .task(id: parseKey) {
            let captured = payload
            let captureFormat = format
            let isComplete = artifact.isComplete
            let scope = artifact.id.rawValue
            let artifactTitle = artifact.title
            let baseIRI = artifact.attributes["base"]
            let previousGraph = currentGraph
            let result: ParseResult = await Task.detached(priority: .userInitiated) {
                if isComplete {
                    do {
                        let graph = try captureFormat.parse(captured, scope: scope, baseIRI: baseIRI)
                        let presentation = captureFormat == .jsonLD
                            ? try JSONLDGraphPresentationExtractor.presentation(
                                from: captured,
                                id: "presentation:\(scope)",
                                title: artifactTitle
                            )
                            : nil
                        return .success(graph, presentation)
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
                    return .success(previousGraph, nil)
                }
                return .success(outcome.graph, nil)
            }.value
            if Task.isCancelled { return }
            parseResult = result
        }
    }

    private func groupingStrategy(for payload: String, presentation: GraphPresentation?) -> GroupingStrategy {
        guard format == .jsonLD else { return .namedGraphs() }
        if let groups = presentation?.groups, !groups.isEmpty {
            return .explicit(groups: explicitGroups(from: groups))
        }
        return JSONLDViewGroupExtractor.groupingStrategy(from: payload) ?? .namedGraphs()
    }

    private func explicitGroups(from groups: [GraphPresentationGroup]) -> [GroupingStrategy.ExplicitGroup] {
        groups.flatMap { group -> [GroupingStrategy.ExplicitGroup] in
            let members = group.members.compactMap { reference -> NodeIdentifier? in
                guard case .node(let node) = reference else { return nil }
                return node
            }
            return [
                GroupingStrategy.ExplicitGroup(
                    id: group.id,
                    label: group.title,
                    memberNodeIDs: members
                )
            ] + explicitGroups(from: group.children)
        }
    }
}
