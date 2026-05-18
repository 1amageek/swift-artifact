import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

#if os(macOS)
import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
#endif

/// Renders source code in a readonly, syntax-highlighted editor surface.
public struct CodeRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .code
    /// The code editor provides its own gutter, padding, and language pill, so
    /// the card's default padding would stack as an outer margin.
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.payload.isEmpty {
            return .preRenderable(PreRenderableProgress(receivedCharacters: 0))
        }
        return .renderable(artifact.payload)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        let languageName = Self.languageDisplayName(for: artifact)

        #if os(macOS)
        HighlightedCodeSurface(
            source: payload,
            language: Self.codeLanguage(for: artifact, payload: payload),
            languageDisplayName: languageName
        )
        #else
        PlainCodeSurface(source: payload, languageDisplayName: languageName)
        #endif
    }

    private static func languageDisplayName(for artifact: AnyArtifact) -> String? {
        let directKeys = ["language", "lang"]
        for key in directKeys {
            if let value = artifact.attributes[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        let titleExtension = URL(fileURLWithPath: artifact.title).pathExtension
        return titleExtension.isEmpty ? nil : titleExtension
    }

    /// Minimum number of visible editor rows. Short snippets should still keep
    /// enough height to read as an editor rather than a one-line label.
    fileprivate static let minimumVisibleLineCount = 10

    fileprivate static func visibleLineCount(for source: String) -> Int {
        max(countContentLines(of: source), minimumVisibleLineCount)
    }

    fileprivate static func countContentLines(of source: String) -> Int {
        guard !source.isEmpty else { return 0 }
        var lines = source.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        return lines.count
    }

    #if os(macOS)
    private static func codeLanguage(for artifact: AnyArtifact, payload: String) -> CodeLanguage {
        for candidate in languageCandidates(for: artifact) {
            if let language = codeLanguage(matching: candidate) {
                return language
            }
        }

        let prefix = String(payload.prefix(4096))
        let suffix = String(payload.suffix(4096))
        let filename = artifact.title.isEmpty ? "snippet.txt" : artifact.title
        return CodeLanguage.detectLanguageFrom(
            url: URL(fileURLWithPath: filename),
            prefixBuffer: prefix,
            suffixBuffer: suffix
        )
    }

    private static func languageCandidates(for artifact: AnyArtifact) -> [String] {
        var candidates: [String] = []

        for key in ["language", "lang", "fileExtension", "filename", "fileName"] {
            if let value = artifact.attributes[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                candidates.append(value)
            }
        }

        if !artifact.title.isEmpty {
            candidates.append(artifact.title)
            let titleExtension = URL(fileURLWithPath: artifact.title).pathExtension
            if !titleExtension.isEmpty {
                candidates.append(titleExtension)
            }
        }

        return candidates
    }

    private static func codeLanguage(matching rawValue: String) -> CodeLanguage? {
        let normalized = normalizedLanguageIdentifier(rawValue)
        guard !normalized.isEmpty else { return nil }

        let identifiers = Set([
            normalized,
            languageAliases[normalized],
            normalized.replacingOccurrences(of: "_", with: "-"),
            normalized.replacingOccurrences(of: "-", with: "")
        ].compactMap { $0 })

        return CodeLanguage.allLanguages.first { language in
            identifiers.contains(language.tsName.lowercased())
            || identifiers.contains(language.id.rawValue.lowercased())
            || language.extensions.contains { identifiers.contains($0.lowercased()) }
            || language.additionalIdentifiers.contains { identifiers.contains($0.lowercased()) }
        }
    }

    private static func normalizedLanguageIdentifier(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix(".") {
            value.removeFirst()
        }
        if value.contains("/") || value.contains(".") {
            let url = URL(fileURLWithPath: value)
            let pathExtension = url.pathExtension
            if !pathExtension.isEmpty {
                value = pathExtension.lowercased()
            } else if let lastPathComponent = url.pathComponents.last, !lastPathComponent.isEmpty {
                value = lastPathComponent.lowercased()
            }
        }
        return value
    }

    private static let languageAliases: [String: String] = [
        "c#": "c-sharp",
        "csharp": "c-sharp",
        "c++": "cpp",
        "cxx": "cpp",
        "objective-c": "objc",
        "objectivec": "objc",
        "shell": "bash",
        "zsh": "bash",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "ts": "typescript",
        "py": "python",
        "yml": "yaml",
        "md": "markdown",
        "text": "txt",
        "plain": "txt",
        "plaintext": "txt"
    ]
    #endif
}

#if os(macOS)
private struct HighlightedCodeSurface: View {
    let source: String
    let language: CodeLanguage
    let languageDisplayName: String?

    @Environment(\.artifactContentMaxHeight) private var maxHeight
    @State private var text: String
    @State private var editorState = SourceEditorState()

    init(source: String, language: CodeLanguage, languageDisplayName: String?) {
        self.source = source
        self.language = language
        self.languageDisplayName = languageDisplayName
        self._text = State(initialValue: source)
    }

    var body: some View {
        SourceEditor(
            $text,
            language: language,
            configuration: configuration,
            state: $editorState
        )
        .frame(height: editorHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let languageDisplayName {
                languageBadge(languageDisplayName)
            }
        }
        .onAppear {
            text = source
        }
        .onChange(of: source) { _, newValue in
            text = newValue
        }
    }

    private func languageBadge(_ language: String) -> some View {
        Text(language)
            .font(.caption2.weight(.medium))
            .monospaced()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassEffect(in: Capsule())
            .padding(8)
    }

    private var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: .artifactCodeDark,
                useThemeBackground: true,
                font: Self.font,
                lineHeightMultiple: Double(Self.lineHeightMultiple),
                wrapLines: false,
                tabWidth: 4,
                bracketPairEmphasis: nil
            ),
            behavior: .init(
                isEditable: false,
                isSelectable: true,
                indentOption: .spaces(count: 4),
                reformatAtColumn: 120
            ),
            layout: .init(
                editorOverscroll: 0,
                contentInsets: NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0),
                additionalTextInsets: NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
            ),
            peripherals: .init(
                showGutter: true,
                showMinimap: false,
                showReformattingGuide: false,
                showFoldingRibbon: false
            )
        )
    }

    private var editorHeight: CGFloat {
        let contentHeight = CGFloat(CodeRenderer.visibleLineCount(for: source)) * Self.lineHeight + 24
        guard let maxHeight else { return contentHeight }
        return min(contentHeight, maxHeight)
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let lineHeightMultiple: CGFloat = 1.22
    private static let lineHeight = ceil((font.ascender - font.descender + font.leading) * lineHeightMultiple)
}

private extension EditorTheme {
    static var artifactCodeDark: EditorTheme {
        EditorTheme(
            text: Attribute(color: NSColor.artifactCodeColor(0xE6EDF3)),
            insertionPoint: NSColor.artifactCodeColor(0x58A6FF),
            invisibles: Attribute(color: NSColor.artifactCodeColor(0x53606E)),
            background: NSColor.artifactCodeColor(0x111418),
            lineHighlight: NSColor.artifactCodeColor(0x1A2029),
            selection: NSColor.artifactCodeColor(0x315174),
            keywords: Attribute(color: NSColor.artifactCodeColor(0xFF7AB2), bold: true),
            commands: Attribute(color: NSColor.artifactCodeColor(0x78C2B3)),
            types: Attribute(color: NSColor.artifactCodeColor(0x6BDFFF)),
            attributes: Attribute(color: NSColor.artifactCodeColor(0xCC9768)),
            variables: Attribute(color: NSColor.artifactCodeColor(0x79C0FF)),
            values: Attribute(color: NSColor.artifactCodeColor(0xB281EB)),
            numbers: Attribute(color: NSColor.artifactCodeColor(0xD9C97C)),
            strings: Attribute(color: NSColor.artifactCodeColor(0xA5D6FF)),
            characters: Attribute(color: NSColor.artifactCodeColor(0xD9C97C)),
            comments: Attribute(color: NSColor.artifactCodeColor(0x8B949E))
        )
    }
}

private extension NSColor {
    static func artifactCodeColor(_ rgb: UInt32) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
#else
private struct PlainCodeSurface: View {
    let source: String
    let languageDisplayName: String?

    var body: some View {
        ArtifactBoundedScrollView(
            .vertical,
            contentInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        ) {
            HStack(alignment: .top, spacing: 12) {
                Text(lineNumbers(for: source))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)

                Text(source)
                    .textSelection(.enabled)
            }
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .topTrailing) {
            if let languageDisplayName {
                Text(languageDisplayName)
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

    private func lineNumbers(for source: String) -> String {
        let rowCount = CodeRenderer.visibleLineCount(for: source)
        let width = String(rowCount).count
        return (1...rowCount).map { number in
            let digits = String(number)
            return String(repeating: " ", count: width - digits.count) + digits
        }.joined(separator: "\n")
    }
}
#endif

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
    .frame(width: 480, height: 480)
}

private struct CodeRendererLanguageSwitcherPreview: View {
    @State private var selectedID = CodeRendererPreviewSample.samples[0].id

    private var selectedSample: CodeRendererPreviewSample {
        CodeRendererPreviewSample.samples.first { $0.id == selectedID } ?? CodeRendererPreviewSample.samples[0]
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Language", selection: $selectedID) {
                    ForEach(CodeRendererPreviewSample.samples) { sample in
                        Text(sample.name).tag(sample.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)

                Spacer()
            }

            ArtifactCard(selectedSample.artifact, renderer: CodeRenderer())
                .artifactContentMaxHeight(nil)
                .id(selectedSample.id)
        }
        .padding(16)
        .frame(width: 760, height: 560)
    }
}

private struct CodeRendererPreviewSample: Identifiable {
    let id: String
    let name: String
    let fileName: String
    let language: String
    let payload: String

    var artifact: AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("code-renderer-preview-\(id)"),
            type: .code,
            title: fileName,
            attributes: ["language": language],
            payload: payload,
            isComplete: true
        )
    }

    static let samples: [CodeRendererPreviewSample] = [
        CodeRendererPreviewSample(
            id: "swift",
            name: "Swift",
            fileName: "GraphLayout.swift",
            language: "swift",
            payload: """
            struct GraphLayout {
                var nodes: [Node]
                var edges: [Edge]

                func routeCost(for edge: Edge) -> Double {
                    let length = edge.segments.reduce(0) { $0 + $1.length }
                    return length + Double(edge.corners * 24)
                }
            }
            """
        ),
        CodeRendererPreviewSample(
            id: "typescript",
            name: "TypeScript",
            fileName: "layout.ts",
            language: "typescript",
            payload: """
            type RouteCost = {
              length: number
              corners: number
              clearancePenalty: number
            }

            export function compareRoute(a: RouteCost, b: RouteCost): number {
              return a.length - b.length
                || a.corners - b.corners
                || a.clearancePenalty - b.clearancePenalty
            }
            """
        ),
        CodeRendererPreviewSample(
            id: "python",
            name: "Python",
            fileName: "packing.py",
            language: "python",
            payload: """
            from dataclasses import dataclass

            @dataclass(frozen=True)
            class Rect:
                x: float
                y: float
                width: float
                height: float

                @property
                def area(self) -> float:
                    return self.width * self.height
            """
        ),
        CodeRendererPreviewSample(
            id: "json",
            name: "JSON",
            fileName: "artifact.json",
            language: "json",
            payload: """
            {
              "type": "code",
              "title": "artifact.json",
              "attributes": {
                "language": "json",
                "readonly": true
              },
              "isComplete": true
            }
            """
        ),
        CodeRendererPreviewSample(
            id: "markdown",
            name: "Markdown",
            fileName: "notes.md",
            language: "markdown",
            payload: """
            # Layout Notes

            Edge routing uses orthogonal segments.

            ```swift
            let route = Route(source: alice, target: bob)
            ```

            - Prefer shorter routes
            - Keep ports visually balanced
            """
        ),
        CodeRendererPreviewSample(
            id: "shell",
            name: "Shell",
            fileName: "verify.sh",
            language: "bash",
            payload: """
            set -euo pipefail

            swift build
            swift test --filter CodeRendererTests
            """
        ),
        CodeRendererPreviewSample(
            id: "html",
            name: "HTML",
            fileName: "preview.html",
            language: "html",
            payload: """
            <main class="artifact">
              <header>
                <h1>Code Renderer</h1>
              </header>
              <pre><code>readonly source</code></pre>
            </main>
            """
        )
    ]
}

#Preview("Code Render — selectable languages") {
    CodeRendererLanguageSwitcherPreview()
}
