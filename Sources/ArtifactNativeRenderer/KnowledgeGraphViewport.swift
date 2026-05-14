import CoreGraphics

/// 2D affine viewport for the Knowledge Graph canvas.
///
/// Mirrors the swift-flow `Viewport` value semantics: a uniform `zoom`
/// combined with a screen-space `offset`. The forward transform converts
/// canvas (logical) coordinates to screen coordinates, the inverse goes the
/// other way. Both are pure functions of the two stored fields, which keeps
/// the renderer reproducible across snapshots.
///
/// Zoom-at-anchor (pinch / scroll-wheel zoom about a screen point) is a
/// derived operation — see `zoomed(by:anchor:)`. The formula keeps the screen
/// position of `anchor` fixed while the underlying canvas is rescaled.
struct KnowledgeGraphViewport: Sendable, Hashable {

    /// Screen-space translation applied **after** scaling.
    var offset: CGPoint
    /// Uniform scale factor; clamped to a positive value by callers.
    var zoom: CGFloat

    init(offset: CGPoint = .zero, zoom: CGFloat = 1.0) {
        self.offset = offset
        self.zoom = zoom
    }

    func canvasToScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * zoom + offset.x,
            y: point.y * zoom + offset.y
        )
    }

    func screenToCanvas(_ point: CGPoint) -> CGPoint {
        let safeZoom = max(zoom, 0.0001)
        return CGPoint(
            x: (point.x - offset.x) / safeZoom,
            y: (point.y - offset.y) / safeZoom
        )
    }

    /// Returns a new viewport whose `zoom` becomes `targetZoom`, with `offset`
    /// adjusted so the screen-space `anchor` point maps to the same canvas
    /// point as in the receiver.
    func zoomed(to targetZoom: CGFloat, anchor: CGPoint) -> KnowledgeGraphViewport {
        guard zoom > 0 else {
            return KnowledgeGraphViewport(offset: offset, zoom: targetZoom)
        }
        let scale = targetZoom / zoom
        let newOffset = CGPoint(
            x: anchor.x - (anchor.x - offset.x) * scale,
            y: anchor.y - (anchor.y - offset.y) * scale
        )
        return KnowledgeGraphViewport(offset: newOffset, zoom: targetZoom)
    }
}
