# swift-artifact Markdown Renderer

## Purpose and Scope

This package adapts Markdown Artifact payloads to the external
`swift-markdown-ui` `MarkdownView`. It owns Artifact refinement, renderer
routing, and the card-friendly default image bounds.

## Responsibilities and Boundaries

`MarkdownRenderer` validates streaming payload boundaries and invokes one
`MarkdownView` for the renderable payload. Image parsing, loading, and frame
semantics belong to `swift-markdown-ui`; this package supplies a default
maximum image frame of 360 by 240 points for Artifact cards. No image-specific
public view is defined here.

## Related Designs

| Design | Relationship | Contract Used | Summary |
|---|---|---|---|
| [`swift-markdown-ui`](../swift-markdown-ui/DESIGN.md) | depends on | `MarkdownView` and `markdownImageSize` | Owns Markdown AST/image rendering and frame-compatible image policy. |
| [`SPEC.md`](SPEC.md) | package authority | Artifact renderer contract | Defines Artifact refinement and renderer routing. |

## Architecture

```mermaid
flowchart LR
    A[AnyArtifact payload] --> B[MarkdownRenderer.refine]
    B --> C[MarkdownRenderer.body]
    C --> D[MarkdownView(payload)]
    D --> P[Artifact default image frame<br/>max 360 x 240]
    D --> E[swift-markdown-ui image/text rendering]
```

## Contracts and Invariants

- `MarkdownRenderer.body` invokes exactly one `MarkdownView` for a valid
  payload.
- This package does not parse Markdown a second time.
- This package does not expose `MarkdownImageBlockView` or another image entry
  point.
- Artifact Markdown images use a maximum 360 by 240 point frame, preserving
  the source aspect ratio and aligning to the leading edge.
- Direct `MarkdownView` consumers may apply `markdownImageSize`; the modifier
  applies to all descendant Markdown images.

## Runtime Flows

Streaming refinement returns only a complete line prefix. Once the Artifact is
renderable, `MarkdownRenderer` forwards the refined string to `MarkdownView`
inside the existing bounded scroll and content inset container.

## Failure, Concurrency, and Constraints

Malformed or incomplete Markdown is handled by the existing refinement
contract. Image URL failures remain visible through `MarkdownView` and are not
converted into successful text-only payloads.

## Verification and Change Impact

- `MarkdownRefinerTests` verifies refinement behavior.
- `swift-markdown-ui` tests verify Markdown image node preservation and image
  frame configuration.
- `ArtifactNativeRenderer` must compile against the selected MarkdownUI
  revision on macOS and iOS 27.
