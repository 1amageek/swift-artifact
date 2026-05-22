import SwiftUI

#if DEBUG
private struct KnowledgeGraphPresentationStylePreview: View {
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack(alignment: .top, spacing: 14) {
                    nodeShapeMatrix
                    groupShapeMatrix
                    edgeStyleMatrix
                    attributeRuleMatrix
                }
                logisticsBoard
            }
            .padding(18)
        }
        .background(Color(red: 0.965, green: 0.975, blue: 0.98))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GraphPresentation style evaluator")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.11, green: 0.13, blue: 0.16))
                Text("Shape, paint, stroke, line style, marker, and attribute-driven rules")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.42, green: 0.46, blue: 0.52))
            }
            Spacer()
            HStack(spacing: 12) {
                legendSwatch(color: .blue, label: "Node")
                legendSwatch(color: .green, label: "Group")
                legendSwatch(color: .purple, label: "Edge")
                legendSwatch(color: .orange, label: "Rule")
            }
        }
        .frame(width: 1170)
    }

    private var nodeShapeMatrix: some View {
        previewPanel(title: "Node shapes", width: 270) {
            VStack(spacing: 10) {
                ForEach(PreviewNode.shapeSamples) { node in
                    previewNode(node)
                }
            }
        }
    }

    private var groupShapeMatrix: some View {
        previewPanel(title: "Group shapes", width: 270) {
            VStack(spacing: 10) {
                ForEach(PreviewGroupSample.samples) { group in
                    previewGroup(group)
                }
            }
        }
    }

    private var edgeStyleMatrix: some View {
        previewPanel(title: "Edge styles", width: 280) {
            VStack(spacing: 9) {
                ForEach(PreviewEdgeSample.samples) { edge in
                    previewEdge(edge)
                }
            }
        }
    }

    private var attributeRuleMatrix: some View {
        previewPanel(title: "Attribute rules", width: 280) {
            VStack(spacing: 10) {
                attributeRuleRow(target: "node.status", value: "critical", color: .red, shape: .roundedRectangle)
                attributeRuleRow(target: "node.kind", value: "hub", color: .blue, shape: .capsule)
                attributeRuleRow(target: "group.stage", value: "domestic", color: .green, shape: .rectangle)
                attributeRuleRow(target: "edge.type", value: "handoff", color: .purple, shape: .roundedRectangle)
            }
        }
    }

    private var logisticsBoard: some View {
        previewPanel(title: "Integrated layout sample", width: 1170) {
            HStack(alignment: .top, spacing: 14) {
                stage(
                    title: "Overseas",
                    tint: Color(red: 0.14, green: 0.68, blue: 0.51),
                    shape: .rectangle,
                    nodes: [
                        .init(title: "OEM Factory", subtitle: "rectangle", shape: .rectangle, accent: .green),
                        .init(title: "Vietnam Plant", subtitle: "rounded", shape: .roundedRectangle, accent: .mint),
                        .init(title: "Bangladesh Plant", subtitle: "rectangle", shape: .rectangle, accent: .green)
                    ]
                )
                edgeColumn(style: .solid, marker: .arrow, color: .gray, label: "solid")
                stage(
                    title: "International",
                    tint: Color(red: 0.11, green: 0.61, blue: 0.86),
                    shape: .roundedRectangle,
                    nodes: [
                        .init(title: "Air Forwarder", subtitle: "capsule + dashed", shape: .capsule, accent: .blue, dashed: true),
                        .init(title: "Ocean Forwarder", subtitle: "capsule + amber", shape: .capsule, accent: .orange)
                    ]
                )
                edgeColumn(style: .dashed, marker: .arrow, color: .purple, label: "dashed")
                stage(
                    title: "Domestic DC",
                    tint: Color(red: 0.14, green: 0.68, blue: 0.51),
                    shape: .roundedRectangle,
                    nodes: [
                        .init(title: "Chiba DC", subtitle: "blue stroke", shape: .roundedRectangle, accent: .blue),
                        .init(title: "Okayama DC", subtitle: "orange stroke", shape: .roundedRectangle, accent: .orange)
                    ]
                )
                edgeColumn(style: .dotted, marker: .arrow, color: .purple, label: "dotted")
                stage(
                    title: "Retail",
                    tint: Color(red: 0.14, green: 0.68, blue: 0.51),
                    shape: .capsule,
                    nodes: [
                        .init(title: "Store A", subtitle: "rounded", shape: .roundedRectangle, accent: .gray),
                        .init(title: "Store B", subtitle: "rounded", shape: .roundedRectangle, accent: .gray)
                    ]
                )
            }
        }
    }

    private func previewPanel<Content: View>(
        title: String,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(red: 0.19, green: 0.23, blue: 0.28))
            content()
        }
        .padding(12)
        .frame(width: width, alignment: .topLeading)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.86, green: 0.89, blue: 0.92), lineWidth: 1)
        )
    }

    private func stage(
        title: String,
        tint: Color,
        shape: PreviewShape,
        nodes: [PreviewNode]
    ) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(tint)

            VStack(spacing: 14) {
                ForEach(nodes) { node in
                    previewNode(node)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .frame(width: 170)
        .modifier(ShapeContainer(shape: shape, fill: tint.opacity(0.08), stroke: tint.opacity(0.24), lineWidth: 1))
    }

    @ViewBuilder
    private func previewNode(_ node: PreviewNode) -> some View {
        let content = VStack(spacing: 5) {
            Text(node.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.13, green: 0.16, blue: 0.20))
            Text(node.subtitle)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(red: 0.43, green: 0.47, blue: 0.53))
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.horizontal, 10)

        content
            .modifier(ShapeContainer(
                shape: node.shape,
                fill: Color.white,
                stroke: node.accent,
                style: strokeStyle(dashed: node.dashed)
            ))
    }

    private func previewGroup(_ group: PreviewGroupSample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(group.title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(group.stroke)
                Text(group.subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(red: 0.42, green: 0.46, blue: 0.52))
            }
            HStack(spacing: 6) {
                previewNode(.init(title: "Node A", subtitle: "member", shape: .roundedRectangle, accent: group.stroke))
                previewNode(.init(title: "Node B", subtitle: "member", shape: .roundedRectangle, accent: group.stroke.opacity(0.65)))
            }
        }
        .padding(10)
        .modifier(ShapeContainer(shape: group.shape, fill: group.fill, stroke: group.stroke.opacity(0.55), lineWidth: 1.2))
    }

    private func previewEdge(_ edge: PreviewEdgeSample) -> some View {
        HStack(spacing: 10) {
            Canvas { context, size in
                let y = size.height / 2
                drawEdge(in: &context, size: size, y: y, style: edge.style, marker: edge.marker, color: edge.color)
            }
            .frame(width: 112, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(edge.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.19, green: 0.23, blue: 0.28))
                Text(edge.detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(red: 0.42, green: 0.46, blue: 0.52))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 34)
    }

    private func edgeColumn(
        style: PreviewEdgeLineStyle,
        marker: PreviewEdgeMarker,
        color: Color,
        label: String
    ) -> some View {
        VStack(spacing: 8) {
            Canvas { context, size in
                drawEdge(in: &context, size: size, y: size.height / 2, style: style, marker: marker, color: color)
            }
            .frame(width: 52, height: 64)

            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.top, 86)
    }

    private func attributeRuleRow(target: String, value: String, color: Color, shape: PreviewShape) -> some View {
        HStack(spacing: 10) {
            Text(target)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.19, green: 0.23, blue: 0.28))
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 58, alignment: .leading)
            Text(shape.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(red: 0.42, green: 0.46, blue: 0.52))
            Spacer(minLength: 0)
            Rectangle()
                .fill(color)
                .frame(width: 18, height: 10)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color(red: 0.98, green: 0.985, blue: 0.99))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(red: 0.88, green: 0.90, blue: 0.93), lineWidth: 1)
        )
    }

    private func drawEdge(
        in context: inout GraphicsContext,
        size: CGSize,
        y: CGFloat,
        style: PreviewEdgeLineStyle,
        marker: PreviewEdgeMarker,
        color: Color
    ) {
        var path = Path()
        path.move(to: CGPoint(x: 6, y: y))
        path.addLine(to: CGPoint(x: size.width - 12, y: y))
        context.stroke(path, with: .color(color), style: edgeStrokeStyle(style))

        guard marker == .arrow else {
            return
        }

        var arrow = Path()
        arrow.move(to: CGPoint(x: size.width - 13, y: y - 4))
        arrow.addLine(to: CGPoint(x: size.width - 5, y: y))
        arrow.addLine(to: CGPoint(x: size.width - 13, y: y + 4))
        context.stroke(arrow, with: .color(color), lineWidth: 1.5)
    }

    private func legendSwatch(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(red: 0.36, green: 0.40, blue: 0.46))
        }
    }

    private func strokeStyle(dashed: Bool) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: dashed ? [5, 4] : [])
    }

    private func edgeStrokeStyle(_ style: PreviewEdgeLineStyle) -> StrokeStyle {
        switch style {
        case .solid:
            return StrokeStyle(lineWidth: 1.5, lineCap: .round)
        case .dashed:
            return StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [7, 5])
        case .dotted:
            return StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [1, 6])
        }
    }
}

private struct ShapeContainer: ViewModifier {
    let shape: PreviewShape
    let fill: Color
    let stroke: Color
    var style: StrokeStyle?
    var lineWidth: CGFloat = 1

    func body(content: Content) -> some View {
        switch shape {
        case .rectangle:
            content
                .background(Rectangle().fill(fill))
                .overlay(Rectangle().stroke(stroke, style: style ?? StrokeStyle(lineWidth: lineWidth)))
        case .roundedRectangle:
            content
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(stroke, style: style ?? StrokeStyle(lineWidth: lineWidth)))
        case .capsule:
            content
                .background(Capsule().fill(fill))
                .overlay(Capsule().stroke(stroke, style: style ?? StrokeStyle(lineWidth: lineWidth)))
        }
    }
}

private struct PreviewNode: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let shape: PreviewShape
    let accent: Color
    var dashed: Bool = false

    static let shapeSamples: [PreviewNode] = [
        .init(title: "Rectangle Node", subtitle: "fill + square border", shape: .rectangle, accent: .green),
        .init(title: "Rounded Node", subtitle: "corner radius + stroke", shape: .roundedRectangle, accent: .blue),
        .init(title: "Capsule Node", subtitle: "pill outline + dashed", shape: .capsule, accent: .orange, dashed: true)
    ]
}

private struct PreviewGroupSample: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let shape: PreviewShape
    let fill: Color
    let stroke: Color

    static let samples: [PreviewGroupSample] = [
        .init(
            title: "Rectangle",
            subtitle: "stage block",
            shape: .rectangle,
            fill: Color(red: 0.14, green: 0.68, blue: 0.51).opacity(0.08),
            stroke: Color(red: 0.14, green: 0.68, blue: 0.51)
        ),
        .init(
            title: "Rounded",
            subtitle: "semantic group",
            shape: .roundedRectangle,
            fill: Color(red: 0.11, green: 0.61, blue: 0.86).opacity(0.08),
            stroke: Color(red: 0.11, green: 0.61, blue: 0.86)
        ),
        .init(
            title: "Capsule",
            subtitle: "flow lane",
            shape: .capsule,
            fill: Color.orange.opacity(0.10),
            stroke: .orange
        )
    ]
}

private struct PreviewEdgeSample: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    let style: PreviewEdgeLineStyle
    let marker: PreviewEdgeMarker
    let color: Color

    static let samples: [PreviewEdgeSample] = [
        .init(label: "Solid arrow", detail: "direct dependency", style: .solid, marker: .arrow, color: .gray),
        .init(label: "Dashed arrow", detail: "conditional flow", style: .dashed, marker: .arrow, color: .purple),
        .init(label: "Dotted arrow", detail: "reference link", style: .dotted, marker: .arrow, color: .blue),
        .init(label: "Solid line", detail: "undirected relation", style: .solid, marker: .none, color: .orange)
    ]
}

private enum PreviewShape {
    case rectangle
    case roundedRectangle
    case capsule

    var label: String {
        switch self {
        case .rectangle:
            return "rectangle"
        case .roundedRectangle:
            return "rounded"
        case .capsule:
            return "capsule"
        }
    }
}

private enum PreviewEdgeLineStyle {
    case solid
    case dashed
    case dotted
}

private enum PreviewEdgeMarker {
    case none
    case arrow
}

#Preview("GraphPresentation - detailed style evaluator") {
    KnowledgeGraphPresentationStylePreview()
        .frame(width: 1210, height: 760)
}
#endif
