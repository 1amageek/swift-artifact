import SwiftUI
import RealityKit
import simd
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders a USDZ asset inline using RealityKit's `RealityView`. The payload
/// is a URL string (`file://`, `http://`, or `https://`); remote URLs are
/// fetched to a temporary file before being handed to `Entity(contentsOf:)`.
///
/// Caching, authentication, and persistent storage are intentionally outside
/// this renderer's responsibility — the app is expected to either pre-download
/// the asset and pass a `file://` URL, or rely on the renderer's transient
/// fetch.
public struct USDZModel3DRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .usdz

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        let payload = artifact.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard artifact.isComplete, URL(string: payload) != nil else {
            return .preRenderable(
                PreRenderableProgress(
                    receivedCharacters: payload.count,
                    hint: "waiting for complete URL"
                )
            )
        }
        return .renderable(payload)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        USDZModel3DView(payload: payload)
    }
}

private struct USDZModel3DView: View {
    let payload: String

    @State private var sceneRoot: Entity?
    @State private var loadFailed: Bool = false

    @State private var committedScale: Float = 1.0
    @State private var committedRotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0])
    @GestureState private var gestureMagnify: CGFloat = 1.0
    @GestureState private var gestureDrag: CGSize = .zero

    private let minScale: Float = 0.1
    private let maxScale: Float = 20.0
    private let rotationSensitivity: Float = 0.01
    private static let pivotName = "artifact.usdz.pivot"

    var body: some View {
        Group {
            if let sceneRoot {
                RealityView { content in
                    content.add(sceneRoot)
                } update: { _ in
                    if let pivot = sceneRoot.findEntity(named: Self.pivotName) {
                        apply(to: pivot)
                    }
                }
                .frame(minHeight: 240, maxHeight: 360)
                .gesture(rotateGesture())
                .simultaneousGesture(zoomGesture())
                .onTapGesture(count: 2) { resetTransform() }
            } else if loadFailed {
                ContentUnavailableView(
                    "Failed to load 3D model",
                    systemImage: "exclamationmark.triangle"
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task(id: payload) {
            await loadEntity()
        }
    }

    private func loadEntity() async {
        sceneRoot = nil
        loadFailed = false
        committedScale = 1.0
        committedRotation = simd_quatf(angle: 0, axis: [0, 1, 0])
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            loadFailed = true
            return
        }
        do {
            let fileURL = try await USDZAssetLoader.localFileURL(for: url)
            let loaded = try await Entity(contentsOf: fileURL)

            // Wrap in a pivot so gestures transform the pivot instead of the
            // asset itself. Scene composition (camera, lighting, framing) is
            // the asset author's responsibility — we render whatever the USDZ
            // ships with.
            let pivot = Entity()
            pivot.name = Self.pivotName
            pivot.addChild(loaded)
            sceneRoot = pivot
        } catch is CancellationError {
            // The view was replaced — leave state for the next load to update.
        } catch {
            loadFailed = true
        }
    }

    private func apply(to entity: Entity) {
        let pinch = max(0.05, Float(gestureMagnify))
        let scale = max(minScale, min(maxScale, committedScale * pinch))
        let dragRotation = rotationFromDrag(gestureDrag)
        entity.transform.scale = SIMD3<Float>(repeating: scale)
        entity.transform.rotation = dragRotation * committedRotation
    }

    private func rotationFromDrag(_ translation: CGSize) -> simd_quatf {
        let yaw = Float(translation.width) * rotationSensitivity
        let pitch = Float(translation.height) * rotationSensitivity
        let yawQ = simd_quatf(angle: yaw, axis: [0, 1, 0])
        let pitchQ = simd_quatf(angle: pitch, axis: [1, 0, 0])
        return yawQ * pitchQ
    }

    private func zoomGesture() -> some Gesture {
        MagnifyGesture()
            .updating($gestureMagnify) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                let pinch = max(0.05, Float(value.magnification))
                committedScale = max(minScale, min(maxScale, committedScale * pinch))
            }
    }

    private func rotateGesture() -> some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($gestureDrag) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                committedRotation = rotationFromDrag(value.translation) * committedRotation
            }
    }

    private func resetTransform() {
        committedScale = 1.0
        committedRotation = simd_quatf(angle: 0, axis: [0, 1, 0])
    }
}

/// Resolves a USDZ source URL to a local `file://` URL. File URLs pass
/// through; remote URLs are downloaded into the caller's temporary directory.
enum USDZAssetLoader {
    static func localFileURL(for url: URL) async throws -> URL {
        if url.isFileURL { return url }
        let (downloaded, _) = try await URLSession.shared.download(from: url)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "artifact-\(UUID().uuidString).usdz"
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }
}

#Preview("Card — USDZ URL") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("usdz1"),
            type: .usdz,
            title: "Toy car",
            payload: "https://developer.apple.com/augmented-reality/quick-look/models/toycar/toy_car.usdz",
            isComplete: true
        ),
        renderer: USDZModel3DRenderer()
    )
    .padding()
    .frame(width: 480, height: 480)
}

#Preview("Bare — invalid URL") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("usdz2"),
            type: .usdz,
            payload: "",
            isComplete: true
        )
    )
    .artifactRenderer(USDZModel3DRenderer())
    .padding()
    .frame(width: 360, height: 200)
}
