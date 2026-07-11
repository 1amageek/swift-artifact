import Foundation
import Testing
@testable import ArtifactCore

@Suite("Artifact file resolution")
struct ArtifactFileResolverTests {
    private enum StubDownloaderError: Error {
        case noDownloadAvailable
    }

    private actor StubDownloader: ArtifactFileDownloading {
        private var downloads: [ArtifactFileDownload]
        private var invocationCount = 0

        init(downloads: [ArtifactFileDownload]) {
            self.downloads = downloads
        }

        func download(from url: URL) async throws -> ArtifactFileDownload {
            invocationCount += 1
            guard !downloads.isEmpty else {
                throw StubDownloaderError.noDownloadAvailable
            }
            return downloads.removeFirst()
        }

        func count() -> Int {
            invocationCount
        }
    }

    @Test func standardPolicyUsesBoundedSecureDefaults() {
        let policy = ArtifactFileLoadingPolicy.standard

        #expect(policy.maximumRemoteByteCount == 128 * 1_024 * 1_024)
        #expect(policy.maximumTextByteCount == 8 * 1_024 * 1_024)
        #expect(policy.allowsInsecureHTTP == false)
        #expect(ArtifactFileLoadingPolicy(allowsInsecureHTTP: true).allowsInsecureHTTP)
    }

    @Test func resolvesLocalJSONAndReadsText() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let fileURL = directory.appending(path: "result.json")
        let contents = #"{"status":"ok"}"#
        try Data(contents.utf8).write(to: fileURL)

        let resolver = ArtifactFileResolver()
        let file = try await resolver.resolve(ArtifactFileRequest(url: fileURL))
        let text = try await resolver.textContents(of: file, maximumByteCount: 1_024)

        #expect(file.sourceURL == fileURL)
        #expect(file.localFileURL == fileURL.standardizedFileURL)
        #expect(file.type == .json)
        #expect(file.byteCount == contents.utf8.count)
        #expect(file.isRemote == false)
        #expect(text == contents)
    }

    @Test func magicBytesTakePriorityOverFilename() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let fileURL = directory.appending(path: "misleading.txt")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: fileURL)

        let file = try await ArtifactFileResolver().resolve(
            ArtifactFileRequest(url: fileURL)
        )

        #expect(file.type == .png)
    }

    @Test func declaredTypeTakesPriorityOverDetection() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let fileURL = directory.appending(path: "design.json")
        try Data("not JSON".utf8).write(to: fileURL)
        let declaredType = ArtifactType("application/vnd.example.design")

        let file = try await ArtifactFileResolver().resolve(
            ArtifactFileRequest(url: fileURL, declaredType: declaredType)
        )

        #expect(file.type == declaredType)
    }

    @Test func detectsUnknownUTF8FileAsPlainText() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let fileURL = directory.appending(path: "README")
        try Data("plain UTF-8 text".utf8).write(to: fileURL)

        let file = try await ArtifactFileResolver().resolve(
            ArtifactFileRequest(url: fileURL)
        )

        #expect(file.type == .plainText)
    }

    @Test func detectsUnknownBinaryFileAsOctetStream() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let fileURL = directory.appending(path: "payload")
        try Data([0x00, 0xFF, 0x10, 0x80]).write(to: fileURL)

        let file = try await ArtifactFileResolver().resolve(
            ArtifactFileRequest(url: fileURL)
        )

        #expect(file.type == .octetStream)
    }

    @Test func detectsBundledFormatsFromCanonicalFilenames() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let detector = DefaultArtifactFileTypeDetector()
        let cases: [(String, ArtifactType)] = [
            ("page.html", .html),
            ("component.tsx", .react),
            ("drawing.svg", .svg),
            ("flow.mermaid", .mermaid),
            ("notes.md", .markdown),
            ("source.swift", .code),
            ("data.json", .json),
            ("graph.jsonld", .jsonLD),
            ("table.csv", .csv),
            ("chart.vl.json", .vegaLite),
            ("map.geojson", .geoJSON),
            ("formula.tex", .latex),
            ("scene.gltf", .gltf),
            ("scene.glb", .glb),
            ("scene.usdz", .usdz),
            ("document.pdf", .pdf),
            ("image.png", .png),
            ("image.jpeg", .jpeg),
            ("image.webp", .webp),
            ("image.gif", .gif),
            ("image.tiff", .tiff),
            ("image.heic", .heic),
            ("image.bmp", .bmp),
            ("graph.ttl", .turtle),
            ("dataset.trig", .trig),
            ("dataset.nq", .nQuads),
            ("ontology.rdf", .rdfXML),
            ("readme.txt", .plainText),
        ]

        for (filename, expectedType) in cases {
            let fileURL = directory.appending(path: filename)
            try Data("fixture".utf8).write(to: fileURL)
            let detectedType = try detector.detectType(
                for: ArtifactFileTypeDetectionRequest(
                    sourceURL: fileURL,
                    localFileURL: fileURL
                )
            )
            #expect(detectedType == expectedType)
        }
    }

    @Test func rejectsInsecureHTTPBeforeDownloading() async throws {
        let sourceURL = try #require(URL(string: "http://example.com/result.json"))
        let resolver = ArtifactFileResolver()

        do {
            _ = try await resolver.resolve(ArtifactFileRequest(url: sourceURL))
            Issue.record("Expected insecure HTTP to be rejected")
        } catch let error as ArtifactFileError {
            #expect(error == .unsupportedURLScheme("http"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func resolvesAndCachesRemoteFileUsingResponseMIME() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let temporaryURL = directory.appending(path: "download")
        let contents = #"{"status":"ok"}"#
        try Data(contents.utf8).write(to: temporaryURL)
        let sourceURL = try #require(URL(string: "https://example.com/artifact"))
        let downloader = StubDownloader(downloads: [
            ArtifactFileDownload(
                temporaryFileURL: temporaryURL,
                statusCode: 200,
                expectedContentLength: Int64(contents.utf8.count),
                mediaType: "application/json; charset=utf-8"
            ),
        ])
        let resolver = ArtifactFileResolver(downloader: downloader)
        let request = ArtifactFileRequest(url: sourceURL)

        let first = try await resolver.resolve(request)
        let second = try await resolver.resolve(request)

        #expect(first.type == .json)
        #expect(first.isRemote)
        #expect(first.localFileURL.pathExtension == "json")
        #expect(first.localFileURL == second.localFileURL)
        #expect(FileManager.default.fileExists(atPath: first.localFileURL.path(percentEncoded: false)))
        #expect(await downloader.count() == 1)

        try await resolver.clearCache()
        #expect(FileManager.default.fileExists(atPath: first.localFileURL.path(percentEncoded: false)) == false)
    }

    @Test func rejectsHTTPFailureAndRemovesTemporaryDownload() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let temporaryURL = directory.appending(path: "not-found")
        try Data("missing".utf8).write(to: temporaryURL)
        let sourceURL = try #require(URL(string: "https://example.com/missing"))
        let downloader = StubDownloader(downloads: [
            ArtifactFileDownload(
                temporaryFileURL: temporaryURL,
                statusCode: 404,
                expectedContentLength: 7,
                mediaType: "text/plain"
            ),
        ])
        let resolver = ArtifactFileResolver(downloader: downloader)

        do {
            _ = try await resolver.resolve(ArtifactFileRequest(url: sourceURL))
            Issue.record("Expected the HTTP failure to be rejected")
        } catch let error as ArtifactFileError {
            #expect(error == .httpFailure(url: sourceURL.absoluteString, statusCode: 404))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path(percentEncoded: false)) == false)
    }

    @Test func rejectsRemoteFileUsingDeclaredResponseSize() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let temporaryURL = directory.appending(path: "oversized")
        try Data("data".utf8).write(to: temporaryURL)
        let sourceURL = try #require(URL(string: "https://example.com/oversized"))
        let downloader = StubDownloader(downloads: [
            ArtifactFileDownload(
                temporaryFileURL: temporaryURL,
                statusCode: 200,
                expectedContentLength: 1_024,
                mediaType: "application/octet-stream"
            ),
        ])
        let resolver = ArtifactFileResolver(downloader: downloader)
        let policy = ArtifactFileLoadingPolicy(maximumRemoteByteCount: 512)

        do {
            _ = try await resolver.resolve(
                ArtifactFileRequest(url: sourceURL, policy: policy)
            )
            Issue.record("Expected the declared response size to be rejected")
        } catch let error as ArtifactFileError {
            #expect(
                error == .remoteFileTooLarge(
                    url: sourceURL.absoluteString,
                    byteCount: 1_024,
                    limit: 512
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path(percentEncoded: false)) == false)
    }

    @Test func rejectsRemoteFileUsingActualDownloadedSize() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let temporaryURL = directory.appending(path: "actual-oversized")
        try Data(repeating: 0x41, count: 513).write(to: temporaryURL)
        let sourceURL = try #require(URL(string: "https://example.com/actual-oversized"))
        let downloader = StubDownloader(downloads: [
            ArtifactFileDownload(
                temporaryFileURL: temporaryURL,
                statusCode: 200
            ),
        ])
        let resolver = ArtifactFileResolver(downloader: downloader)
        let policy = ArtifactFileLoadingPolicy(maximumRemoteByteCount: 512)

        do {
            _ = try await resolver.resolve(
                ArtifactFileRequest(url: sourceURL, policy: policy)
            )
            Issue.record("Expected the downloaded file size to be rejected")
        } catch let error as ArtifactFileError {
            #expect(
                error == .remoteFileTooLarge(
                    url: sourceURL.absoluteString,
                    byteCount: 513,
                    limit: 512
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path(percentEncoded: false)) == false)
    }

    @Test func resolverCachesAreIsolated() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let firstTemporaryURL = directory.appending(path: "first")
        let secondTemporaryURL = directory.appending(path: "second")
        try Data("first".utf8).write(to: firstTemporaryURL)
        try Data("second".utf8).write(to: secondTemporaryURL)
        let firstSourceURL = try #require(URL(string: "https://example.com/first.txt"))
        let secondSourceURL = try #require(URL(string: "https://example.com/second.txt"))
        let firstResolver = ArtifactFileResolver(
            downloader: StubDownloader(downloads: [
                ArtifactFileDownload(temporaryFileURL: firstTemporaryURL, statusCode: 200),
            ])
        )
        let secondResolver = ArtifactFileResolver(
            downloader: StubDownloader(downloads: [
                ArtifactFileDownload(temporaryFileURL: secondTemporaryURL, statusCode: 200),
            ])
        )

        let first = try await firstResolver.resolve(ArtifactFileRequest(url: firstSourceURL))
        let second = try await secondResolver.resolve(ArtifactFileRequest(url: secondSourceURL))
        try await firstResolver.clearCache()

        #expect(FileManager.default.fileExists(atPath: first.localFileURL.path(percentEncoded: false)) == false)
        #expect(FileManager.default.fileExists(atPath: second.localFileURL.path(percentEncoded: false)))
        try await secondResolver.clearCache()
    }

    @Test func enforcesTextByteLimitBeforeReading() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let fileURL = directory.appending(path: "large.txt")
        try Data("12345".utf8).write(to: fileURL)
        let resolver = ArtifactFileResolver()
        let file = try await resolver.resolve(ArtifactFileRequest(url: fileURL))

        do {
            _ = try await resolver.textContents(of: file, maximumByteCount: 4)
            Issue.record("Expected the text byte limit to be enforced")
        } catch let error as ArtifactFileError {
            guard case let .textFileTooLarge(path, byteCount, limit) = error else {
                Issue.record("Unexpected artifact file error: \(error)")
                return
            }
            #expect(path == fileURL.path(percentEncoded: false))
            #expect(byteCount == 5)
            #expect(limit == 4)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func rejectsDirectoriesAsArtifacts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let resolver = ArtifactFileResolver()

        do {
            _ = try await resolver.resolve(ArtifactFileRequest(url: directory))
            Issue.record("Expected a directory URL to be rejected")
        } catch let error as ArtifactFileError {
            #expect(error == .notRegularFile(directory.standardizedFileURL.path(percentEncoded: false)))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-artifact-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove temporary test directory: \(error)")
        }
    }
}
