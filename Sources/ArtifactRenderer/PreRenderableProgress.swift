import Foundation

/// Progress information surfaced to renderers while the artifact has not yet
/// reached a renderable state.
///
/// `receivedCharacters` reflects the raw payload length the parser has seen so
/// far. `hint` is an optional, renderer-defined string describing why the
/// payload is still pre-renderable (e.g. "waiting for first newline").
public struct PreRenderableProgress: Sendable, Equatable, Hashable {
    public let receivedCharacters: Int
    public let hint: String?

    public init(receivedCharacters: Int, hint: String? = nil) {
        self.receivedCharacters = receivedCharacters
        self.hint = hint
    }
}
