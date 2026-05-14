# swift-artifact

A Swift/SwiftUI library for displaying LLM-generated `<artifact>` blocks inside chat
interfaces. Parses Claude-style artifact tags, models them as values, and renders each
one through a pluggable renderer protocol — with first-class support for **partial
rendering** while a model is still streaming.

- **Swift 6.3+**, **iOS / macOS / iPadOS / visionOS / Mac Catalyst 26+**
- One umbrella module (`SwiftArtifact`) or five fine-grained libraries — pick your
  granularity
- **Two-stage rendering model**: every renderer declares a `refine(_:)` step that
  reduces the in-flight payload to a renderer-valid subset, so the `body` never sees
  half-formed input
- **Streaming-aware refiners** for JSON, SVG, Mermaid, LaTeX, CSV, Markdown, and
  GeoJSON — partial output is drawn as it arrives, not after the final token
- Environment-driven renderer registry — call `.artifactRenderer(_:)` once at the top
  of your view tree and let `ArtifactView` resolve the right renderer

See [SPEC.md](SPEC.md) for the full specification.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/1amageek/swift-artifact.git", from: "0.5.0"),
]
```

The simplest option is the umbrella product `SwiftArtifact`, which re-exports every
sub-module:

```swift
// Target dependency
.product(name: "SwiftArtifact", package: "swift-artifact"),
```

```swift
import SwiftArtifact   // grants access to every type and renderer below
```

If you want to pull in only a subset (e.g. you ship a Markdown-only client and don't
want WebKit in your binary), depend on individual products instead:

```swift
.product(name: "ArtifactCore",            package: "swift-artifact"),
.product(name: "ArtifactRenderer",        package: "swift-artifact"),
.product(name: "ArtifactView",            package: "swift-artifact"),
.product(name: "ArtifactNativeRenderer",  package: "swift-artifact"),
.product(name: "ArtifactWebRenderer",     package: "swift-artifact"),
```

## Modules

| Module | Depends on | Purpose |
|---|---|---|
| `SwiftArtifact` | All of the below | Umbrella — `@_exported` re-export of every module |
| `ArtifactCore` | — | `ArtifactType`, `AnyArtifact`, parsing |
| `ArtifactRenderer` | Core | `ArtifactRenderable` protocol, `RefinedPayload`, `AnyArtifactRenderer` |
| `ArtifactView` | Core + Renderer | `ArtifactView`, `ArtifactCard`, `ArtifactCanvas`, env registry |
| `ArtifactNativeRenderer` | View | Markdown / JSON / CSV / Code / SVG / GeoJSON (MapKit) / GLTF (SceneKit) / USDZ (RealityKit) |
| `ArtifactWebRenderer` | View | HTML / React / Mermaid / LaTeX (KaTeX) / Vega-Lite via `WKWebView` |

`ArtifactNativeRenderer` pulls in [`swift-markdown-ui`](https://github.com/1amageek/swift-markdown-ui)
for block-level Markdown rendering (headings, lists, tables, code blocks).
The USDZ renderer uses RealityKit's `RealityView` with built-in pinch / drag / double-tap
gestures.

## Minimal example

```swift
import SwiftUI
import SwiftArtifact

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
            .artifactRenderer(USDZModel3DRenderer())
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
.artifactCardContentInsets(EdgeInsets())    // override inner padding
.artifactCardDisclosure(.hidden)            // hide the expand/collapse button
```

If the environment override is not set, the card consults the resolved
renderer's `preferredContentInsets`. Bundled renderers that fill their frame
(HTML, Map, Mermaid, Code) opt out of card padding by default; textual
renderers (Markdown, JSON, CSV) keep the package-level default.

## Partial rendering

Each renderer owns the rules for what counts as a renderable subset of its payload via
`refine(_:)`. The view layer never shows a half-parsed structure — it shows either a
waiting state (`.preRenderable`) or whatever the renderer says is safe to draw
(`.renderable(String)`).

| Type | Strategy while streaming |
|---|---|
| JSON / GeoJSON | longest valid prefix down to the deepest open frame |
| SVG | element-level boundary tracking, last unclosed element dropped |
| HTML | token-level trim — half-typed tag dropped, `<script>` / `<style>` blocks withheld until their close tag arrives |
| Mermaid | last incomplete line dropped + brace / quote balance check |
| LaTeX | dangling `\command` and unbalanced braces trimmed back |
| CSV | drops the last in-flight row |
| Markdown | drops the last in-flight block |

Renderers without an incremental strategy fall back to the default refiner, which
waits for `artifact.isComplete`.

A type-specific waiting UI is opt-in via `preRenderableBody(artifact:progress:)` — for
example, the React renderer shows highlighted JSX source until the component finishes
streaming. If a renderer doesn't override it, the view layer falls back to
`ArtifactProgressView`.

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
struct MyJSONRenderer: ArtifactRenderable, Sendable {
    static let artifactType: ArtifactType = .json

    // Optional: declare what counts as a renderable subset while streaming.
    // Omitting this gives you the default — wait for artifact.isComplete.
    static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        if let prefix = longestValidPrefix(of: artifact.payload) {
            return .renderable(prefix)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for first complete value"
            )
        )
    }

    // body receives the refined string, never the raw payload. It can assume
    // the input is well-formed for this renderer's type.
    func body(artifact: AnyArtifact, payload: String) -> some View {
        Text(payload).font(.system(.callout, design: .monospaced))
    }
}
```

To make the hosting card fill its chrome edge-to-edge (Map / WebView / Code
style), override `preferredContentInsets`:

```swift
static let preferredContentInsets: EdgeInsets? = EdgeInsets()
```

For a type-specific waiting state, add `preRenderableBody`:

```swift
func preRenderableBody(
    artifact: AnyArtifact,
    progress: PreRenderableProgress
) -> some View {
    Text(artifact.payload)      // show the raw stream
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(.secondary)
}
```

## License

MIT — see [LICENSE](LICENSE).
