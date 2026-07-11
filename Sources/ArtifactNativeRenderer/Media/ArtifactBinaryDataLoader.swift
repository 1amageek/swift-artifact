import Foundation

actor ArtifactBinaryDataLoader {
    static let shared = ArtifactBinaryDataLoader()

    func data(from payload: String) async throws -> Data {
        if let url = ArtifactBinaryPayloadResolver.remoteURL(from: payload) {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
        return try ArtifactBinaryPayloadResolver.data(from: payload)
    }
}
