# swift-artifact

A Swift/SwiftUI library for displaying LLM-generated `<artifact>` blocks inside chat
interfaces. Parses Claude-style artifact tags, models them as values, and renders each
one through a pluggable renderer protocol.

- **Swift 6.3+**, **iOS / macOS / iPadOS / visionOS / Mac Catalyst 26+**
- Five SPM libraries — depend only on what you need
- Streaming-aware: each renderer declares whether its current payload is
  `empty / streaming / partial / complete`
- Environment-driven renderer registry — call `.artifactRenderer(_:)` once at
  the top of your view tree and let `ArtifactView` resolve the right renderer

See [SPEC.md](SPEC.md) for the full specification.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/1amageek/swift-artifact.git", from: "0.1.0"),
]

// Target dependencies (pick what you need)
.product(name: "ArtifactCore",            package: "swift-artifact"),
.product(name: "ArtifactRenderer",        package: "swift-artifact"),
.product(name: "ArtifactView",            package: "swift-artifact"),
.product(name: "ArtifactRendererNative",  package: "swift-artifact"),
.product(name: "ArtifactRendererWeb",     package: "swift-artifact"),
```

## Modules

| Module | Depends on | Purpose |
|---|---|---|
| `ArtifactCore` | — | `ArtifactType`, `AnyArtifact`, parsing |
| `ArtifactRenderer` | Core | `ArtifactRenderable` protocol, `AnyArtifactRenderer` |
| `ArtifactView` | Core + Renderer | `ArtifactView`, `ArtifactCard`, `ArtifactCanvas`, env registry |
| `ArtifactRendererNative` | View | Markdown / JSON / CSV / Code / SVG / GeoJSON (MapKit) / GLTF (SceneKit) / USDZ (QuickLook) |
| `ArtifactRendererWeb` | View | HTML / React / Mermaid / LaTeX (KaTeX) / Vega-Lite via `WKWebView` |

`ArtifactRendererNative` pulls in [`swift-markdown-ui`](https://github.com/1amageek/swift-markdown-ui)
for block-level Markdown rendering (headings, lists, tables, code blocks).

## Minimal example

```swift
import SwiftUI
import ArtifactCore
import ArtifactView
import ArtifactRendererNative
import ArtifactRendererWeb

struct ChatBubble: View {
    let message: String  // raw text containing <artifact> tags

    var body: some View {
        ArtifactCanvas(text: message)
            .artifactRenderer(MarkdownRenderer())
            .artifactRenderer(CodeRenderer())
            .artifactRenderer(JSONRenderer())
            .artifactRenderer(CSVRenderer())
            .artifactRenderer(SVGRenderer())
            .artifactRenderer(GeoJSONMapKitRenderer())
            .artifactRenderer(MermaidWebViewRenderer())
            .artifactRenderer(LaTeXWebViewRenderer())
            .artifactRenderer(HTMLWebViewRenderer())
            .artifactRenderer(ReactWebViewRenderer())
            .artifactRenderer(VegaLiteWebViewRenderer())
    }
}
```

### Standalone display

`ArtifactView(_:)` shows an artifact without the card chrome — use it when an artifact
already has its own header (sidebar, document outline, etc.).

```swift
ArtifactView(artifact)
    .artifactRenderer(MarkdownRenderer())
```

`ArtifactCard(_:)` wraps the same thing with a title bar, type badge, streaming
indicator, and an optional disclosure button.

```swift
ArtifactCard(artifact) {
    Button { share(artifact) } label: { Image(systemName: "square.and.arrow.up") }
    Button { copy(artifact) }  label: { Image(systemName: "doc.on.doc") }
}
```

The card respects two environment modifiers:

```swift
.artifactCardContentInsets(EdgeInsets())    // remove inner padding
.artifactCardDisclosure(.hidden)            // hide the expand/collapse button
```

## Supported artifact types

### Tier 1 — Claude-compatible

`text/html` · `application/vnd.ant.react` · `image/svg+xml` · `application/vnd.ant.mermaid` · `text/markdown` · `application/vnd.ant.code`

### Tier 2 — Common agent output

`application/json` · `text/csv` · `application/vnd.ant.vega-lite` · `application/geo+json` · `application/vnd.ant.latex` · `model/gltf+json` · `model/vnd.usdz+zip`

### Tier 3 — User-defined

Register your own MIME type by conforming to `Artifactable` and adding an
`ArtifactRenderable` implementation.

## Writing a custom renderer

```swift
struct MyMarkdownRenderer: ArtifactRenderable, Sendable {
    static let artifactType: ArtifactType = .markdown

    static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        return artifact.isComplete ? .complete : .partial
    }

    func body(artifact: AnyArtifact) -> some View {
        Text(artifact.payload)
    }
}
```

`renderingState(for:)` lets the view layer switch between an empty placeholder, a
streaming progress indicator, and the renderer body — without each renderer needing to
implement that branching itself.

## License

MIT — see [LICENSE](LICENSE).
