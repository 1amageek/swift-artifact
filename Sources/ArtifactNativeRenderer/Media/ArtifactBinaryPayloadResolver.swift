import Foundation

enum ArtifactBinaryPayloadResolver {
    static func trimmedPayload(_ payload: String) -> String {
        payload.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func remoteURL(from payload: String) -> URL? {
        let trimmed = trimmedPayload(payload)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return url
    }

    static func localFileURL(from payload: String) -> URL? {
        let trimmed = trimmedPayload(payload)
        guard trimmed.isEmpty == false else { return nil }
        if let url = URL(string: trimmed), url.isFileURL {
            return url
        }
        if trimmed.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = home + String(trimmed.dropFirst())
            return URL(fileURLWithPath: path)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return nil
    }

    static func data(from payload: String) throws -> Data {
        let trimmed = trimmedPayload(payload)
        guard trimmed.isEmpty == false else {
            throw ArtifactBinaryPayloadError.empty
        }
        if trimmed.lowercased().hasPrefix("data:") {
            return try dataFromDataURL(trimmed)
        }
        if let fileURL = localFileURL(from: trimmed) {
            return try Data(contentsOf: fileURL)
        }
        if remoteURL(from: trimmed) != nil {
            throw ArtifactBinaryPayloadError.unsupportedPayload
        }
        return try dataFromBase64(trimmed)
    }

    private static func dataFromDataURL(_ payload: String) throws -> Data {
        guard let comma = payload.firstIndex(of: ",") else {
            throw ArtifactBinaryPayloadError.invalidDataURL
        }
        let metadata = payload[..<comma].lowercased()
        let bodyStart = payload.index(after: comma)
        let body = String(payload[bodyStart...])
        if metadata.contains(";base64") {
            return try dataFromBase64(body)
        }
        guard let decoded = body.removingPercentEncoding,
              let data = decoded.data(using: .utf8)
        else {
            throw ArtifactBinaryPayloadError.invalidDataURL
        }
        return data
    }

    private static func dataFromBase64(_ payload: String) throws -> Data {
        let cleaned = payload.filter { character in
            character.isWhitespace == false && character.isNewline == false
        }
        guard let data = Data(base64Encoded: String(cleaned)) else {
            throw ArtifactBinaryPayloadError.invalidBase64
        }
        return data
    }
}
