import ArtifactCore
import ArtifactRenderer
import Foundation

struct ArtifactFileArtifactLoader: Sendable {
    let resolver: any ArtifactFileResolving

    func load(
        _ request: ArtifactFileRequest,
        renderers: [ArtifactType: AnyArtifactRenderer]
    ) async throws -> AnyArtifact {
        let file = try await resolver.resolve(request)
        let fileInput = renderers.artifactRenderer(for: file.type)?.fileInput
            ?? ArtifactFileInput.inferred(for: file.type)

        let payload: String
        switch fileInput {
        case .text:
            payload = try await resolver.textContents(
                of: file,
                maximumByteCount: request.policy.maximumTextByteCount
            )
        case .localFileURL:
            payload = file.localFileURL.absoluteString
        }

        var attributes = [
            "sourceURL": file.sourceURL.absoluteString,
            "localFileURL": file.localFileURL.absoluteString,
            "byteCount": String(file.byteCount),
            "isRemote": String(file.isRemote),
        ]
        if let responseMediaType = file.responseMediaType {
            attributes["responseMediaType"] = responseMediaType
        }
        let filename = file.sourceURL.lastPathComponent
        if !filename.isEmpty {
            attributes["filename"] = filename
        }
        let pathExtension = file.sourceURL.pathExtension
        if !pathExtension.isEmpty {
            attributes["fileExtension"] = pathExtension
        }

        return AnyArtifact(
            id: ArtifactIdentifier("file:\(file.sourceURL.absoluteString)"),
            type: file.type,
            title: Self.displayTitle(for: request),
            attributes: attributes,
            payload: payload,
            isComplete: true
        )
    }

    static func displayTitle(for request: ArtifactFileRequest) -> String {
        if let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        let filename = request.url.lastPathComponent
        return filename.isEmpty ? "Artifact" : filename
    }
}
