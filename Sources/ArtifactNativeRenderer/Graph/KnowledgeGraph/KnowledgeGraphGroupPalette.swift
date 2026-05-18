import SwiftUI

/// SwiftUI bridge that resolves a `GroupStyle.Tint` to a concrete `Color`.
///
/// The grouping IR (`GroupStyle`) is SwiftUI-free so the layout layer can
/// reason about it without pulling in the framework. This file is the only
/// SwiftUI-aware entry point — it lives alongside the renderer, picks a
/// hue from a deterministic 8-color palette, and lets the canvas drawing
/// code stay short. Same `n` (or same group index for `.auto`) always
/// produces the same `Color`, which is what the F6 / F7 invariants rely
/// on.
enum KnowledgeGraphGroupPalette {

    /// Resolve the fill color for a group. `groupIndex` is the position of
    /// the group inside `CompoundGraph.groups` and is used only when the
    /// tint is `.auto`.
    static func color(for tint: GroupStyle.Tint, groupIndex: Int) -> Color {
        switch tint {
        case .auto:
            return palette[normalizedIndex(groupIndex)]
        case .palette(let value):
            return palette[normalizedIndex(value)]
        }
    }

    /// Eight evenly-spaced hues. We pick a saturation / brightness profile
    /// that reads well at low opacity (0.10–0.20) — pastel-ish hues so the
    /// underlying cards remain the focal element.
    private static let palette: [Color] = [
        Color(hue: 0.00 / 8, saturation: 0.55, brightness: 0.95), // warm red
        Color(hue: 1.00 / 8, saturation: 0.55, brightness: 0.95), // orange
        Color(hue: 2.00 / 8, saturation: 0.50, brightness: 0.90), // yellow-green
        Color(hue: 3.00 / 8, saturation: 0.55, brightness: 0.85), // green
        Color(hue: 4.00 / 8, saturation: 0.50, brightness: 0.90), // teal
        Color(hue: 5.00 / 8, saturation: 0.55, brightness: 0.95), // blue
        Color(hue: 6.00 / 8, saturation: 0.55, brightness: 0.95), // purple
        Color(hue: 7.00 / 8, saturation: 0.55, brightness: 0.95)  // magenta
    ]

    private static func normalizedIndex(_ raw: Int) -> Int {
        let count = palette.count
        let mod = raw % count
        return mod >= 0 ? mod : mod + count
    }
}
