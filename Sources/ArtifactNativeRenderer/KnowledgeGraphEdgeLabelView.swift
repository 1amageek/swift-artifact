import SwiftUI

/// Pill-shaped edge label rendered as a real SwiftUI view so the text
/// inherits system font scaling and accessibility. Sits on top of the edge
/// canvas with `.allowsHitTesting(false)` so it never intercepts gestures.
struct KnowledgeGraphEdgeLabelView: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .fixedSize()
    }
}
