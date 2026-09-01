import SwiftUI
import Markdown
import MarkdownUI

struct MarkdownImageBlockView: View {
    private let blocks: [MarkdownRenderBlock]

    init(markdown: String) {
        blocks = MarkdownImageBlockParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                content(for: block)
            }
        }
    }

    @ViewBuilder
    private func content(for block: MarkdownRenderBlock) -> some View {
        switch block {
        case let .markdown(source):
            MarkdownView(source)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .image(url, alt):
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 96)
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 360)
                case .failure:
                    Label(alt.isEmpty ? url.absoluteString : alt, systemImage: "photo")
                        .foregroundStyle(.secondary)
                @unknown default:
                    EmptyView()
                }
            }
            .accessibilityLabel(alt)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum MarkdownRenderBlock: Sendable, Equatable {
    case markdown(source: String)
    case image(url: URL, alt: String)
}

enum MarkdownImageBlockParser {
    static func parse(_ markdown: String) -> [MarkdownRenderBlock] {
        let document = Document(parsing: markdown)
        var blocks: [MarkdownRenderBlock] = []
        var text = ""

        for child in document.children {
            if let image = image(in: child) {
                appendText(text, to: &blocks)
                text = ""
                blocks.append(.image(url: image.url, alt: image.alt))
            } else {
                let formatted = child.format().trimmingCharacters(in: .whitespacesAndNewlines)
                if !formatted.isEmpty {
                    if !text.isEmpty {
                        text += "\n\n"
                    }
                    text += formatted
                }
            }
        }

        appendText(text, to: &blocks)
        return blocks.isEmpty ? [.markdown(source: markdown)] : blocks
    }

    private static func image(in markup: Markup) -> (url: URL, alt: String)? {
        guard let paragraph = markup as? Paragraph,
              paragraph.childCount == 1,
              let image = paragraph.child(at: 0) as? Markdown.Image,
              let source = image.source,
              let url = URL(string: source) else {
            return nil
        }
        return (url, image.plainText)
    }

    private static func appendText(_ text: String, to blocks: inout [MarkdownRenderBlock]) {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        blocks.append(.markdown(source: source))
    }
}
