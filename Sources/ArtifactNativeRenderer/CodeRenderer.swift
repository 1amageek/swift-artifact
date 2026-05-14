import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders source code in a monospaced, scrollable container.
///
/// No external highlighter is bundled — this MVP shows uncolored source. Hook a
/// real highlighter (Splash / Highlightr / tree-sitter) by replacing this
/// renderer in your application.
public struct CodeRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .code
    /// The code container provides its own gutter, padding, and language
    /// pill, so the card's default padding would stack as an outer margin.
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.payload.isEmpty {
            return .preRenderable(PreRenderableProgress(receivedCharacters: 0))
        }
        return .renderable(artifact.payload)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        let language = (artifact.attributes["language"]).flatMap { $0.isEmpty ? nil : $0 }

        // Layout strategy:
        // - Vertical-only `ScrollView` so the container's intrinsic
        //   vertical size equals the content's height. Combined with
        //   `.fixedSize(horizontal: false, vertical: true)` and
        //   `.frame(maxHeight: 360)`, the height hugs the content until
        //   it would exceed 360pt, then caps and starts scrolling.
        //   A horizontal+vertical scroll view would have proposed
        //   infinity on both axes and forced us to drive width with a
        //   `GeometryReader`, which is greedy on height and would always
        //   inflate the container to 360pt.
        // - `frame(maxWidth: .infinity, alignment: .topLeading)` on the
        //   `HStack` stretches the gutter+code row to the full viewport
        //   width and anchors it to the top-left corner; lines that
        //   exceed the viewport wrap rather than horizontally scroll.
        // - Gutter and source live in separate `Text` views so that
        //   `.textSelection(.enabled)` can be opt-in per view — the
        //   gutter omits it so the line numbers are not selectable and
        //   never participate in copy. Identical monospaced fonts give
        //   matching line heights, which keeps the two columns aligned
        //   row-by-row without any explicit layout pinning.
        // - The container uses `.glassEffect` (Liquid Glass) as its
        //   surface. The language pill is rendered in an overlay so it
        //   floats above the scrolling content and stays pinned to the
        //   top-right corner; the top padding of the code content is
        //   bumped only when a language is present so the first source
        //   line does not slide under the pill.
        return ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 12) {
                Text(Self.lineNumbers(for: payload))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)

                Text(payload)
                    .textSelection(.enabled)
            }
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
        .contentMargins(12)
        .overlay(alignment: .topTrailing) {
            if let language {
                Text(language)
                    .font(.caption2.weight(.medium))
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassEffect(in: Capsule())
                    .padding(8)
            }
        }
    }

    /// Minimum number of line-number rows always rendered, regardless of
    /// how short the source is. Reserves a stable visual height for the
    /// code surface — a 2-line snippet still shows the same card size as
    /// a 10-line snippet, and the gutter does not jitter as a stream
    /// crosses the 9 → 10 line boundary.
    private static let minimumGutterLineCount = 10

    /// Builds the gutter string: `" 1\n 2\n 3..."` with one entry per
    /// row, padded with leading spaces to the digit width of
    /// `max(contentLineCount, minimumGutterLineCount)`. The row count
    /// itself is also clamped to that minimum so that short or empty
    /// payloads still reserve the gutter — line numbers beyond the source
    /// content sit next to empty space, mirroring how editors render an
    /// almost-empty buffer.
    private static func lineNumbers(for source: String) -> String {
        let contentLineCount = countContentLines(of: source)
        let rowCount = max(contentLineCount, minimumGutterLineCount)
        let width = String(rowCount).count
        return (1...rowCount).map { number in
            let digits = String(number)
            return String(repeating: " ", count: width - digits.count) + digits
        }.joined(separator: "\n")
    }

    /// Number of content lines in `source`. A trailing newline does not
    /// get its own line — that final empty position is not a content
    /// line.
    private static func countContentLines(of source: String) -> Int {
        guard !source.isEmpty else { return 0 }
        var lines = source.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        return lines.count
    }
}

#Preview("Card — Swift") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("c1"),
            type: .code,
            title: "fib.swift",
            attributes: ["language": "swift"],
            payload: """
            func fib(_ n: Int) -> Int {
                if n < 2 { return n }
                return fib(n - 1) + fib(n - 2)
            }

            print(fib(10))
            """,
            isComplete: true
        ),
        renderer: CodeRenderer()
    )
    .padding()
    .frame(width: 460)
}

#Preview("Bare — no language tag") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("c2"),
            type: .code,
            title: "snippet",
            payload: "hello = lambda x: x * 2\nprint(hello(21))",
            isComplete: true
        )
    )
    .artifactRenderer(CodeRenderer())
    .padding()
    .frame(width: 460)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("c3"),
        type: .code,
        title: "fizzbuzz.swift",
        attributes: ["language": "swift"],
        fullPayload: """
        func fizzbuzz(upTo limit: Int) {
            for n in 1...limit {
                switch (n % 3, n % 5) {
                case (0, 0): print("FizzBuzz")
                case (0, _): print("Fizz")
                case (_, 0): print("Buzz")
                default:     print(n)
                }
            }
        }

        fizzbuzz(upTo: 30)
        """,
        chunkSize: 6,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(CodeRenderer())
    .padding()
    .frame(width: 480, height: 480)
}
