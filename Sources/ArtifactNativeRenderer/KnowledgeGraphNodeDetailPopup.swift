import SwiftUI

struct KnowledgeGraphNodeDetailPopup: View {

    let card: CompoundGraph.Card
    let theme: KnowledgeGraphVisualTheme

    private let maximumVisibleAttributes = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .overlay(theme.innerStroke)
            content
        }
        .background(theme.surfaceRaised.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .shadow(color: theme.cardShadow, radius: 14, x: 0, y: 8)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: headerIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kindLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(accent.opacity(theme.cardHeaderOpacity))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailRow(label: "Identifier", value: card.qualifiedTitle)
            if card.attributes.isEmpty {
                detailRow(label: "Attributes", value: "None")
            } else {
                attributesSection
            }
        }
        .padding(12)
    }

    private var attributesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Attributes")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.muted)
            ForEach(Array(card.attributes.prefix(maximumVisibleAttributes))) { attribute in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(attribute.predicate)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 92, alignment: .leading)
                    Text(attributeValue(attribute))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if card.attributes.count > maximumVisibleAttributes {
                Text("+\(card.attributes.count - maximumVisibleAttributes) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.muted)
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.muted)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(theme.foreground)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerIcon: String {
        switch card.kind {
        case .resource(.iri): return "globe"
        case .resource(.blank): return "circle.dashed"
        case .resource(.literal): return "text.quote"
        case .literal: return "text.quote"
        }
    }

    private var kindLabel: String {
        switch card.kind {
        case .resource(.iri): return "IRI resource"
        case .resource(.blank): return "Blank node"
        case .resource(.literal): return "Literal resource"
        case .literal: return "Shared literal"
        }
    }

    private var accent: Color {
        theme.cardAccent(for: card.kind)
    }

    private func attributeValue(_ attribute: CompoundGraph.Card.Attribute) -> String {
        guard let qualifier = attribute.valueQualifier else {
            return attribute.value
        }
        return "\(attribute.value) \(qualifier)"
    }
}
