import SwiftUI
import KnowledgeGraph

struct KnowledgeGraphCardStyle {
    var shape: GraphShape?
    var fill: Color?
    var stroke: Color?
    var strokeWidth: CGFloat?
    var strokeLine: GraphLineStyle?
    var text: Color?
    var opacity: Double?
}

struct KnowledgeGraphEdgeDrawingStyle {
    var stroke: Color?
    var strokeWidth: CGFloat?
    var strokeLine: GraphLineStyle?
    var sourceMarker: GraphMarker?
    var targetMarker: GraphMarker?
    var label: KnowledgeGraphEdgeLabelDrawingStyle?
    var opacity: Double?
}

struct KnowledgeGraphGroupDrawingStyle {
    var shape: GraphShape?
    var fill: Color?
    var stroke: Color?
    var headerFill: Color?
    var strokeWidth: CGFloat?
    var strokeLine: GraphLineStyle?
    var text: Color?
    var opacity: Double?
}

struct KnowledgeGraphCanvasDrawingStyle {
    var fill: Color?
    var opacity: Double?
}

struct KnowledgeGraphEdgeLabelDrawingStyle {
    var shape: GraphShape?
    var fill: Color?
    var stroke: Color?
    var strokeWidth: CGFloat?
    var strokeLine: GraphLineStyle?
    var text: Color?
    var textSize: CGFloat?
    var textWeight: Font.Weight?
    var opacity: Double?
}

struct KnowledgeGraphPresentationStyleResolver {
    private let graph: KnowledgeGraph
    private let presentation: GraphPresentation?
    private let nodesByID: [NodeIdentifier: Node]

    init(graph: KnowledgeGraph, presentation: GraphPresentation?) {
        self.graph = graph
        self.presentation = presentation
        self.nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
    }

    func cardStyle(for card: CompoundGraph.Card, theme: KnowledgeGraphVisualTheme) -> KnowledgeGraphCardStyle {
        let style = resolvedStyle { target in
            switch target {
            case .allNodes:
                return 0
            case .node(let id):
                return id == card.id.nodeID ? 3 : nil
            case .kind(let kind):
                return cardKind(card) == kind ? 1 : nil
            case .rdfType(let type):
                return nodesByID[card.id.nodeID]?.types.contains(type) == true ? 2 : nil
            case .canvas, .edge, .namedGraph, .group, .allEdges, .allGroups:
                return nil
            }
        }
        return KnowledgeGraphCardStyle(
            shape: style.shape,
            fill: color(for: style.fill, fallback: nil),
            stroke: color(for: style.stroke?.paint, fallback: nil),
            strokeWidth: style.stroke?.width.map { CGFloat($0) },
            strokeLine: style.stroke?.line,
            text: color(for: style.text?.paint, fallback: nil),
            opacity: style.opacity
        )
    }

    func edgeStyle(for edge: CompoundGraph.CardEdge, theme: KnowledgeGraphVisualTheme) -> KnowledgeGraphEdgeDrawingStyle {
        let style = resolvedStyle { target in
            switch target {
            case .allEdges:
                return 0
            case .edge(let id):
                return id == edge.id ? 3 : nil
            case .kind(let kind):
                let matches = edge.predicate == kind
                    || edge.id.predicate == kind
                    || expandedKind(kind) == edge.id.predicate
                    || compactKindSuffix(kind) == edge.predicate
                return matches ? 1 : nil
            case .canvas, .node, .namedGraph, .group, .rdfType, .allNodes, .allGroups:
                return nil
            }
        }
        let stroke = style.stroke ?? style.edge?.stroke
        return KnowledgeGraphEdgeDrawingStyle(
            stroke: color(for: stroke?.paint, fallback: nil),
            strokeWidth: stroke?.width.map { CGFloat($0) },
            strokeLine: stroke?.line,
            sourceMarker: style.edge?.sourceMarker,
            targetMarker: style.edge?.targetMarker,
            label: edgeLabelStyle(from: style.edge?.label),
            opacity: style.opacity
        )
    }

    func groupStyle(
        for group: CompoundGraph.Group,
        groupIndex: Int,
        theme: KnowledgeGraphVisualTheme
    ) -> KnowledgeGraphGroupDrawingStyle {
        let style = resolvedStyle { target in
            switch target {
            case .allGroups:
                return 0
            case .group(let id):
                let matches = group.id.key == "explicit:\(id)"
                    || group.id.key == id
                    || group.id.key == "explicit:\(id.dropGroupPrefix())"
                return matches ? 3 : nil
            case .namedGraph(let id):
                return group.id.key == "namedGraph:\(id)" ? 3 : nil
            case .kind(let kind):
                return group.id.key == kind || group.label == kind ? 1 : nil
            case .canvas, .node, .edge, .rdfType, .allNodes, .allEdges:
                return nil
            }
        }
        let fallback = KnowledgeGraphGroupPalette.color(for: group.style.tint, groupIndex: groupIndex)
        return KnowledgeGraphGroupDrawingStyle(
            shape: style.shape,
            fill: color(for: style.fill, fallback: nil),
            stroke: color(for: style.stroke?.paint, fallback: nil),
            headerFill: color(for: style.stroke?.paint, fallback: nil),
            strokeWidth: style.stroke?.width.map { CGFloat($0) },
            strokeLine: style.stroke?.line,
            text: color(for: style.text?.paint, fallback: fallback),
            opacity: style.opacity
        )
    }

    func canvasStyle(theme: KnowledgeGraphVisualTheme) -> KnowledgeGraphCanvasDrawingStyle {
        let style = resolvedStyle { target in
            if case .canvas = target { return 3 }
            return nil
        }
        return KnowledgeGraphCanvasDrawingStyle(
            fill: color(for: style.fill, fallback: nil),
            opacity: style.opacity
        )
    }

    private func resolvedStyle(specificity: (GraphStyleTarget) -> Int?) -> GraphStyle {
        guard let presentation else { return GraphStyle() }
        var result = GraphStyle()
        let candidates = presentation.styles.enumerated().compactMap { index, rule -> StyleCandidate? in
            guard let targetSpecificity = specificity(rule.target) else { return nil }
            return StyleCandidate(
                sourceOrder: index,
                priority: priorityRank(rule.priority),
                specificity: targetSpecificity,
                style: rule.style
            )
        }
        for candidate in candidates.sorted(by: styleCandidateSort) {
            result = result.merging(candidate.style)
        }
        return result
    }

    private struct StyleCandidate {
        let sourceOrder: Int
        let priority: Int
        let specificity: Int
        let style: GraphStyle
    }

    private func styleCandidateSort(_ lhs: StyleCandidate, _ rhs: StyleCandidate) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.specificity != rhs.specificity { return lhs.specificity < rhs.specificity }
        return lhs.sourceOrder < rhs.sourceOrder
    }

    private func priorityRank(_ priority: GraphStylePriority) -> Int {
        switch priority {
        case .default: return 0
        case .theme: return 1
        case .explicit: return 2
        case .override: return 3
        }
    }

    private func cardKind(_ card: CompoundGraph.Card) -> String {
        switch card.kind {
        case .resource(let kind):
            return kind.rawValue
        case .literal:
            return NodeKind.literal.rawValue
        }
    }

    private func expandedKind(_ value: String) -> String? {
        guard let separator = value.firstIndex(of: ":") else { return nil }
        let prefix = String(value[..<separator])
        let suffix = String(value[value.index(after: separator)...])
        guard let namespace = graph.namespaces.first(where: { $0.prefix == prefix }) else {
            return nil
        }
        return namespace.uri + suffix
    }

    private func compactKindSuffix(_ value: String) -> String? {
        guard let separator = value.firstIndex(of: ":") else { return nil }
        return String(value[value.index(after: separator)...])
    }

    private func color(for paint: GraphPaint?, fallback: Color?) -> Color? {
        guard let paint else { return fallback }
        switch paint {
        case .color(let color):
            return Color(
                red: color.red,
                green: color.green,
                blue: color.blue,
                opacity: color.alpha
            )
        case .palette(let name), .semantic(let name):
            return namedColor(name) ?? fallback
        }
    }

    private func namedColor(_ name: String) -> Color? {
        switch name.lowercased() {
        case "red", "critical", "danger":
            return .red
        case "orange", "warning":
            return .orange
        case "yellow":
            return .yellow
        case "green", "success":
            return .green
        case "mint":
            return .mint
        case "teal":
            return .teal
        case "blue", "primary":
            return .blue
        case "purple":
            return .purple
        case "pink":
            return .pink
        case "gray", "grey", "secondary":
            return .gray
        default:
            return nil
        }
    }

    private func edgeLabelStyle(from label: GraphEdgeLabelStyle?) -> KnowledgeGraphEdgeLabelDrawingStyle? {
        guard let label else { return nil }
        return KnowledgeGraphEdgeLabelDrawingStyle(
            shape: label.shape,
            fill: color(for: label.fill, fallback: nil),
            stroke: color(for: label.stroke?.paint, fallback: nil),
            strokeWidth: label.stroke?.width.map { CGFloat($0) },
            strokeLine: label.stroke?.line,
            text: color(for: label.text?.paint, fallback: nil),
            textSize: label.text?.size.map { CGFloat($0) },
            textWeight: fontWeight(label.text?.weight),
            opacity: label.opacity
        )
    }

    private func fontWeight(_ value: String?) -> Font.Weight? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "ultralight":
            return .ultraLight
        case "thin":
            return .thin
        case "light":
            return .light
        case "regular":
            return .regular
        case "medium":
            return .medium
        case "semibold":
            return .semibold
        case "bold":
            return .bold
        case "heavy":
            return .heavy
        case "black":
            return .black
        default:
            return nil
        }
    }
}

private extension GraphStyle {
    func merging(_ other: GraphStyle) -> GraphStyle {
        GraphStyle(
            shape: other.shape ?? shape,
            fill: other.fill ?? fill,
            stroke: other.stroke ?? stroke,
            text: other.text ?? text,
            edge: edge?.merging(other.edge) ?? other.edge,
            opacity: other.opacity ?? opacity
        )
    }
}

private extension GraphEdgeStyle {
    func merging(_ other: GraphEdgeStyle?) -> GraphEdgeStyle {
        guard let other else { return self }
        return GraphEdgeStyle(
            stroke: other.stroke ?? stroke,
            sourceMarker: other.sourceMarker ?? sourceMarker,
            targetMarker: other.targetMarker ?? targetMarker,
            route: other.route ?? route,
            label: label?.merging(other.label) ?? other.label
        )
    }
}

private extension GraphEdgeLabelStyle {
    func merging(_ other: GraphEdgeLabelStyle?) -> GraphEdgeLabelStyle {
        guard let other else { return self }
        return GraphEdgeLabelStyle(
            shape: other.shape ?? shape,
            fill: other.fill ?? fill,
            stroke: other.stroke ?? stroke,
            text: other.text ?? text,
            opacity: other.opacity ?? opacity
        )
    }
}

extension StrokeStyle {
    init(lineWidth: CGFloat, line: GraphLineStyle?, lineCap: CGLineCap = .round) {
        switch line {
        case .solid, .none:
            self.init(lineWidth: lineWidth, lineCap: lineCap)
        case .dashed(let pattern):
            self.init(
                lineWidth: lineWidth,
                lineCap: lineCap,
                dash: (pattern ?? [6, 4]).map { CGFloat($0) }
            )
        case .dotted:
            self.init(lineWidth: lineWidth, lineCap: lineCap, dash: [1, 4])
        }
    }
}

extension GroupStyle.Outline {
    init(lineStyle: GraphLineStyle) {
        switch lineStyle {
        case .solid:
            self = .solid
        case .dashed, .dotted:
            self = .dashed
        }
    }
}

private extension String {
    func dropGroupPrefix() -> String {
        hasPrefix("group:") ? String(dropFirst("group:".count)) : self
    }
}
