import Foundation
import UniformTypeIdentifiers

/// Detects common types from declarations, signatures, names, MIME metadata, and text probing.
public struct DefaultArtifactFileTypeDetector: ArtifactFileTypeDetecting, Sendable {
    private static let probeByteCount = 4_096

    public init() {}

    public func detectType(for request: ArtifactFileTypeDetectionRequest) throws -> ArtifactType {
        if let declaredType = request.declaredType {
            return declaredType
        }

        let probe = try readProbe(from: request.localFileURL)
        if let magicType = typeFromMagicBytes(probe) {
            return magicType
        }

        if let extensionType = typeFromFilename(request.sourceURL.lastPathComponent) {
            return extensionType
        }

        if let responseType = normalizedResponseType(request.responseMediaType) {
            return responseType
        }

        let pathExtension = request.sourceURL.pathExtension
        if !pathExtension.isEmpty,
           let uniformType = UTType(filenameExtension: pathExtension),
           let mediaType = uniformType.preferredMIMEType {
            return ArtifactType(mediaType)
        }

        return isUTF8Text(probe) ? .plainText : .octetStream
    }

    private func readProbe(from url: URL) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ArtifactFileError.readFailed(
                path: url.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }

        let result: Result<Data, Error>
        do {
            result = .success(try handle.read(upToCount: Self.probeByteCount) ?? Data())
        } catch {
            result = .failure(error)
        }

        do {
            try handle.close()
        } catch {
            throw ArtifactFileError.readFailed(
                path: url.path(percentEncoded: false),
                reason: "Failed to close file after probing: \(error.localizedDescription)"
            )
        }

        switch result {
        case let .success(data):
            return data
        case let .failure(error):
            throw ArtifactFileError.readFailed(
                path: url.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }
    }

    private func typeFromFilename(_ filename: String) -> ArtifactType? {
        let lowercased = filename.lowercased()
        if lowercased.hasSuffix(".vl.json") {
            return .vegaLite
        }
        if lowercased.hasSuffix(".chart.json") {
            return .swiftCharts
        }

        let fileExtension = (lowercased as NSString).pathExtension
        switch fileExtension {
        case "html", "htm": return .html
        case "jsx", "tsx": return .react
        case "svg": return .svg
        case "mmd", "mermaid": return .mermaid
        case "md", "markdown": return .markdown
        case "json": return .json
        case "jsonld": return .jsonLD
        case "csv": return .csv
        case "geojson": return .geoJSON
        case "tex", "latex": return .latex
        case "gltf": return .gltf
        case "glb": return .glb
        case "usdz": return .usdz
        case "pdf": return .pdf
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "webp": return .webp
        case "gif": return .gif
        case "tif", "tiff": return .tiff
        case "heic", "heif": return .heic
        case "bmp": return .bmp
        case "ttl": return .turtle
        case "trig": return .trig
        case "nq": return .nQuads
        case "rdf", "owl": return .rdfXML
        case "txt", "log": return .plainText
        case "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "swift", "kt", "kts",
             "java", "js", "ts", "py", "rb", "rs", "go", "zig", "sh", "zsh", "bash",
             "fish", "sql", "css", "scss", "yaml", "yml", "toml", "ini", "diff", "patch":
            return .code
        default:
            return nil
        }
    }

    private func typeFromMagicBytes(_ data: Data) -> ArtifactType? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) {
            return .pdf
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return .png
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
            return .gif
        }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return .tiff
        }
        if bytes.starts(with: [0x42, 0x4D]) {
            return .bmp
        }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return .webp
        }
        if bytes.count >= 12,
           Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self).lowercased()
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) {
                return .heic
            }
        }
        if bytes.starts(with: [0x67, 0x6C, 0x54, 0x46]) {
            return .glb
        }
        return nil
    }

    private func normalizedResponseType(_ mediaType: String?) -> ArtifactType? {
        guard let mediaType else { return nil }
        let normalized = mediaType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty, normalized != ArtifactType.octetStream.rawValue else {
            return nil
        }
        return ArtifactType(normalized)
    }

    private func isUTF8Text(_ data: Data) -> Bool {
        guard !data.contains(0) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }
}
