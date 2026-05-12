import Foundation

/// Internal value-typed state machine shared by the synchronous `ArtifactParser`
/// and the actor-based `ArtifactStreamParser`.
///
/// State machine:
///
///     ┌──────────┐   <artifact ...>   ┌──────────────┐   </artifact>   ┌──────────┐
///     │   text   │ ─────────────────▶ │ inArtifact   │ ─────────────▶ │   text   │
///     └──────────┘                    └──────────────┘                 └──────────┘
///
/// Chunk boundaries that fall inside the open/close marker are held in the
/// internal buffer until enough characters arrive to disambiguate.
struct ArtifactStreamParserCore {

    // MARK: Configuration

    let messageId: UUID

    // MARK: State

    private var inputBuffer: String = ""
    private var committedSegments: [ArtifactMessage.Segment] = []
    private var pendingText: String = ""
    private var current: AnyArtifact?

    private static let openMarker = "<artifact"
    private static let closeMarker = "</artifact>"

    // MARK: Lifecycle

    init(messageId: UUID = UUID()) {
        self.messageId = messageId
    }

    // MARK: Public API

    mutating func feed(_ chunk: String) -> ArtifactMessage {
        _ = feedEvents(chunk)
        return snapshot()
    }

    mutating func feedEvents(_ chunk: String) -> [ArtifactStreamEvent] {
        inputBuffer.append(chunk)
        return drain()
    }

    mutating func reset() {
        inputBuffer = ""
        committedSegments = []
        pendingText = ""
        current = nil
    }

    /// Treat the input as finished. Any unterminated artifact becomes an error.
    /// Any buffered partial-marker bytes are flushed as text.
    mutating func finalize() throws -> ArtifactMessage {
        if let current {
            throw ArtifactError.unterminatedArtifact(current.id)
        }
        if !inputBuffer.isEmpty {
            pendingText.append(inputBuffer)
            inputBuffer = ""
        }
        commitPendingText()
        return ArtifactMessage(id: messageId, segments: committedSegments)
    }

    func snapshot() -> ArtifactMessage {
        var segs = committedSegments
        if !pendingText.isEmpty {
            segs.append(.text(pendingText))
        }
        if let current {
            segs.append(.artifact(current))
        }
        return ArtifactMessage(id: messageId, segments: segs)
    }

    // MARK: Drain loop

    private mutating func drain() -> [ArtifactStreamEvent] {
        var events: [ArtifactStreamEvent] = []
        while true {
            let advanced: Bool
            if current == nil {
                advanced = stepText(events: &events)
            } else {
                advanced = stepInsideArtifact(events: &events)
            }
            if !advanced { break }
        }
        return events
    }

    /// One step of progress in `text` mode. Returns `true` if more work may be possible.
    private mutating func stepText(events: inout [ArtifactStreamEvent]) -> Bool {
        guard !inputBuffer.isEmpty else { return false }

        if let openRange = inputBuffer.range(of: Self.openMarker) {
            // Flush prose preceding the marker.
            let prefixCount = inputBuffer.distance(from: inputBuffer.startIndex, to: openRange.lowerBound)
            if prefixCount > 0 {
                let prefix = String(inputBuffer.prefix(prefixCount))
                appendText(prefix, events: &events)
                inputBuffer.removeFirst(prefixCount)
            }
            // Buffer now starts with the marker. Find the closing `>` of the open tag.
            guard let tagEnd = inputBuffer.firstIndex(of: ">") else {
                return false  // wait for more chunks
            }
            let openTagString = String(inputBuffer[...tagEnd])
            let consumed = inputBuffer.distance(from: inputBuffer.startIndex, to: tagEnd) + 1
            inputBuffer.removeFirst(consumed)

            if let parsed = parseOpenTag(openTagString) {
                commitPendingText()
                let artifact = AnyArtifact(
                    id: parsed.identifier,
                    type: parsed.type,
                    title: parsed.title,
                    attributes: parsed.attributes,
                    payload: "",
                    isComplete: false
                )
                current = artifact
                events.append(.opened(artifact))
            } else {
                // Malformed tag — treat raw text.
                appendText(openTagString, events: &events)
            }
            return true
        }

        // No full marker yet. Preserve any trailing partial match for the next chunk.
        let partial = longestPartialMatch(suffixOf: inputBuffer, prefixOf: Self.openMarker)
        let safeCount = inputBuffer.count - partial
        if safeCount > 0 {
            let safe = String(inputBuffer.prefix(safeCount))
            appendText(safe, events: &events)
            inputBuffer.removeFirst(safeCount)
        }
        return false
    }

    /// One step of progress while inside an artifact body.
    private mutating func stepInsideArtifact(events: inout [ArtifactStreamEvent]) -> Bool {
        guard var artifact = current else { return false }
        guard !inputBuffer.isEmpty else { return false }

        if let closeRange = inputBuffer.range(of: Self.closeMarker) {
            // Append payload up to the close marker.
            let prefixCount = inputBuffer.distance(from: inputBuffer.startIndex, to: closeRange.lowerBound)
            if prefixCount > 0 {
                let chunk = String(inputBuffer.prefix(prefixCount))
                artifact = artifact.appending(payloadChunk: chunk)
                events.append(.delta(id: artifact.id, chunk: chunk))
            }
            // Consume the close marker.
            let consumed = inputBuffer.distance(from: inputBuffer.startIndex, to: closeRange.upperBound)
            inputBuffer.removeFirst(consumed)

            let completed = artifact.completing()
            committedSegments.append(.artifact(completed))
            events.append(.closed(id: completed.id))
            current = nil
            return true
        }

        // No close marker yet. Hold back any trailing partial close.
        let partial = longestPartialMatch(suffixOf: inputBuffer, prefixOf: Self.closeMarker)
        let safeCount = inputBuffer.count - partial
        if safeCount > 0 {
            let chunk = String(inputBuffer.prefix(safeCount))
            artifact = artifact.appending(payloadChunk: chunk)
            current = artifact
            events.append(.delta(id: artifact.id, chunk: chunk))
            inputBuffer.removeFirst(safeCount)
        }
        return false
    }

    // MARK: Helpers

    private mutating func appendText(_ value: String, events: inout [ArtifactStreamEvent]) {
        guard !value.isEmpty else { return }
        pendingText.append(value)
        events.append(.text(value))
    }

    private mutating func commitPendingText() {
        guard !pendingText.isEmpty else { return }
        committedSegments.append(.text(pendingText))
        pendingText = ""
    }
}

extension AnyArtifact {
    fileprivate func appending(payloadChunk: String) -> AnyArtifact {
        AnyArtifact(
            id: id,
            type: type,
            title: title,
            attributes: attributes,
            payload: payload + payloadChunk,
            isComplete: isComplete
        )
    }

    fileprivate func completing() -> AnyArtifact {
        AnyArtifact(
            id: id,
            type: type,
            title: title,
            attributes: attributes,
            payload: payload,
            isComplete: true
        )
    }
}

// MARK: - Open-tag parsing

struct ParsedOpenTag {
    let identifier: ArtifactIdentifier
    let type: ArtifactType
    let title: String
    let attributes: [String: String]
}

/// Parse a string of the form `<artifact key="value" key="value">` into structured
/// attributes. Returns `nil` if the string is not a syntactically valid open tag
/// or lacks the required `type` attribute.
func parseOpenTag(_ raw: String) -> ParsedOpenTag? {
    var body = raw
    guard body.hasPrefix("<artifact") else { return nil }
    body.removeFirst("<artifact".count)
    guard body.hasSuffix(">") else { return nil }
    body.removeLast()  // ">"
    if body.hasSuffix("/") {
        body.removeLast()  // tolerate self-closing
    }

    var attributes: [String: String] = [:]
    var scanner = AttributeScanner(input: body)
    while let pair = scanner.nextAttribute() {
        attributes[pair.key] = pair.value
    }

    guard let typeString = attributes.removeValue(forKey: "type") else {
        return nil
    }
    let identifierString = attributes.removeValue(forKey: "identifier") ?? UUID().uuidString
    let title = attributes.removeValue(forKey: "title") ?? ""

    return ParsedOpenTag(
        identifier: ArtifactIdentifier(identifierString),
        type: ArtifactType(typeString),
        title: title,
        attributes: attributes
    )
}

// MARK: - Partial marker matching

/// Longest length `k` such that `source.suffix(k)` equals `target.prefix(k)`,
/// constrained to `k <= target.count - 1`. Used to hold back chunk-boundary
/// bytes that might be the start of a marker.
func longestPartialMatch(suffixOf source: String, prefixOf target: String) -> Int {
    let maxLen = min(source.count, target.count - 1)
    if maxLen <= 0 { return 0 }
    let sourceChars = Array(source)
    let targetChars = Array(target)
    for len in stride(from: maxLen, through: 1, by: -1) {
        var match = true
        let offset = sourceChars.count - len
        for i in 0..<len {
            if sourceChars[offset + i] != targetChars[i] {
                match = false
                break
            }
        }
        if match { return len }
    }
    return 0
}
