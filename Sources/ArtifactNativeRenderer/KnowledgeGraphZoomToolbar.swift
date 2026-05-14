import SwiftUI

/// Floating pill that exposes zoom controls for a `KnowledgeGraphView`.
///
/// Three actions and a current-percentage readout are laid out in a compact
/// capsule that lives in the bottom-leading overlay of the graph viewport.
/// All button hit areas explicitly use `.contentShape(Rectangle())` because
/// `.plain` button style restricts hit-testing to the drawn glyph otherwise.
struct KnowledgeGraphZoomToolbar: View {

    let zoom: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void
    let onResetTo100: () -> Void
    let onFit: () -> Void

    private let buttonSide: CGFloat = 20

    var body: some View {
        HStack(spacing: 1) {
            controlButton(systemImage: "minus", help: "Zoom out", action: onZoomOut)
                .disabled(zoom <= minZoom + 0.0005)

            Button(action: onResetTo100) {
                Text(percentageLabel)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 34, minHeight: buttonSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reset to 100%")

            controlButton(systemImage: "plus", help: "Zoom in", action: onZoomIn)
                .disabled(zoom >= maxZoom - 0.0005)

            Divider()
                .frame(height: 12)
                .padding(.horizontal, 1)

            controlButton(
                systemImage: "arrow.up.left.and.down.right.magnifyingglass",
                help: "Fit to view",
                action: onFit
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
    }

    private var percentageLabel: String {
        "\(Int((zoom * 100).rounded()))%"
    }

    private func controlButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: buttonSide, height: buttonSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
