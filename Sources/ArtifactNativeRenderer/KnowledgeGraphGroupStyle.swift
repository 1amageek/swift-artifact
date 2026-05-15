import Foundation
import CoreGraphics

/// IR-pure visual specification for a `CompoundGraph.Group`.
///
/// Stays inside the layout layer (no SwiftUI dependency) so layout-side
/// code can reason about cohesion / bbox padding without importing the
/// renderer's color palette. The `tint` field carries an *index* into a
/// palette that the renderer resolves to a concrete color — colors are
/// SwiftUI-specific and therefore deliberately not represented here.
struct GroupStyle: Sendable, Hashable {

    /// How the group's fill color is chosen.
    enum Tint: Sendable, Hashable {
        /// Renderer derives the color from the group's positional index.
        /// Identical inputs produce identical colors across runs.
        case auto
        /// Renderer picks `palette[index % palette.count]`. Multiple groups
        /// with the same index share a color.
        case palette(Int)
    }

    /// How the group's border is drawn.
    enum Outline: Sendable, Hashable {
        case solid
        case dashed
        case none
    }

    /// Fill opacity in `[0, 1]`. Applied to the resolved tint color.
    let opacity: Double
    /// Padding (points) around the bounding box of the group's members.
    let padding: CGFloat
    /// Corner radius for the group rectangle, in points.
    let cornerRadius: CGFloat
    let tint: Tint
    let outline: Outline

    init(
        opacity: Double = 0.12,
        padding: CGFloat = 24,
        cornerRadius: CGFloat = 18,
        tint: Tint = .auto,
        outline: Outline = .dashed
    ) {
        self.opacity = opacity
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.outline = outline
    }

    static let `default` = GroupStyle()
}
