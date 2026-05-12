import SwiftUI
@preconcurrency import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shared SwiftUI representable used by every web renderer. Owns the
/// `WKWebView` lifetime via the pool and reloads when `html` changes.
public struct ArtifactWebView {
    public let html: String
    public let baseURL: URL?
    public let minHeight: CGFloat

    public init(html: String, baseURL: URL? = nil, minHeight: CGFloat = 280) {
        self.html = html
        self.baseURL = baseURL
        self.minHeight = minHeight
    }
}

#if canImport(UIKit)
extension ArtifactWebView: UIViewRepresentable {
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> WKWebView {
        let view = WebViewPool.shared.acquire()
        context.coordinator.attach(view)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.loadHTMLString(html, baseURL: baseURL)
        return view
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        uiView.loadHTMLString(html, baseURL: baseURL)
    }

    public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        WebViewPool.shared.release(uiView)
    }
}

@MainActor
public final class _ArtifactWebViewCoordinator {
    fileprivate(set) var lastHTML: String = ""
    fileprivate weak var view: WKWebView?

    fileprivate func attach(_ view: WKWebView) {
        self.view = view
    }
}

extension ArtifactWebView {
    public typealias Coordinator = _ArtifactWebViewCoordinator
}
#elseif canImport(AppKit)
extension ArtifactWebView: NSViewRepresentable {
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> WKWebView {
        let view = WebViewPool.shared.acquire()
        context.coordinator.attach(view)
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(html, baseURL: baseURL)
        return view
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        nsView.loadHTMLString(html, baseURL: baseURL)
    }

    public static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        WebViewPool.shared.release(nsView)
    }
}

@MainActor
public final class _ArtifactWebViewCoordinator {
    fileprivate(set) var lastHTML: String = ""
    fileprivate weak var view: WKWebView?

    fileprivate func attach(_ view: WKWebView) {
        self.view = view
    }
}

extension ArtifactWebView {
    public typealias Coordinator = _ArtifactWebViewCoordinator
}
#endif

#Preview("Inline document") {
    ArtifactWebView(
        html: """
        <!doctype html>
        <html>
          <body style="font-family:-apple-system;padding:24px;">
            <h2>WKWebView preview</h2>
            <p>Used as the rendering surface for every web-backed renderer.</p>
          </body>
        </html>
        """
    )
    .frame(width: 460, height: 320)
    .padding()
}
