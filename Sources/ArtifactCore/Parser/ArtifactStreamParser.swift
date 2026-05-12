import Foundation

/// Actor-isolated streaming parser. Feed chunks of LLM output as they arrive;
/// receive the current `ArtifactMessage` snapshot or a list of streaming events.
public actor ArtifactStreamParser {
    private var core: ArtifactStreamParserCore

    public init() {
        self.core = ArtifactStreamParserCore()
    }

    public init(messageId: UUID) {
        self.core = ArtifactStreamParserCore(messageId: messageId)
    }

    /// Append `chunk` to the input stream and return the current message snapshot.
    public func feed(_ chunk: String) -> ArtifactMessage {
        core.feed(chunk)
    }

    /// Append `chunk` to the input stream and return only the events produced
    /// during this call.
    public func feedEvents(_ chunk: String) -> [ArtifactStreamEvent] {
        core.feedEvents(chunk)
    }

    /// Return the current snapshot without consuming new input.
    public func snapshot() -> ArtifactMessage {
        core.snapshot()
    }

    /// Finalize the stream. Any unterminated artifact raises an error.
    public func finalize() throws -> ArtifactMessage {
        try core.finalize()
    }

    /// Discard all internal state.
    public func reset() {
        core.reset()
    }
}
