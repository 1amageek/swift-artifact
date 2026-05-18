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
    let groupingStrategy: GroupingStrategy

    init(graph: KnowledgeGraph, groupingStrategy: GroupingStrategy = .namedGraphs()) {
        self.graph = graph
        self.groupingStrategy = groupingStrategy
    }

    @State private var layout: KnowledgeGraphLayout.Result?
    @State private var layoutTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

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
    @State private var hoveredCardID: CompoundGraph.Card.ID?

    private let minZoom: CGFloat = 0.2
    private let maxZoom: CGFloat = 3.0
    private let viewportMargin: CGFloat = 16
    private let arrowSize: CGFloat = 9
    private let edgeLineWidth: CGFloat = 1.4
    private let edgeSourceMarkerRadius: CGFloat = 2.2
    private let edgeLabelHorizontalPadding: CGFloat = 6
    private let edgeLabelVerticalPadding: CGFloat = 3
    private let edgeLabelCornerRadius: CGFloat = 7
    private let edgeLabelGuideInset: CGFloat = 2
    private let cullingMargin: CGFloat = 120
    private let zoomStep: CGFloat = 1.25
    private let groupLabelMaximumCharacters = 48
    private let nodeDetailPopupWidth: CGFloat = 320
    private let nodeDetailPopupEstimatedHeight: CGFloat = 220
    private let nodeDetailPopupGap: CGFloat = 10
    private let nodeDetailPopupViewportInset: CGFloat = 12

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
        let theme = KnowledgeGraphVisualTheme(colorScheme: colorScheme)
        // Pre-compute per-group SwiftUI values (Color, Text) once per layout
        // snapshot so Canvas's per-frame redraw does not reconstruct them on
        // every pan/zoom tick. `context.resolve` and `Text.measure` still run
        // inside the Canvas closure because they need a `GraphicsContext`,
        // but the inputs feeding them are now stable values.
        let groupRenderInfos = makeGroupRenderInfos(layout: layout, theme: theme)
        let canvas = Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            let viewport = effectiveViewport
            let visibleRect = CGRect(origin: .zero, size: size)
                .insetBy(dx: -cullingMargin, dy: -cullingMargin)
            // Z-order: groups (background) → edges → edge labels → cards
            // (foreground). Multi-group overlaps darken naturally because
            // each fill is drawn with `style.opacity`.
            drawGroups(
                layout: layout,
                renderInfos: groupRenderInfos,
                viewport: viewport,
                visibleRect: visibleRect,
                context: &context
            )
            drawEdges(layout: layout, viewport: viewport, visibleRect: visibleRect, theme: theme, context: &context)
            drawEdgeLabels(layout: layout, viewport: viewport, visibleRect: visibleRect, theme: theme, context: &context)
            drawCards(layout: layout, viewport: viewport, visibleRect: visibleRect, context: &context)
        } symbols: {
            ForEach(layout.compoundGraph.cards) { card in
                KnowledgeGraphCardView(card: card, theme: theme)
                    .tag(card.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)

        // `KnowledgeGraphCanvasHost` taps the native scroll-wheel (macOS) /
        // two-finger trackpad pan (iOS / Catalyst / visionOS) events that
        // SwiftUI's gesture system does not surface. On macOS it also feeds
        // pinch magnification through `NSEvent.magnify`, so we suppress the
        // SwiftUI `MagnifyGesture` there to avoid double-zooming.
        return KnowledgeGraphCanvasHost(
            onScroll: { delta, _ in
                committedViewport.offset.x += delta.width
                committedViewport.offset.y += delta.height
                hoveredCardID = nil
            },
            onMagnify: { magnification, location in
                let target = clamp(committedViewport.zoom * (1 + magnification))
                committedViewport = committedViewport.zoomed(to: target, anchor: location)
                hoveredCardID = nil
            }
        ) {
            canvas
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoveredCardID = cardID(at: location, layout: layout, viewport: effectiveViewport)
            case .ended:
                hoveredCardID = nil
            }
        }
        .overlay(alignment: .topLeading) {
            hoveredNodeDetailPopup(layout: layout, theme: theme)
        }
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
        theme: KnowledgeGraphVisualTheme,
        context: inout GraphicsContext
    ) {
        var strokePath = Path()
        var sourcePath = Path()
        var headPath = Path()

        for edge in layout.compoundGraph.edges {
            guard let route = layout.edgeRoutes[edge.id] else { continue }
            let routePoints = route.points.isEmpty ? [route.start, route.end] : route.points
            let screenPoints = routePoints.map { viewport.canvasToScreen($0) }
            guard
                let screenStart = screenPoints.first,
                let screenEnd = screenPoints.last
            else { continue }

            var routeBounds = CGRect.null
            for point in screenPoints {
                let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
                routeBounds = routeBounds.isNull ? rect : routeBounds.union(rect)
            }
            if !routeBounds.insetBy(dx: -48, dy: -48).intersects(visibleRect) {
                continue
            }

            strokePath.move(to: screenStart)
            appendSourceMarker(at: screenStart, into: &sourcePath)
            let tangent: CGVector
            if route.isCurved {
                let screenControl = viewport.canvasToScreen(route.control)
                strokePath.addQuadCurve(to: screenEnd, control: screenControl)
                tangent = CGVector(
                    dx: screenEnd.x - screenControl.x,
                    dy: screenEnd.y - screenControl.y
                )
            } else if screenPoints.count > 2 {
                for point in screenPoints.dropFirst() {
                    strokePath.addLine(to: point)
                }
                let previous = screenPoints[screenPoints.count - 2]
                tangent = CGVector(
                    dx: screenEnd.x - previous.x,
                    dy: screenEnd.y - previous.y
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
                with: .color(theme.line),
                style: StrokeStyle(lineWidth: edgeLineWidth, lineCap: .round)
            )
        }
        if !sourcePath.isEmpty {
            context.fill(sourcePath, with: .color(theme.arrow.opacity(0.82)))
        }
        if !headPath.isEmpty {
            context.fill(headPath, with: .color(theme.arrow))
        }
    }

    private func appendSourceMarker(at point: CGPoint, into path: inout Path) {
        let diameter = edgeSourceMarkerRadius * 2
        path.addEllipse(in: CGRect(
            x: point.x - edgeSourceMarkerRadius,
            y: point.y - edgeSourceMarkerRadius,
            width: diameter,
            height: diameter
        ))
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
        theme: KnowledgeGraphVisualTheme,
        context: inout GraphicsContext
    ) {
        for edge in layout.compoundGraph.edges {
            guard
                let position = layout.edgeLabelPositions[edge.id],
                let route = layout.edgeRoutes[edge.id]
            else { continue }
            let screenPos = viewport.canvasToScreen(position)
            guard visibleRect.contains(screenPos) else { continue }

            let resolved = context.resolve(
                Text(edge.predicate)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.muted)
            )
            let textSize = resolved.measure(in: CGSize(width: 180, height: 60))
            let bgRect = CGRect(
                x: screenPos.x - textSize.width / 2 - edgeLabelHorizontalPadding,
                y: screenPos.y - textSize.height / 2 - edgeLabelVerticalPadding,
                width: textSize.width + edgeLabelHorizontalPadding * 2,
                height: textSize.height + edgeLabelVerticalPadding * 2
            )
            let labelPath = Path(roundedRect: bgRect, cornerRadius: edgeLabelCornerRadius)
            context.fill(labelPath, with: .color(theme.edgeLabelFill))
            drawEdgeLabelGuide(
                in: bgRect,
                axis: edgeLabelAxis(route: route, labelPosition: position),
                theme: theme,
                context: &context
            )
            context.stroke(
                labelPath,
                with: .color(theme.edgeLabelStroke),
                lineWidth: 1
            )
            context.draw(resolved, at: screenPos, anchor: .center)
        }
    }

    private enum EdgeLabelAxis {
        case horizontal
        case vertical
    }

    private func drawEdgeLabelGuide(
        in rect: CGRect,
        axis: EdgeLabelAxis,
        theme: KnowledgeGraphVisualTheme,
        context: inout GraphicsContext
    ) {
        var path = Path()
        switch axis {
        case .horizontal:
            path.move(to: CGPoint(x: rect.minX + edgeLabelGuideInset, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - edgeLabelGuideInset, y: rect.midY))
        case .vertical:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + edgeLabelGuideInset))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - edgeLabelGuideInset))
        }
        context.stroke(
            path,
            with: .color(theme.line.opacity(0.9)),
            style: StrokeStyle(lineWidth: edgeLineWidth, lineCap: .round)
        )
    }

    private func edgeLabelAxis(
        route: KnowledgeGraphLayout.EdgeRoute,
        labelPosition: CGPoint
    ) -> EdgeLabelAxis {
        let points = route.points.isEmpty ? [route.start, route.end] : route.points
        guard points.count > 1 else { return .horizontal }

        var bestAxis = EdgeLabelAxis.horizontal
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for offset in 1..<points.count {
            let start = points[offset - 1]
            let end = points[offset]
            let distance = labelDistance(labelPosition, toSegmentStart: start, end: end)
            guard distance < bestDistance else { continue }
            bestDistance = distance
            bestAxis = abs(end.x - start.x) >= abs(end.y - start.y) ? .horizontal : .vertical
        }
        return bestAxis
    }

    private func labelDistance(
        _ point: CGPoint,
        toSegmentStart start: CGPoint,
        end: CGPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.001 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let rawT = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let t = min(1, max(0, rawT))
        let projection = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    // MARK: - Drawing — groups

    /// Draw each group as a rounded outline with an internal header. The fill
    /// uses `GroupStyle.opacity` so two overlapping groups produce a darker
    /// intersection automatically (F7). Cards are drawn afterwards by
    /// `drawCards`, so groups always sit behind their members.
    private func drawGroups(
        layout: KnowledgeGraphLayout.Result,
        renderInfos: [GroupRenderInfo],
        viewport: KnowledgeGraphViewport,
        visibleRect: CGRect,
        context: inout GraphicsContext
    ) {
        for info in renderInfos {
            // computeGroupBoundingBoxes emits a rect for every group in
            // compoundGraph.groups; a missing entry is a pipeline desync.
            guard let bbox = layout.groupBoundingBoxes[info.group.id] else {
                preconditionFailure("Group \(info.group.id) missing bounding box")
            }
            let screenOrigin = viewport.canvasToScreen(bbox.origin)
            let screenRect = CGRect(
                x: screenOrigin.x,
                y: screenOrigin.y,
                width: bbox.width * viewport.zoom,
                height: bbox.height * viewport.zoom
            )
            guard visibleRect.intersects(screenRect) else { continue }

            let style = info.group.style
            let scaledRadius = style.cornerRadius * viewport.zoom
            let rounded = Path(roundedRect: screenRect, cornerRadius: scaledRadius)
            let headerHeight = CardSizing.headerHeight * viewport.zoom
            let headerBottomY = min(screenRect.maxY, screenRect.minY + headerHeight)

            context.fill(rounded, with: .color(info.fillColor))

            switch style.outline {
            case .none:
                break
            case .solid:
                context.stroke(
                    rounded,
                    with: .color(info.strokeColor),
                    style: StrokeStyle(lineWidth: 1.2)
                )
            case .dashed:
                context.stroke(
                    rounded,
                    with: .color(info.strokeColor),
                    style: StrokeStyle(
                        lineWidth: 1.2,
                        lineCap: .round,
                        dash: [6, 4]
                    )
                )
            }

            var separatorPath = Path()
            separatorPath.move(to: CGPoint(x: screenRect.minX, y: headerBottomY))
            separatorPath.addLine(to: CGPoint(x: screenRect.maxX, y: headerBottomY))
            context.stroke(separatorPath, with: .color(info.strokeColor), lineWidth: 0.8)

            var labelContext = context
            labelContext.translateBy(x: screenRect.minX, y: screenRect.minY)
            labelContext.scaleBy(x: viewport.zoom, y: viewport.zoom)
            let labelClipRect = CGRect(
                x: CardSizing.horizontalPad,
                y: 0,
                width: max(1, bbox.width - CardSizing.horizontalPad * 2),
                height: CardSizing.headerHeight
            )
            labelContext.clip(to: Path(labelClipRect))
            labelContext.draw(
                context.resolve(info.labelText),
                at: CGPoint(x: CardSizing.horizontalPad, y: CardSizing.headerHeight / 2),
                anchor: .leading
            )
        }
    }

    /// Per-group SwiftUI values that depend only on the layout snapshot
    /// (label, tint, opacity) — i.e. everything except viewport-dependent
    /// geometry. Precomputed once per layout invalidation so the Canvas hot
    /// path no longer re-constructs `Text` and `Color` values per frame.
    struct GroupRenderInfo {
        let group: CompoundGraph.Group
        let labelText: Text
        let fillColor: Color
        let strokeColor: Color
    }

    private func makeGroupRenderInfos(
        layout: KnowledgeGraphLayout.Result,
        theme: KnowledgeGraphVisualTheme
    ) -> [GroupRenderInfo] {
        layout.compoundGraph.groups.enumerated().map { groupIndex, group in
            let style = group.style
            let baseColor = KnowledgeGraphGroupPalette.color(
                for: style.tint,
                groupIndex: groupIndex
            )
            return GroupRenderInfo(
                group: group,
                labelText: Text(compactGroupLabel(group.label))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(baseColor.opacity(min(max(style.opacity * 6.0, 0.72), 0.98))),
                fillColor: baseColor.opacity(style.opacity),
                strokeColor: baseColor.opacity(min(style.opacity * 3.0, 0.9))
            )
        }
    }

    private func compactGroupLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > groupLabelMaximumCharacters else {
            return trimmed
        }
        let prefix = trimmed.prefix(32)
        let suffix = trimmed.suffix(12)
        return "\(prefix)...\(suffix)"
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

    // MARK: - Hover detail popup

    @ViewBuilder
    private func hoveredNodeDetailPopup(
        layout: KnowledgeGraphLayout.Result,
        theme: KnowledgeGraphVisualTheme
    ) -> some View {
        if
            let hoveredCardID,
            let card = layout.compoundGraph.cardByID[hoveredCardID],
            let origin = popupOrigin(for: hoveredCardID, layout: layout, viewport: effectiveViewport)
        {
            KnowledgeGraphNodeDetailPopup(card: card, theme: theme)
                .frame(width: nodeDetailPopupWidth, alignment: .topLeading)
                .offset(x: origin.x, y: origin.y)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                .allowsHitTesting(false)
        }
    }

    private func cardID(
        at screenPoint: CGPoint,
        layout: KnowledgeGraphLayout.Result,
        viewport: KnowledgeGraphViewport
    ) -> CompoundGraph.Card.ID? {
        let canvasPoint = viewport.screenToCanvas(screenPoint)
        for card in layout.compoundGraph.cards.reversed() {
            guard let origin = layout.cardPositions[card.id] else { continue }
            let rect = CGRect(origin: origin, size: card.size)
            if rect.contains(canvasPoint) {
                return card.id
            }
        }
        return nil
    }

    private func popupOrigin(
        for cardID: CompoundGraph.Card.ID,
        layout: KnowledgeGraphLayout.Result,
        viewport: KnowledgeGraphViewport
    ) -> CGPoint? {
        guard
            let origin = layout.cardPositions[cardID],
            let card = layout.compoundGraph.cardByID[cardID]
        else { return nil }
        let screenOrigin = viewport.canvasToScreen(origin)
        let cardRect = CGRect(
            x: screenOrigin.x,
            y: screenOrigin.y,
            width: card.size.width * viewport.zoom,
            height: card.size.height * viewport.zoom
        )
        let rightOriginX = cardRect.maxX + nodeDetailPopupGap
        let leftOriginX = cardRect.minX - nodeDetailPopupWidth - nodeDetailPopupGap
        let x = rightOriginX + nodeDetailPopupWidth <= viewportSize.width - nodeDetailPopupViewportInset
            ? rightOriginX
            : max(nodeDetailPopupViewportInset, leftOriginX)
        let preferredY = cardRect.minY
        let maxY = max(
            nodeDetailPopupViewportInset,
            viewportSize.height - nodeDetailPopupEstimatedHeight - nodeDetailPopupViewportInset
        )
        let y = min(max(preferredY, nodeDetailPopupViewportInset), maxY)
        return CGPoint(x: x, y: y)
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($liveDragTranslation) { value, state, _ in
                state = value.translation
                hoveredCardID = nil
            }
            .onEnded { value in
                committedViewport.offset.x += value.translation.width
                committedViewport.offset.y += value.translation.height
                hoveredCardID = nil
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
        let strategy = groupingStrategy
        let task = Task.detached(priority: .userInitiated) {
            KnowledgeGraphLayout.compute(graph: snapshot, initial: initial, groupingStrategy: strategy)
        }
        layoutTask = Task { @MainActor in
            let result = await task.value
            if Task.isCancelled { return }
            self.layout = result
        }
    }
}

// MARK: - Previews
//
// Preview coverage is organised in four bands so a reviewer can visually
// confirm each guarantee in `Specs/Grouping.Goal.md` without reading code:
//
//   1. `.namedGraphs` via TriG parser (B1, B2, F1, F8)
//   2. `.byType` / `.byNamespace` / `.explicit` via JSON-LD or hand-built
//      graphs (B3–B7), because the Turtle / TriG parsers do not populate
//      `Node.types` or `graph.namespaces`.
//   3. `.combined` showing strategy union with deduplication (B8, B9)
//   4. `GroupStyle` variations covering outline / opacity / tint (F2–F7)
//      and `.none` as a no-grouping baseline.

/// Parse a fixture payload for use in `#Preview`. The payload is authored
/// alongside the preview, so a parse failure is a programmer error in the
/// fixture itself — crash explicitly rather than show an empty graph so the
/// regression is impossible to miss in development. Preview-only code never
/// ships in release builds (Xcode strips `#Preview`), so the `fatalError` has
/// no production blast radius.
private func previewGraph(
    _ payload: String,
    format: KnowledgeGraphFormat,
    scope: String
) -> KnowledgeGraph {
    do {
        return try format.parse(payload, scope: scope, baseIRI: nil)
    } catch {
        fatalError("preview parse failure (\(scope)): \(error)")
    }
}

// MARK: Band 1 — namedGraphs via TriG

#Preview("namedGraphs — two disjoint named graphs") {
    KnowledgeGraphView(
        graph: previewGraph(
            """
            @prefix ex: <http://example.org/> .
            ex:g1 {
                ex:alice ex:knows ex:bob .
                ex:bob ex:knows ex:carol .
                ex:alice ex:knows ex:carol .
            }
            ex:g2 {
                ex:dave ex:knows ex:eve .
                ex:eve ex:knows ex:frank .
                ex:dave ex:knows ex:frank .
            }
            """,
            format: .trig,
            scope: "preview-two-disjoint"
        ),
        groupingStrategy: .namedGraphs()
    )
    .frame(width: 640, height: 480)
}

#Preview("namedGraphs — two graphs bridged by a third") {
    KnowledgeGraphView(
        graph: previewGraph(
            """
            @prefix ex: <http://example.org/> .
            ex:g1 {
                ex:alice ex:knows ex:bob .
                ex:bob ex:knows ex:carol .
            }
            ex:g2 {
                ex:carol ex:knows ex:dave .
                ex:dave ex:knows ex:eve .
            }
            ex:bridge {
                ex:carol ex:bridge ex:dave .
            }
            """,
            format: .trig,
            scope: "preview-two-connected"
        ),
        groupingStrategy: .namedGraphs()
    )
    .frame(width: 640, height: 480)
}

#Preview("namedGraphs — single large team") {
    KnowledgeGraphView(
        graph: previewGraph(
            """
            @prefix ex: <http://example.org/> .
            ex:team {
                ex:alice ex:knows ex:bob .
                ex:bob ex:knows ex:carol .
                ex:carol ex:knows ex:dave .
                ex:dave ex:knows ex:eve .
                ex:eve ex:knows ex:frank .
                ex:frank ex:knows ex:grace .
                ex:grace ex:knows ex:henry .
                ex:alice ex:knows ex:henry .
            }
            """,
            format: .trig,
            scope: "preview-single-large"
        ),
        groupingStrategy: .namedGraphs()
    )
    .frame(width: 640, height: 480)
}

#Preview("namedGraphs — literal-folded subjects survive") {
    // All *objects* fold into attributes on their subject cards (ex:alice,
    // ex:bob), but the IRI subjects themselves still belong to the named
    // graph. The group survives with 2 members and the literal values
    // appear inline on each card.
    KnowledgeGraphView(
        graph: previewGraph(
            """
            @prefix ex:   <http://example.org/> .
            @prefix foaf: <http://xmlns.com/foaf/0.1/> .
            ex:facts {
                ex:alice foaf:name "Alice" .
                ex:bob foaf:name "Bob" .
            }
            """,
            format: .trig,
            scope: "preview-literal-only"
        ),
        groupingStrategy: .namedGraphs()
    )
    .frame(width: 640, height: 480)
}

// MARK: Band 2 — byType / byNamespace / explicit

#Preview("byType — three disjoint type groups (JSON-LD)") {
    // JSON-LD is the only format the parser stack populates `Node.types` for,
    // so it is the canonical way to exercise `.byType` end-to-end. Three
    // disjoint type buckets exercise palette assignment across more than the
    // two-color minimum, which is what F5 ("auto picks distinguishable
    // colors") relies on.
    KnowledgeGraphView(
        graph: previewGraph(
            """
            {
              "@graph": [
                {"@id": "http://example.org/alice",
                 "@type": "http://xmlns.com/foaf/0.1/Person",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/bob"}},
                {"@id": "http://example.org/bob",
                 "@type": "http://xmlns.com/foaf/0.1/Person",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/carol"}},
                {"@id": "http://example.org/carol",
                 "@type": "http://xmlns.com/foaf/0.1/Person"},

                {"@id": "http://example.org/acme",
                 "@type": "http://example.org/Company"},
                {"@id": "http://example.org/globex",
                 "@type": "http://example.org/Company"},

                {"@id": "http://example.org/laptop",
                 "@type": "http://example.org/Device"},
                {"@id": "http://example.org/phone",
                 "@type": "http://example.org/Device"},
                {"@id": "http://example.org/tablet",
                 "@type": "http://example.org/Device"},

                {"@id": "http://example.org/alice",
                 "http://example.org/worksAt": {"@id": "http://example.org/acme"}},
                {"@id": "http://example.org/bob",
                 "http://example.org/worksAt": {"@id": "http://example.org/globex"}},
                {"@id": "http://example.org/carol",
                 "http://example.org/owns": {"@id": "http://example.org/laptop"}},
                {"@id": "http://example.org/bob",
                 "http://example.org/owns": {"@id": "http://example.org/phone"}},
                {"@id": "http://example.org/alice",
                 "http://example.org/owns": {"@id": "http://example.org/tablet"}}
              ]
            }
            """,
            format: .jsonLD,
            scope: "preview-by-type-mixed"
        ),
        groupingStrategy: .byType()
    )
    .frame(width: 640, height: 480)
}

#Preview("byType — overlapping multi-typed nodes (JSON-LD)") {
    // `ex:bob` belongs to three type buckets simultaneously — F7 says the
    // intersection darkens because each group is rendered with `opacity ≈
    // 0.12`, so two overlapping fills sum to ~0.24 and three to ~0.34.
    KnowledgeGraphView(
        graph: previewGraph(
            """
            {
              "@graph": [
                {"@id": "http://example.org/alice",
                 "@type": ["http://xmlns.com/foaf/0.1/Person",
                           "http://example.org/Employee"]},
                {"@id": "http://example.org/bob",
                 "@type": ["http://xmlns.com/foaf/0.1/Person",
                           "http://example.org/Employee",
                           "http://example.org/Manager"]},
                {"@id": "http://example.org/carol",
                 "@type": ["http://xmlns.com/foaf/0.1/Person",
                           "http://example.org/Manager"]},
                {"@id": "http://example.org/dave",
                 "@type": "http://xmlns.com/foaf/0.1/Person"},
                {"@id": "http://example.org/eve",
                 "@type": "http://example.org/Employee"},

                {"@id": "http://example.org/alice",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/bob"}},
                {"@id": "http://example.org/bob",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/carol"}},
                {"@id": "http://example.org/carol",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/dave"}},
                {"@id": "http://example.org/dave",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/eve"}},
                {"@id": "http://example.org/eve",
                 "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/alice"}}
              ]
            }
            """,
            format: .jsonLD,
            scope: "preview-by-type-multi"
        ),
        groupingStrategy: .byType()
    )
    .frame(width: 640, height: 480)
}

#Preview("byNamespace — longest-prefix wins") {
    // No RDF parser populates `graph.namespaces`, so the only way to
    // exercise `.byNamespace` is to hand-build a `KnowledgeGraph` with
    // `Namespace` entries. `orgHR` is intentionally a sub-prefix of `org`;
    // members of the longer prefix must NOT also appear under the shorter
    // one (B6).
    KnowledgeGraphView(
        graph: byNamespaceFixtureGraph(),
        groupingStrategy: .byNamespace()
    )
    .frame(width: 640, height: 480)
}

#Preview("explicit — caller-supplied groups with custom labels") {
    // `.explicit` is the only strategy whose membership the caller supplies
    // directly. Two hand-picked groups demonstrate F5 (auto tint by index)
    // and F8 (label is rendered in the internal group header).
    let graph = explicitFixtureGraph()
    let alice = NodeIdentifier.iri("http://example.org/alice")
    let bob = NodeIdentifier.iri("http://example.org/bob")
    let carol = NodeIdentifier.iri("http://example.org/carol")
    let dave = NodeIdentifier.iri("http://example.org/dave")
    let eve = NodeIdentifier.iri("http://example.org/eve")
    return KnowledgeGraphView(
        graph: graph,
        groupingStrategy: .explicit(groups: [
            GroupingStrategy.ExplicitGroup(
                id: "core-team",
                label: "Core team",
                memberNodeIDs: [alice, bob, carol]
            ),
            GroupingStrategy.ExplicitGroup(
                id: "advisors",
                label: "Advisors",
                memberNodeIDs: [dave, eve]
            )
        ])
    )
    .frame(width: 640, height: 480)
}

// MARK: Band 3 — combined

#Preview("combined — namedGraphs + byType (JSON-LD nested @graph)") {
    // Nested @graph blocks produce both NamedGraph entries AND per-node
    // `types` — so the combined strategy's union shows both `namedGraph:`
    // and `type:` groups overlapping. Dedup (B9) ensures a group whose
    // (label, sorted-members) tuple already appeared is dropped.
    KnowledgeGraphView(
        graph: previewGraph(
            """
            {
              "@graph": [
                {"@id": "http://example.org/engineering",
                 "@graph": [
                   {"@id": "http://example.org/alice",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Engineer"],
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/bob"}},
                   {"@id": "http://example.org/bob",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Engineer"]}
                 ]},
                {"@id": "http://example.org/sales",
                 "@graph": [
                   {"@id": "http://example.org/carol",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Salesperson"],
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/dave"}},
                   {"@id": "http://example.org/dave",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Salesperson"]}
                 ]},
                {"@id": "http://example.org/management",
                 "@graph": [
                   {"@id": "http://example.org/eve",
                    "@type": ["http://xmlns.com/foaf/0.1/Person",
                              "http://example.org/Manager"],
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/alice"}},
                   {"@id": "http://example.org/eve",
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://example.org/carol"}}
                 ]}
              ]
            }
            """,
            format: .jsonLD,
            scope: "preview-combined"
        ),
        groupingStrategy: .combined(strategies: [.namedGraphs(), .byType()])
    )
    .frame(width: 640, height: 480)
}

// MARK: Band 4 — GroupStyle variations & `.none`

#Preview("style — outline solid") {
    KnowledgeGraphView(
        graph: stylePreviewGraph(),
        groupingStrategy: .namedGraphs(
            style: GroupStyle(opacity: 0.14, outline: .solid)
        )
    )
    .frame(width: 640, height: 480)
}

#Preview("style — outline dashed (default)") {
    KnowledgeGraphView(
        graph: stylePreviewGraph(),
        groupingStrategy: .namedGraphs(
            style: GroupStyle(opacity: 0.14, outline: .dashed)
        )
    )
    .frame(width: 640, height: 480)
}

#Preview("style — outline none, opacity 0.25") {
    // F4 + F2: removing the dashed border and bumping opacity makes the
    // fill carry the group affordance on its own.
    KnowledgeGraphView(
        graph: stylePreviewGraph(),
        groupingStrategy: .namedGraphs(
            style: GroupStyle(opacity: 0.25, outline: .none)
        )
    )
    .frame(width: 640, height: 480)
}

#Preview("style — tint .palette(n) shared across groups") {
    // F6: two groups passing `.palette(0)` paint with the *same* hue,
    // distinguishing them only by position. Useful when groups represent
    // the same logical category (e.g. "current iteration").
    KnowledgeGraphView(
        graph: stylePreviewGraph(),
        groupingStrategy: .namedGraphs(
            style: GroupStyle(opacity: 0.18, tint: .palette(2))
        )
    )
    .frame(width: 640, height: 480)
}

#Preview("strategy — .none baseline (no grouping)") {
    // The same fixture as the style previews, rendered without any group
    // overlay. Useful as the "before" comparison for the band-4 previews.
    KnowledgeGraphView(
        graph: stylePreviewGraph(),
        groupingStrategy: .none
    )
    .frame(width: 640, height: 480)
}

// MARK: - Preview helpers — hand-built graphs

/// Two clusters connected by a single bridge edge. Reused across the
/// band-4 style previews so a reviewer can compare outline / tint changes
/// against a fixed topology.
private func stylePreviewGraph() -> KnowledgeGraph {
    do {
        return try KnowledgeGraphFormat.trig.parse(
            """
            @prefix ex: <http://example.org/> .
            ex:left {
                ex:alice ex:knows ex:bob .
                ex:bob ex:knows ex:carol .
                ex:alice ex:knows ex:carol .
            }
            ex:right {
                ex:dave ex:knows ex:eve .
                ex:eve ex:knows ex:frank .
                ex:dave ex:knows ex:frank .
            }
            ex:bridge {
                ex:carol ex:bridge ex:dave .
            }
            """,
            scope: "preview-style-shared",
            baseIRI: nil
        )
    } catch {
        fatalError("style preview graph failed to parse: \(error)")
    }
}

/// Hand-built graph for the `.byNamespace` preview. Parsers do not
/// populate `graph.namespaces`, so the preview constructs the
/// `Namespace` entries directly. `org/hr/` (orgHR) is a sub-prefix of
/// `org/` to demonstrate the longest-prefix rule (B6).
private func byNamespaceFixtureGraph() -> KnowledgeGraph {
    let alice = NodeIdentifier.iri("http://example.org/alice")
    let bob = NodeIdentifier.iri("http://example.org/bob")
    let carol = NodeIdentifier.iri("http://example.org/carol")
    let engineering = NodeIdentifier.iri("http://example.org/org/engineering")
    let sales = NodeIdentifier.iri("http://example.org/org/sales")
    let recruiting = NodeIdentifier.iri("http://example.org/org/hr/recruiting")
    let payroll = NodeIdentifier.iri("http://example.org/org/hr/payroll")
    let widget = NodeIdentifier.iri("http://example.org/product/widget")
    let gadget = NodeIdentifier.iri("http://example.org/product/gadget")

    let nodes = [alice, bob, carol, engineering, sales, recruiting, payroll, widget, gadget]
        .map { Node(id: $0) }

    let knows = "http://xmlns.com/foaf/0.1/knows"
    let memberOf = "http://example.org/memberOf"
    let builds = "http://example.org/builds"
    let reviews = "http://example.org/reviews"
    let edges = [
        Edge(id: EdgeIdentifier(source: alice, predicate: knows, target: bob)),
        Edge(id: EdgeIdentifier(source: bob, predicate: knows, target: carol)),
        Edge(id: EdgeIdentifier(source: alice, predicate: memberOf, target: engineering)),
        Edge(id: EdgeIdentifier(source: bob, predicate: memberOf, target: recruiting)),
        Edge(id: EdgeIdentifier(source: carol, predicate: memberOf, target: sales)),
        Edge(id: EdgeIdentifier(source: alice, predicate: builds, target: widget)),
        Edge(id: EdgeIdentifier(source: bob, predicate: reviews, target: gadget)),
        Edge(id: EdgeIdentifier(source: carol, predicate: memberOf, target: payroll))
    ]
    return KnowledgeGraph(
        nodes: nodes,
        edges: edges,
        namespaces: [
            Namespace(prefix: "foaf", uri: "http://xmlns.com/foaf/0.1/"),
            Namespace(prefix: "org", uri: "http://example.org/org/"),
            Namespace(prefix: "orgHR", uri: "http://example.org/org/hr/"),
            Namespace(prefix: "prod", uri: "http://example.org/product/")
        ]
    )
}

/// Hand-built graph for the `.explicit` preview. Five IRIs forming a
/// star around `ex:bob` so each explicit group has a clear visual centre.
private func explicitFixtureGraph() -> KnowledgeGraph {
    let alice = NodeIdentifier.iri("http://example.org/alice")
    let bob = NodeIdentifier.iri("http://example.org/bob")
    let carol = NodeIdentifier.iri("http://example.org/carol")
    let dave = NodeIdentifier.iri("http://example.org/dave")
    let eve = NodeIdentifier.iri("http://example.org/eve")
    let knows = "http://xmlns.com/foaf/0.1/knows"
    return KnowledgeGraph(
        nodes: [alice, bob, carol, dave, eve].map { Node(id: $0) },
        edges: [
            Edge(id: EdgeIdentifier(source: alice, predicate: knows, target: bob)),
            Edge(id: EdgeIdentifier(source: carol, predicate: knows, target: bob)),
            Edge(id: EdgeIdentifier(source: bob, predicate: knows, target: dave)),
            Edge(id: EdgeIdentifier(source: bob, predicate: knows, target: eve)),
            Edge(id: EdgeIdentifier(source: dave, predicate: knows, target: eve))
        ]
    )
}
