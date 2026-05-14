import SwiftUI
import KnowledgeGraph

/// SwiftUI rendering of a single `CompoundGraph.Card`.
///
/// The card is sized exactly to its precomputed `card.size` so layout
/// geometry (positions, edge anchors) matches what the user sees. Three
/// visual variants:
///   - **IRI resource**: accent-tinted header, attribute rows below.
///   - **Blank node**: same shape, dashed border, slightly desaturated header.
///   - **Shared literal**: orange header, no body.
struct KnowledgeGraphCardView: View {

    let card: CompoundGraph.Card

    var body: some View {
        VStack(spacing: 0) {
            header
            if !card.attributes.isEmpty {
                Divider()
                attributesList
            }
        }
        .frame(width: card.size.width, height: card.size.height, alignment: .topLeading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(border)
        .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
        .help(card.qualifiedTitle)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: headerIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(card.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, CardSizing.horizontalPad)
        .frame(height: CardSizing.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(headerBackground)
    }

    private var attributesList: some View {
        VStack(spacing: 0) {
            ForEach(card.attributes) { attribute in
                attributeRow(attribute)
                    .frame(height: CardSizing.rowHeight)
            }
        }
        .padding(.vertical, CardSizing.attributesVerticalPad)
        .padding(.horizontal, CardSizing.horizontalPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attributeRow(_ attribute: CompoundGraph.Card.Attribute) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(attribute.predicate)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Text(attribute.value)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let qualifier = attribute.valueQualifier {
                    Text(qualifier)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Style

    private var headerIcon: String {
        switch card.kind {
        case .resource(.iri): return "globe"
        case .resource(.blank): return "circle.dashed"
        case .resource(.literal): return "text.quote"
        case .literal: return "text.quote"
        }
    }

    private var headerBackground: Color {
        switch card.kind {
        case .resource(.iri): return Color.accentColor
        case .resource(.blank): return Color.accentColor.opacity(0.65)
        case .resource(.literal): return Color.orange.opacity(0.85)
        case .literal: return Color.orange.opacity(0.85)
        }
    }

    private var cardBackground: some ShapeStyle {
        Color(.sRGB, white: 0.16, opacity: 1.0).opacity(0.96)
    }

    @ViewBuilder
    private var border: some View {
        switch card.kind {
        case .resource(.blank):
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
        default:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        }
    }
}
