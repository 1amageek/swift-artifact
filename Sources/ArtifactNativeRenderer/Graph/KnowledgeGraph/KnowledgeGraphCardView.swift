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
    let theme: KnowledgeGraphVisualTheme
    var presentationStyle = KnowledgeGraphCardStyle()

    var body: some View {
        VStack(spacing: 0) {
            header
            if !card.attributes.isEmpty {
                Divider()
                    .overlay(theme.innerStroke)
                attributesList
            }
        }
        .frame(width: card.size.width, height: card.size.height, alignment: .topLeading)
        .background(cardBackground)
        .clipShape(cardClipShape)
        .overlay(border)
        .shadow(color: theme.cardShadow, radius: 5, x: 0, y: 2)
        .help(card.qualifiedTitle)
        .opacity(presentationStyle.opacity ?? 1.0)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: headerIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
            Text(card.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(presentationStyle.text ?? theme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
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
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Text(attribute.value)
                    .font(.system(size: 11))
                    .foregroundStyle(presentationStyle.text ?? theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let qualifier = attribute.valueQualifier {
                    Text(qualifier)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.muted.opacity(0.78))
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

    private var accent: Color {
        theme.cardAccent(for: card.kind)
    }

    private var headerBackground: Color {
        accent.opacity(theme.cardHeaderOpacity)
    }

    private var cardBackground: Color {
        presentationStyle.fill ?? theme.surfaceRaised
    }

    @ViewBuilder
    private var border: some View {
        let stroke = presentationStyle.stroke
        let lineWidth = presentationStyle.strokeWidth ?? 1
        let line = presentationStyle.strokeLine
        switch card.kind {
        case .resource(.blank):
            cardBorderShape
                .strokeBorder(
                    stroke ?? accent.opacity(0.58),
                    style: line.map { StrokeStyle(lineWidth: lineWidth, line: $0) }
                        ?? StrokeStyle(lineWidth: lineWidth, dash: [3, 3])
                )
        default:
            cardBorderShape
                .strokeBorder(
                    stroke ?? theme.border,
                    style: StrokeStyle(lineWidth: lineWidth, line: line)
                )
        }
    }

    private var cardClipShape: AnyShape {
        AnyShape(CardPresentationShape(shape: presentationStyle.shape))
    }

    private var cardBorderShape: AnyInsettableShape {
        AnyInsettableShape(CardPresentationShape(shape: presentationStyle.shape))
    }
}

private struct CardPresentationShape: InsettableShape {
    var shape: GraphShape?
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        switch shape {
        case .rectangle:
            return Path(rect)
        case .roundedRectangle(let radius):
            return Path(roundedRect: rect, cornerRadius: radius.map { CGFloat($0) } ?? 10)
        case .capsule:
            return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2)
        case .ellipse:
            return Path(ellipseIn: rect)
        case .none:
            return Path(roundedRect: rect, cornerRadius: 10)
        }
    }

    func inset(by amount: CGFloat) -> CardPresentationShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

private struct AnyShape: Shape {
    private let pathBuilder: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        self.pathBuilder = { shape.path(in: $0) }
    }

    func path(in rect: CGRect) -> Path {
        pathBuilder(rect)
    }
}

private struct AnyInsettableShape: InsettableShape {
    private let pathBuilder: @Sendable (CGRect) -> Path
    private let insetBuilder: @Sendable (CGFloat) -> AnyInsettableShape

    init<S: InsettableShape>(_ shape: S) {
        self.pathBuilder = { shape.path(in: $0) }
        self.insetBuilder = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    func path(in rect: CGRect) -> Path {
        pathBuilder(rect)
    }

    func inset(by amount: CGFloat) -> AnyInsettableShape {
        insetBuilder(amount)
    }
}
