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
- **Streaming-aware refiners** for JSON, SVG, Mermaid, LaTeX, CSV, Markdown, GeoJSON,
  Turtle, TriG, N-Quads, RDF/XML, and JSON-LD — partial output is drawn as it
  arrives, not after the final token
- Environment-driven renderer registry — call `.artifactRenderer(_:)` once at the top
  of your view tree and let `ArtifactView` resolve the right renderer

See [SPEC.md](SPEC.md) for the full specification.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/1amageek/swift-artifact.git", from: "0.7.0"),
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
| `ArtifactNativeRenderer` | View | Markdown / JSON / CSV / Code / SVG / GeoJSON (MapKit) / GLTF (SceneKit) / USDZ (RealityKit) / Turtle / TriG / N-Quads / RDF/XML / JSON-LD |
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
            .artifactRenderer(TurtleRenderer())
            .artifactRenderer(TriGRenderer())
            .artifactRenderer(NQuadsRenderer())
            .artifactRenderer(RDFXMLRenderer())
            .artifactRenderer(JSONLDRenderer())
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

## Sizing policy

Renderers split into two groups:

- **Content-driven** (Markdown, JSON, CSV, Code, SVG) — height follows the
  payload. The optional `artifactContentHeightLimit()` modifier scrolls
  content above a configurable cap (`artifactContentMaxHeight`, default
  360pt) so a long Markdown doc doesn't grow a chat bubble unboundedly.
- **Fill-frame** (HTML, React, Mermaid, LaTeX, Vega-Lite, GeoJSON, USDZ,
  Turtle / TriG / N-Quads / RDF/XML / JSON-LD) — these have no intrinsic
  height because they render into a WebView / Map / RealityView / Canvas.
  They expand to fill whatever frame the caller provides. **You are
  expected to wrap them with `.frame(...)`** at the call site:

```swift
ArtifactCard(artifact)
    .frame(height: 480)         // chat-bubble use: fixed height
    .artifactRenderer(GeoJSONMapKitRenderer())
```

Earlier versions imposed an internal 240–360pt cap on these renderers,
which silently overrode caller-supplied `.frame(height:)`. That cap was
removed in 0.6.4 — the library no longer second-guesses your layout.

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
| Turtle / TriG | truncated to the last statement-terminating `.` outside strings, IRIs, and comments |
| N-Quads | truncated to the last newline (each line is a self-contained quad) |
| RDF/XML | framing pass collects every fully-closed top-level element under `<rdf:RDF>` |
| JSON-LD | tolerant JSON AST emits triples for every fully-typed property pair, including pre-`@context` |

Renderers without an incremental strategy fall back to the default refiner, which
waits for `artifact.isComplete`.

A type-specific waiting UI is opt-in via `preRenderableBody(artifact:progress:)` — for
example, the React renderer shows highlighted JSX source until the component finishes
streaming. If a renderer doesn't override it, the view layer falls back to
`ArtifactProgressView`.

## Supported artifact types

The framework keys every artifact on its MIME type. The extension column
lists the canonical file suffix(es) for that format — useful when ingesting
files from disk or routing on an upload's filename. Extensions are advisory
metadata; the renderer registry resolves on `ArtifactType` (i.e. the MIME)
alone.

### Tier 1 — Claude-compatible

| Format | MIME | Extensions | Renderer |
|---|---|---|---|
| HTML | `text/html` | `.html`, `.htm` | `HTMLWebViewRenderer` |
| React | `application/vnd.ant.react` | `.jsx`, `.tsx` | `ReactWebViewRenderer` |
| SVG | `image/svg+xml` | `.svg` | `SVGRenderer` |
| Mermaid | `application/vnd.ant.mermaid` | `.mmd`, `.mermaid` | `MermaidWebViewRenderer` |
| Markdown | `text/markdown` | `.md`, `.markdown` | `MarkdownRenderer` |
| Code | `application/vnd.ant.code` | — (language carried in attributes) | `CodeRenderer` |

### Tier 2 — Common agent output

| Format | MIME | Extensions | Renderer |
|---|---|---|---|
| JSON | `application/json` | `.json` | `JSONRenderer` |
| CSV | `text/csv` | `.csv` | `CSVRenderer` |
| Vega-Lite | `application/vnd.vegalite.v5+json` | `.vl.json` | `VegaLiteWebViewRenderer` |
| GeoJSON | `application/geo+json` | `.geojson` | `GeoJSONMapKitRenderer` |
| LaTeX | `application/x-latex` | `.tex`, `.latex` | `LaTeXWebViewRenderer` |
| glTF (JSON) | `model/gltf+json` | `.gltf` | `GLTFSceneKitRenderer` |
| USDZ | `model/vnd.usdz+zip` | `.usdz` | `USDZModel3DRenderer` |

### Knowledge graph (W3C RDF)

All five RDF renderers share a force-directed layout, blank-node-stable
identifiers across re-renders, and progressive partial rendering. JSON-LD
and RDF/XML use bespoke partial processors so the diagram appears as
triples become derivable from the prefix — not when the closing `}` or
`</rdf:RDF>` arrives.

| Format | MIME | Extensions | Renderer |
|---|---|---|---|
| Turtle | `text/turtle` | `.ttl` | `TurtleRenderer` |
| TriG | `application/trig` | `.trig` | `TriGRenderer` |
| N-Quads | `application/n-quads` | `.nq` | `NQuadsRenderer` |
| RDF/XML | `application/rdf+xml` | `.rdf`, `.owl` | `RDFXMLRenderer` |
| JSON-LD | `application/ld+json` | `.jsonld` | `JSONLDRenderer` |

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
