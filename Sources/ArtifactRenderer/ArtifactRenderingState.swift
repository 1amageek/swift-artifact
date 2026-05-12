import Foundation

/// How a renderer wishes to draw an artifact at this instant.
///
/// The renderer is the authority — `streaming` vs `partial` distinguishes "I
/// cannot draw this yet, show a placeholder" from "I have something to show even
/// though more bytes are coming." Each renderer chooses based on its own
/// requirements (e.g. Mermaid validates the partial source before declaring it
/// renderable).
public enum ArtifactRenderingState: Sendable, Equatable, Hashable {
    /// No content has been received yet.
    case empty

    /// Receiving; render a progress placeholder.
    case streaming

    /// Mid-stream but renderable as-is.
    case partial

    /// Fully received.
    case complete
}
