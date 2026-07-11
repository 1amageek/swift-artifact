import Foundation
import SwiftUI
import ArtifactView

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct RasterImageRendererBody: View {
    let payload: String
    let title: String
    let formatName: String

    @State private var state: RasterImageLoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            case let .loaded(image):
                imageView(image)
            case let .failed(message):
                unavailable(message)
            }
        }
        .task(id: payload) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        state = .loading
        do {
            let data = try await ArtifactBinaryDataLoader.shared.data(from: payload)
            state = try .loaded(decodedImage(from: data))
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func decodedImage(from data: Data) throws -> LoadedRasterImage {
        #if canImport(AppKit)
        if let image = NSImage(data: data) {
            return LoadedRasterImage(
                image: Image(nsImage: image),
                aspectRatio: RasterImageLayout.aspectRatio(for: image.size)
            )
        }
        throw ArtifactBinaryPayloadError.unsupportedPayload
        #elseif canImport(UIKit)
        if let image = UIImage(data: data) {
            return LoadedRasterImage(
                image: Image(uiImage: image),
                aspectRatio: RasterImageLayout.aspectRatio(for: image.size)
            )
        }
        throw ArtifactBinaryPayloadError.unsupportedPayload
        #else
        throw ArtifactBinaryPayloadError.unsupportedPayload
        #endif
    }

    private func imageView(_ loaded: LoadedRasterImage) -> some View {
        RasterImageAspectLayout(aspectRatio: loaded.aspectRatio) {
            loaded.image
                .resizable()
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView(
            title.isEmpty ? formatName : title,
            systemImage: "photo",
            description: Text(message)
        )
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

private enum RasterImageLoadState {
    case loading
    case loaded(LoadedRasterImage)
    case failed(String)
}

private struct LoadedRasterImage {
    let image: Image
    let aspectRatio: CGFloat
}

enum RasterImageLayout {
    static func aspectRatio(for size: CGSize) -> CGFloat {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else {
            return 1
        }
        return size.width / size.height
    }

    static func contentSize(forWidth width: CGFloat, aspectRatio: CGFloat) -> CGSize {
        guard width.isFinite,
              width > 0,
              aspectRatio.isFinite,
              aspectRatio > 0
        else {
            return .zero
        }
        return CGSize(width: width, height: width / aspectRatio)
    }
}

private struct RasterImageAspectLayout: Layout {
    let aspectRatio: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        if let width = proposal.width {
            return RasterImageLayout.contentSize(
                forWidth: width,
                aspectRatio: aspectRatio
            )
        }

        let fallback = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return RasterImageLayout.contentSize(
            forWidth: fallback.width,
            aspectRatio: aspectRatio
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
