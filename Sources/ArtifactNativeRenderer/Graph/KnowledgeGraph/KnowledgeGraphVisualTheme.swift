import SwiftUI

struct KnowledgeGraphVisualTheme {
    let background: Color
    let foreground: Color
    let muted: Color
    let line: Color
    let arrow: Color
    let surfaceRaised: Color
    let border: Color
    let innerStroke: Color
    let edgeLabelFill: Color
    let edgeLabelStroke: Color
    let cardShadow: Color
    let groupLabelFill: Color
    let cardHeaderOpacity: Double

    init(colorScheme: ColorScheme) {
        switch colorScheme {
        case .dark:
            background = Color(red: 0.08, green: 0.085, blue: 0.10)
            foreground = Color(red: 0.94, green: 0.95, blue: 0.97)
            muted = Color(red: 0.66, green: 0.69, blue: 0.75)
            line = Color(red: 0.48, green: 0.53, blue: 0.62).opacity(0.72)
            arrow = Color(red: 0.70, green: 0.74, blue: 0.82)
            surfaceRaised = Color(red: 0.145, green: 0.155, blue: 0.19)
            border = Color.white.opacity(0.12)
            innerStroke = Color.white.opacity(0.08)
            edgeLabelFill = Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.94)
            edgeLabelStroke = Color.white.opacity(0.10)
            cardShadow = Color.black.opacity(0.24)
            groupLabelFill = Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.90)
            cardHeaderOpacity = 0.20
        default:
            background = Color(red: 0.98, green: 0.985, blue: 0.99)
            foreground = Color(red: 0.12, green: 0.13, blue: 0.16)
            muted = Color(red: 0.43, green: 0.46, blue: 0.52)
            line = Color(red: 0.47, green: 0.51, blue: 0.58).opacity(0.78)
            arrow = Color(red: 0.28, green: 0.32, blue: 0.40)
            surfaceRaised = Color.white
            border = Color(red: 0.80, green: 0.84, blue: 0.90)
            innerStroke = Color(red: 0.88, green: 0.90, blue: 0.94)
            edgeLabelFill = Color.white.opacity(0.96)
            edgeLabelStroke = Color(red: 0.80, green: 0.84, blue: 0.90).opacity(0.92)
            cardShadow = Color.black.opacity(0.10)
            groupLabelFill = Color.white.opacity(0.92)
            cardHeaderOpacity = 0.11
        }
    }

    func cardAccent(for kind: CompoundGraph.Card.Kind) -> Color {
        switch kind {
        case .resource(.iri):
            return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .resource(.blank):
            return Color(red: 0.55, green: 0.58, blue: 0.68)
        case .resource(.literal), .literal:
            return Color(red: 0.92, green: 0.51, blue: 0.16)
        }
    }
}
