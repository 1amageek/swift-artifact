import Foundation

/// The result of running a renderer's `refine(_:)` step over an artifact's raw
/// payload.
///
/// `RefinedPayload` enforces the spec's "discard incomplete elements" rule: a
/// renderer never sees half-formed input. Either the payload is not yet usable
/// (`.preRenderable` — the view layer shows a waiting state) or it has been
/// reduced to a string that the renderer can draw as-is (`.renderable`).
///
/// The renderer is the sole authority on what counts as a valid subset. The
/// `String` carried by `.renderable` is the renderer's input — typically the
/// raw payload itself once complete, or a truncated valid prefix while still
/// streaming (e.g. SVG with the last unclosed element dropped).
public enum RefinedPayload: Sendable, Equatable, Hashable {
    /// The payload has not yet reached a state the renderer can draw.
    case preRenderable(PreRenderableProgress)

    /// A valid subset of the payload that the renderer can draw right now.
    case renderable(String)
}
