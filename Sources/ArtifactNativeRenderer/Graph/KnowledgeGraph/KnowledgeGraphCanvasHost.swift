import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Platform host that wraps the `KnowledgeGraphView` `Canvas` so native
/// scroll and pinch events can drive the viewport directly.
///
/// SwiftUI's gesture system on its own does not deliver macOS
/// `scrollWheel` events to a plain `Canvas`, and on iPad / Mac Catalyst /
/// visionOS the two-finger trackpad scroll is similarly invisible to
/// `DragGesture`. This view wraps the content in an `NSView` (macOS) or
/// `UIView` (everywhere else) that subscribes to the platform events and
/// forwards them through `onScroll(delta:location:)` and — on macOS only —
/// `onMagnify(magnification:location:)`.
///
/// Coordinates are reported in the host view's local space with a top-left
/// origin so the value can be fed straight into
/// `KnowledgeGraphViewport.zoomed(to:anchor:)`.
struct KnowledgeGraphCanvasHost<Content: View>: View {

    let onScroll: @MainActor (CGSize, CGPoint) -> Void
    let onMagnify: @MainActor (CGFloat, CGPoint) -> Void
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        AppKitHost(onScroll: onScroll, onMagnify: onMagnify, content: content)
        #else
        UIKitHost(onScroll: onScroll, content: content)
        #endif
    }
}

// MARK: - macOS host

#if os(macOS)

private struct AppKitHost<Content: View>: NSViewRepresentable {

    let onScroll: @MainActor (CGSize, CGPoint) -> Void
    let onMagnify: @MainActor (CGFloat, CGPoint) -> Void
    let content: Content

    func makeNSView(context: Context) -> CanvasNSView<Content> {
        let view = CanvasNSView<Content>()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        let hosting = CanvasNSHostingView(rootView: content)
        hosting.eventSink = view
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.hostingView = hosting
        return view
    }

    func updateNSView(_ nsView: CanvasNSView<Content>, context: Context) {
        nsView.onScroll = onScroll
        nsView.onMagnify = onMagnify
        nsView.hostingView?.rootView = content
    }
}

final class CanvasNSView<Content: View>: NSView {

    var onScroll: (@MainActor (CGSize, CGPoint) -> Void)?
    var onMagnify: (@MainActor (CGFloat, CGPoint) -> Void)?
    weak var hostingView: NSHostingView<Content>?

    override func scrollWheel(with event: NSEvent) {
        handleScroll(event)
    }

    override func magnify(with event: NSEvent) {
        handleMagnify(event)
    }

    func handleScroll(_ event: NSEvent) {
        let dx: CGFloat
        let dy: CGFloat
        if event.hasPreciseScrollingDeltas {
            dx = event.scrollingDeltaX
            dy = event.scrollingDeltaY
        } else {
            // Line-mode scrolling (notched mice) reports ~1.0 per notch;
            // multiply so a notch yields a perceptible pan distance.
            dx = event.scrollingDeltaX * 10
            dy = event.scrollingDeltaY * 10
        }
        let location = flippedLocation(from: event)
        MainActor.assumeIsolated {
            onScroll?(CGSize(width: dx, height: dy), location)
        }
    }

    func handleMagnify(_ event: NSEvent) {
        let location = flippedLocation(from: event)
        MainActor.assumeIsolated {
            onMagnify?(event.magnification, location)
        }
    }

    /// Convert an `NSEvent` window location into this view's local space
    /// with a top-left origin so the result can be used directly as a
    /// SwiftUI-space anchor point.
    private func flippedLocation(from event: NSEvent) -> CGPoint {
        let location = convert(event.locationInWindow, from: nil)
        return CGPoint(x: location.x, y: bounds.height - location.y)
    }
}

/// `NSHostingView` subclass that forwards scroll and magnify events back to
/// the outer `CanvasNSView`. Without this hook the SwiftUI hosting view
/// consumes the events before they reach the responder chain, leaving the
/// outer NSView's overrides silent.
final class CanvasNSHostingView<Content: View>: NSHostingView<Content> {

    weak var eventSink: CanvasNSView<Content>?

    override func scrollWheel(with event: NSEvent) {
        if let sink = eventSink {
            sink.handleScroll(event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        if let sink = eventSink {
            sink.handleMagnify(event)
        } else {
            super.magnify(with: event)
        }
    }
}

#endif // os(macOS)

// MARK: - iOS / visionOS / Mac Catalyst host

#if !os(macOS)

private struct UIKitHost<Content: View>: UIViewRepresentable {

    let onScroll: @MainActor (CGSize, CGPoint) -> Void
    let content: Content

    func makeUIView(context: Context) -> CanvasUIView<Content> {
        let view = CanvasUIView<Content>()
        view.onScroll = onScroll
        let hosting = UIHostingController(rootView: content)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.hostingController = hosting
        return view
    }

    func updateUIView(_ uiView: CanvasUIView<Content>, context: Context) {
        uiView.onScroll = onScroll
        uiView.hostingController?.rootView = content
    }
}

final class CanvasUIView<Content: View>: UIView {

    var onScroll: (@MainActor (CGSize, CGPoint) -> Void)?
    var hostingController: UIHostingController<Content>?

    /// Cumulative translation reported by `UIPanGestureRecognizer`; the
    /// `onScroll` callback wants per-event deltas so we subtract from the
    /// previous value on every `.changed` callback.
    private var lastPanTranslation: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureGesture()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureGesture()
    }

    private func configureGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        // Two-finger touch pan, plus trackpad / Magic Mouse scroll on
        // iPadOS / Mac Catalyst / visionOS via `allowedScrollTypesMask`.
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedScrollTypesMask = .all
        addGestureRecognizer(pan)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            lastPanTranslation = .zero
        case .changed:
            let delta = CGSize(
                width: translation.x - lastPanTranslation.x,
                height: translation.y - lastPanTranslation.y
            )
            lastPanTranslation = translation
            let location = gesture.location(in: self)
            MainActor.assumeIsolated {
                onScroll?(delta, location)
            }
        case .ended, .cancelled:
            lastPanTranslation = .zero
        default:
            break
        }
    }
}

#endif // !os(macOS)
