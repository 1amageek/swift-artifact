import SwiftUI
import KnowledgeGraph
import KnowledgeGraphParsers

/// Card-based diagram for a `KnowledgeGraph`.
///
/// Rendering uses a single SwiftUI `Canvas` whose `symbols:` block
/// rasterizes every `KnowledgeGraphCardView` once per layout snapshot. The
/// Canvas draws batched edge paths, arrowheads, edge-label pills, and then
/// the resolved card symbols directly into one `GraphicsContext`. Per-frame
/// cost during pan / zoom is therefore proportional only to the cards and
/// edges that intersect the visible viewport — there is no SwiftUI `ZStack`
/// rebuilding hundreds of subviews per gesture tick.
///
/// `KnowledgeGraphViewport` owns the `zoom` + `offset` transform. Pinch
/// (`MagnifyGesture`) updates the viewport via `zoomed(to:anchor:)` so
/// zooming targets the gesture location rather than the canvas origin —
/// fixing the prior bug where `.scaleEffect(_, anchor: .topLeading)`
/// always zoomed about the top-left. A `DragGesture` provides pan; there
/// is no enclosing `ScrollView`.
struct KnowledgeGraphView: View {

    let graph: KnowledgeGraph

    @State private var layout: KnowledgeGraphLayout.Result?
    @State private var layoutTask: Task<Void, Never>?

    /// Canonical viewport between gestures. Live gesture state is layered
    /// on top in `effectiveViewport`.
    @State private var committedViewport = KnowledgeGraphViewport()
    /// Snapshot of `committedViewport` captured at the moment the user
    /// begins a magnify gesture. Cleared on gesture end.
    @State private var viewportAtMagnifyStart: KnowledgeGraphViewport?
    @GestureState private var liveDragTranslation: CGSize = .zero
    @GestureState private var liveMagnify: MagnifyState = .inactive

    @State private var viewportSize: CGSize = .zero
    /// `true` once an initial fit-to-view has been applied for the current
    /// `graphIdentity`. Reset whenever the underlying graph changes so a
    /// fresh graph re-fits but ongoing manual zoom is preserved.
    @State private var didApplyInitialFit: Bool = false

    private let minZoom: CGFloat = 0.2
    private let maxZoom: CGFloat = 3.0
    private let viewportMargin: CGFloat = 16
    private let arrowSize: CGFloat = 9
    private let edgeLineWidth: CGFloat = 1.4
    private let cullingMargin: CGFloat = 120
    private let zoomStep: CGFloat = 1.25

    /// Transient state mirrored from `MagnifyGesture` via `@GestureState` so
    /// the in-flight pinch can be replayed against `viewportAtMagnifyStart`
    /// every frame without mutating `committedViewport`.
    private struct MagnifyState: Equatable {
        var magnification: CGFloat
        var anchor: CGPoint
        var active: Bool

        static let inactive = MagnifyState(magnification: 1.0, anchor: .zero, active: false)
    }

    /// Viewport actually used for drawing, reflecting any in-flight gesture
    /// state. When a magnify is active the anchor-zoom formula is applied
    /// to the captured `viewportAtMagnifyStart` so the screen point under
    /// the user's fingers stays put. Pan and magnify are not expected to
    /// fire simultaneously; if both do, magnify wins so the anchor math
    /// stays stable.
    private var effectiveViewport: KnowledgeGraphViewport {
        if liveMagnify.active {
            let base = viewportAtMagnifyStart ?? committedViewport
            let target = clamp(base.zoom * liveMagnify.magnification)
            return base.zoomed(to: target, anchor: liveMagnify.anchor)
        }
        var current = committedViewport
        current.offset.x += liveDragTranslation.width
        current.offset.y += liveDragTranslation.height
        return current
    }

    var body: some View {
        Group {
            if graph.nodes.isEmpty {
                ContentUnavailableView(
                    "Empty graph",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let layout {
                canvasContent(layout: layout)
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

    // MARK: - Canvas

    private func canvasContent(layout: KnowledgeGraphLayout.Result) -> some View {
        let canvas = Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            let viewport = effectiveViewport
            let visibleRect = CGRect(origin: .zero, size: size)
                .insetBy(dx: -cullingMargin, dy: -cullingMargin)
            drawEdges(layout: layout, viewport: viewport, visibleRect: visibleRect, context: &context)
            drawEdgeLabels(layout: layout, viewport: viewport, visibleRect: visibleRect, context: &context)
            drawCards(layout: layout, viewport: viewport, visibleRect: visibleRect, context: &context)
        } symbols: {
            ForEach(layout.compoundGraph.cards) { card in
                KnowledgeGraphCardView(card: card)
                    .tag(card.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // `KnowledgeGraphCanvasHost` taps the native scroll-wheel (macOS) /
        // two-finger trackpad pan (iOS / Catalyst / visionOS) events that
        // SwiftUI's gesture system does not surface. On macOS it also feeds
        // pinch magnification through `NSEvent.magnify`, so we suppress the
        // SwiftUI `MagnifyGesture` there to avoid double-zooming.
        return KnowledgeGraphCanvasHost(
            onScroll: { delta, _ in
                committedViewport.offset.x += delta.width
                committedViewport.offset.y += delta.height
            },
            onMagnify: { magnification, location in
                let target = clamp(committedViewport.zoom * (1 + magnification))
                committedViewport = committedViewport.zoomed(to: target, anchor: location)
            }
        ) {
            canvas
        }
        .contentShape(Rectangle())
        .gesture(panGesture)
        #if !os(macOS)
        .simultaneousGesture(magnifyGesture)
        #endif
    }

    // MARK: - Drawing — edges + arrowheads

    private func drawEdges(
        layout: KnowledgeGraphLayout.Result,
        viewport: KnowledgeGraphViewport,
        visibleRect: CGRect,
        context: inout GraphicsContext
    ) {
        var strokePath = Path()
        var headPath = Path()

        for edge in layout.compoundGraph.edges {
            guard let route = layout.edgeRoutes[edge.id] else { continue }
            let screenStart = viewport.canvasToScreen(route.start)
            let screenEnd = viewport.canvasToScreen(route.end)

            // Coarse cull — skip when both endpoints fall outside the
            // viewport along the same axis. The curve's bounding box may
            // bulge slightly past the endpoints; `cullingMargin` covers it.
            if (screenStart.x < visibleRect.minX && screenEnd.x < visibleRect.minX) ||
                (screenStart.x > visibleRect.maxX && screenEnd.x > visibleRect.maxX) ||
                (screenStart.y < visibleRect.minY && screenEnd.y < visibleRect.minY) ||
                (screenStart.y > visibleRect.maxY && screenEnd.y > visibleRect.maxY) {
                continue
            }

            strokePath.move(to: screenStart)
            let tangent: CGVector
            if route.isCurved {
                let screenControl = viewport.canvasToScreen(route.control)
                strokePath.addQuadCurve(to: screenEnd, control: screenControl)
                tangent = CGVector(
                    dx: screenEnd.x - screenControl.x,
                    dy: screenEnd.y - screenControl.y
                )
            } else {
                strokePath.addLine(to: screenEnd)
                tangent = CGVector(
                    dx: screenEnd.x - screenStart.x,
                    dy: screenEnd.y - screenStart.y
                )
            }
            appendArrowhead(at: screenEnd, along: tangent, into: &headPath)
        }

        if !strokePath.isEmpty {
            context.stroke(
                strokePath,
                with: .color(Color.secondary.opacity(0.75)),
                style: StrokeStyle(lineWidth: edgeLineWidth, lineCap: .round)
            )
        }
        if !headPath.isEmpty {
            context.fill(headPath, with: .color(Color.secondary.opacity(0.9)))
        }
    }

    private func appendArrowhead(
        at tip: CGPoint,
        along tangent: CGVector,
        into path: inout Path
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
        path.move(to: tip)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
    }

    // MARK: - Drawing — edge labels

    private func drawEdgeLabels(
        layout: KnowledgeGraphLayout.Result,
        viewport: KnowledgeGraphViewport,
        visibleRect: CGRect,
        context: inout GraphicsContext
    ) {
        for edge in layout.compoundGraph.edges {
            guard let position = layout.edgeLabelPositions[edge.id] else { continue }
            let screenPos = viewport.canvasToScreen(position)
            guard visibleRect.contains(screenPos) else { continue }

            let resolved = context.resolve(
                Text(edge.predicate)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.primary)
            )
            let textSize = resolved.measure(in: CGSize(width: 180, height: 60))
            let hPad: CGFloat = 6
            let vPad: CGFloat = 2
            let bgRect = CGRect(
                x: screenPos.x - textSize.width / 2 - hPad,
                y: screenPos.y - textSize.height / 2 - vPad,
                width: textSize.width + hPad * 2,
                height: textSize.height + vPad * 2
            )
            let capsule = Capsule(style: .continuous).path(in: bgRect)
            context.fill(capsule, with: .color(Color(.sRGB, white: 0.16, opacity: 0.92)))
            context.stroke(
                capsule,
                with: .color(Color.primary.opacity(0.08)),
                lineWidth: 0.5
            )
            context.draw(resolved, at: screenPos)
        }
    }

    // MARK: - Drawing — cards

    private func drawCards(
        layout: KnowledgeGraphLayout.Result,
        viewport: KnowledgeGraphViewport,
        visibleRect: CGRect,
        context: inout GraphicsContext
    ) {
        for card in layout.compoundGraph.cards {
            guard let origin = layout.cardPositions[card.id] else { continue }
            let screenOrigin = viewport.canvasToScreen(origin)
            let drawRect = CGRect(
                x: screenOrigin.x,
                y: screenOrigin.y,
                width: card.size.width * viewport.zoom,
                height: card.size.height * viewport.zoom
            )
            guard visibleRect.intersects(drawRect) else { continue }
            if let resolved = context.resolveSymbol(id: card.id) {
                context.draw(resolved, in: drawRect)
            }
        }
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($liveDragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                committedViewport.offset.x += value.translation.width
                committedViewport.offset.y += value.translation.height
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($liveMagnify) { value, state, _ in
                if !state.active {
                    state.active = true
                    state.anchor = value.startLocation
                }
                state.magnification = value.magnification
            }
            .onChanged { _ in
                if viewportAtMagnifyStart == nil {
                    viewportAtMagnifyStart = committedViewport
                }
            }
            .onEnded { value in
                let base = viewportAtMagnifyStart ?? committedViewport
                let target = clamp(base.zoom * value.magnification)
                committedViewport = base.zoomed(to: target, anchor: value.startLocation)
                viewportAtMagnifyStart = nil
            }
    }

    // MARK: - Zoom toolbar

    private var zoomToolbar: some View {
        KnowledgeGraphZoomToolbar(
            zoom: effectiveViewport.zoom,
            minZoom: minZoom,
            maxZoom: maxZoom,
            onZoomOut: { applyZoomStep(factor: 1 / zoomStep) },
            onZoomIn: { applyZoomStep(factor: zoomStep) },
            onResetTo100: { applyZoomTarget(1.0) },
            onFit: applyFitToView
        )
    }

    private func applyZoomStep(factor: CGFloat) {
        let target = clamp(committedViewport.zoom * factor)
        let anchor = viewportCenter()
        withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
            committedViewport = committedViewport.zoomed(to: target, anchor: anchor)
        }
    }

    private func applyZoomTarget(_ value: CGFloat) {
        let target = clamp(value)
        let anchor = viewportCenter()
        withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
            committedViewport = committedViewport.zoomed(to: target, anchor: anchor)
        }
    }

    private func viewportCenter() -> CGPoint {
        CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    }

    private func applyFitToView() {
        guard
            let layout,
            viewportSize.width > 0,
            viewportSize.height > 0
        else { return }
        let fitted = fitViewport(canvas: layout.canvasSize, viewport: viewportSize)
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            committedViewport = fitted
        }
    }

    /// Apply the initial fit exactly once per graph load, as soon as both
    /// the layout result and the viewport size are known. Subsequent user
    /// zoom / pan is not overwritten.
    private func applyInitialFitIfPossible() {
        guard
            !didApplyInitialFit,
            let layout,
            viewportSize.width > 0,
            viewportSize.height > 0
        else { return }
        committedViewport = fitViewport(canvas: layout.canvasSize, viewport: viewportSize)
        didApplyInitialFit = true
    }

    private func fitViewport(canvas: CGSize, viewport: CGSize) -> KnowledgeGraphViewport {
        let availableW = max(viewport.width - viewportMargin * 2, 1)
        let availableH = max(viewport.height - viewportMargin * 2, 1)
        let ratio = min(availableW / canvas.width, availableH / canvas.height)
        let zoom = clamp(ratio)
        let scaledW = canvas.width * zoom
        let scaledH = canvas.height * zoom
        // Centre the laid-out canvas within the available viewport.
        let offset = CGPoint(
            x: (viewport.width - scaledW) / 2,
            y: (viewport.height - scaledH) / 2
        )
        return KnowledgeGraphViewport(offset: offset, zoom: zoom)
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        max(minZoom, min(maxZoom, value))
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
    /// `[NodeIdentifier: CGPoint]` so the layout engine can warm-restart
    /// from the wrapped node identifier.
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
}
