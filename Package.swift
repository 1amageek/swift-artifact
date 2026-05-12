// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "swift-artifact",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26),
        .macCatalyst(.v26),
    ],
    products: [
        .library(name: "ArtifactCore", targets: ["ArtifactCore"]),
        .library(name: "ArtifactRenderer", targets: ["ArtifactRenderer"]),
        .library(name: "ArtifactView", targets: ["ArtifactView"]),
        .library(name: "ArtifactRendererNative", targets: ["ArtifactRendererNative"]),
        .library(name: "ArtifactRendererWeb", targets: ["ArtifactRendererWeb"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-markdown-ui.git", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "ArtifactCore"
        ),
        .target(
            name: "ArtifactRenderer",
            dependencies: ["ArtifactCore"]
        ),
        .target(
            name: "ArtifactView",
            dependencies: ["ArtifactCore", "ArtifactRenderer"]
        ),
        .target(
            name: "ArtifactRendererNative",
            dependencies: [
                "ArtifactCore",
                "ArtifactRenderer",
                "ArtifactView",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ]
        ),
        .target(
            name: "ArtifactRendererWeb",
            dependencies: ["ArtifactCore", "ArtifactRenderer", "ArtifactView"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ArtifactCoreTests",
            dependencies: ["ArtifactCore"]
        ),
        .testTarget(
            name: "ArtifactRendererTests",
            dependencies: [
                "ArtifactCore",
                "ArtifactRenderer",
                "ArtifactView",
                "ArtifactRendererNative",
                "ArtifactRendererWeb",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
