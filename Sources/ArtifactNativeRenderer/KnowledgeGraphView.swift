import SwiftUI
import KnowledgeGraph
import KnowledgeGraphParsers

/// Card-based diagram for a `KnowledgeGraph`.
///
/// The view hosts three stacked layers inside a `ScrollView`:
///   1. **Edges** drawn into a single `Canvas` so cost scales with edge count.
///   2. **Cards** rendered as `KnowledgeGraphCardView` instances positioned
///      from `KnowledgeGraphLayout.Result.cardPositions`.
///   3. **Edge labels** as pill-shaped SwiftUI views positioned from
///      `edgeLabelPositions`.
///
/// Navigation uses native scroll input only — no drag-to-pan. A
/// `MagnifyGesture` provides pinch zoom and intentionally coexists with the
/// scroll input via `.highPriorityGesture`. Layout runs off-main as a
/// detached task and writes the final `Result` back through `@State`.
struct KnowledgeGraphView: View {

    let graph: KnowledgeGraph

    @State private var layout: KnowledgeGraphLayout.Result?
    @State private var layoutTask: Task<Void, Never>?
    @State private var zoom: CGFloat = 1.0
    @State private var committedZoom: CGFloat = 1.0
    @State private var viewportSize: CGSize = .zero
    /// `true` once an initial fit-to-view has been applied for the current
    /// `graphIdentity`. Reset whenever the underlying graph changes so a fresh
    /// graph re-fits but ongoing manual zoom is preserved.
    @State private var didApplyInitialFit: Bool = false

    private let minZoom: CGFloat = 0.2
    private let maxZoom: CGFloat = 3.0
    private let viewportMargin: CGFloat = 16
    private let arrowSize: CGFloat = 9
    private let edgeLineWidth: CGFloat = 1.4
    private let zoomStep: CGFloat = 1.25

    var body: some View {
        Group {
            if graph.nodes.isEmpty {
                ContentUnavailableView(
                    "Empty graph",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let layout {
                scrollable(layout: layout)
                    .overlay(alignment: .bottomLeading) {
                        zoomToolbar
                            .padding(12)
                    }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            viewportSize = size
            applyInitialFitIfPossible()
        }
        .task(id: graphIdentity) {
            didApplyInitialFit = false
            await computeLayout(initial: previousPositions())
        }
        .onChange(of: layout?.canvasSize) { _, _ in
            applyInitialFitIfPossible()
        }
        .onDisappear {
            layoutTask?.cancel()
        }
    }

    // MARK: - Zoom toolbar

    private var zoomToolbar: some View {
        KnowledgeGraphZoomToolbar(
            zoom: zoom,
            minZoom: minZoom,
            maxZoom: maxZoom,
            onZoomOut: { applyZoom(zoom / zoomStep) },
            onZoomIn: { applyZoom(zoom * zoomStep) },
            onResetTo100: { applyZoom(1.0) },
            onFit: applyFitToView
        )
    }

    private func applyZoom(_ value: CGFloat) {
        let next = max(minZoom, min(maxZoom, value))
        withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
            zoom = next
            committedZoom = next
        }
    }

    private func applyFitToView() {
        guard
            let layout,
            viewportSize.width > 0,
            viewportSize.height > 0
        else { return }
        let next = fitZoom(canvas: layout.canvasSize, viewport: viewportSize)
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            zoom = next
            committedZoom = next
        }
    }

    /// Apply the initial fit exactly once per graph load, as soon as both the
    /// layout result and the viewport size are known. Subsequent user zoom is
    /// not overwritten.
    private func applyInitialFitIfPossible() {
        guard
            !didApplyInitialFit,
            let layout,
            viewportSize.width > 0,
            viewportSize.height > 0
        else { return }
        let next = fitZoom(canvas: layout.canvasSize, viewport: viewportSize)
        zoom = next
        committedZoom = next
        didApplyInitialFit = true
    }

    private func fitZoom(canvas: CGSize, viewport: CGSize) -> CGFloat {
        let availableW = max(viewport.width - viewportMargin * 2, 1)
        let availableH = max(viewport.height - viewportMargin * 2, 1)
        let ratio = min(availableW / canvas.width, availableH / canvas.height)
        return max(minZoom, min(maxZoom, ratio))
    }

    // MARK: - Identity / warm restart

    private var graphIdentity: Int {
        var hasher = Hasher()
        hasher.combine(graph.nodes.count)
        hasher.combine(graph.edges.count)
        for node in graph.nodes { hasher.combine(node.id) }
        for edge in graph.edges { hasher.combine(edge.id) }
        return hasher.finalize()
    }

    /// Convert the previous `cardPositions` map (keyed by `Card.ID`) back to
    /// `[NodeIdentifier: CGPoint]` so the layout engine can warm-restart from
    /// the wrapped node identifier.
    private func previousPositions() -> [NodeIdentifier: CGPoint] {
        guard let layout else { return [:] }
        var result: [NodeIdentifier: CGPoint] = [:]
        result.reserveCapacity(layout.cardPositions.count)
        for (cardID, origin) in layout.cardPositions {
            if let card = layout.compoundGraph.cardByID[cardID] {
                result[cardID.nodeID] = CGPoint(
                    x: origin.x + card.size.width / 2,
                    y: origin.y + card.size.height / 2
                )
            }
        }
        return result
    }

    // MARK: - Container

    private func scrollable(layout: KnowledgeGraphLayout.Result) -> some View {
        let canvas = layout.canvasSize
        let scaledWidth = canvas.width * zoom + viewportMargin * 2
        let scaledHeight = canvas.height * zoom + viewportMargin * 2
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                edgeCanvas(layout: layout)
                cardsLayer(layout: layout)
                edgeLabelsLayer(layout: layout)
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(
                width: canvas.width * zoom,
                height: canvas.height * zoom,
                alignment: .topLeading
            )
            .padding(viewportMargin)
            .frame(width: scaledWidth, height: scaledHeight, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if targetEnvironment(macCatalyst)
        .simultaneousGesture(zoomGesture)
        #else
        .highPriorityGesture(zoomGesture)
        #endif
    }

    // MARK: - Edges layer

    private func edgeCanvas(layout: KnowledgeGraphLayout.Result) -> some View {
        Canvas(opaque: false) { context, _ in
            for edge in layout.compoundGraph.edges {
                guard let route = layout.edgeRoutes[edge.id] else { continue }
                drawEdge(route: route, in: &context)
            }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
        .allowsHitTesting(false)
    }

    private func drawEdge(route: KnowledgeGraphLayout.EdgeRoute, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: route.start)
        if route.isCurved {
            path.addQuadCurve(to: route.end, control: route.control)
        } else {
            path.addLine(to: route.end)
        }
        context.stroke(
            path,
            with: .color(Color.secondary.opacity(0.75)),
            style: StrokeStyle(lineWidth: edgeLineWidth, lineCap: .round)
        )
        let tangent: CGVector
        if route.isCurved {
            tangent = CGVector(dx: route.end.x - route.control.x, dy: route.end.y - route.control.y)
        } else {
            tangent = CGVector(dx: route.end.x - route.start.x, dy: route.end.y - route.start.y)
        }
        drawArrowhead(at: route.end, along: tangent, in: &context)
    }

    private func drawArrowhead(
        at tip: CGPoint,
        along tangent: CGVector,
        in context: inout GraphicsContext
    ) {
        let length = max(hypot(tangent.dx, tangent.dy), 0.001)
        let ux = tangent.dx / length
        let uy = tangent.dy / length
        let leftAngle: CGFloat = .pi * 5 / 6
        let rightAngle: CGFloat = -.pi * 5 / 6
        let left = CGPoint(
            x: tip.x + (ux * cos(leftAngle) - uy * sin(leftAngle)) * arrowSize,
            y: tip.y + (ux * sin(leftAngle) + uy * cos(leftAngle)) * arrowSize
        )
        let right = CGPoint(
            x: tip.x + (ux * cos(rightAngle) - uy * sin(rightAngle)) * arrowSize,
            y: tip.y + (ux * sin(rightAngle) + uy * cos(rightAngle)) * arrowSize
        )
        var head = Path()
        head.move(to: tip)
        head.addLine(to: left)
        head.addLine(to: right)
        head.closeSubpath()
        context.fill(head, with: .color(Color.secondary.opacity(0.9)))
    }

    // MARK: - Cards layer

    private func cardsLayer(layout: KnowledgeGraphLayout.Result) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.compoundGraph.cards) { card in
                if let origin = layout.cardPositions[card.id] {
                    KnowledgeGraphCardView(card: card)
                        .position(
                            x: origin.x + card.size.width / 2,
                            y: origin.y + card.size.height / 2
                        )
                }
            }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height, alignment: .topLeading)
    }

    // MARK: - Edge labels layer

    private func edgeLabelsLayer(layout: KnowledgeGraphLayout.Result) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.compoundGraph.edges) { edge in
                if let position = layout.edgeLabelPositions[edge.id] {
                    KnowledgeGraphEdgeLabelView(text: edge.predicate)
                        .position(position)
                }
            }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Layout

    private func computeLayout(initial: [NodeIdentifier: CGPoint]) async {
        layoutTask?.cancel()
        let snapshot = graph
        let task = Task.detached(priority: .userInitiated) {
            KnowledgeGraphLayout.compute(graph: snapshot, initial: initial)
        }
        layoutTask = Task { @MainActor in
            let result = await task.value
            if Task.isCancelled { return }
            self.layout = result
        }
    }

    // MARK: - Gestures

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let next = committedZoom * value.magnification
                zoom = max(minZoom, min(maxZoom, next))
            }
            .onEnded { _ in
                committedZoom = zoom
            }
    }
}
