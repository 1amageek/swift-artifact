import Foundation
@preconcurrency import WebKit

/// Recycles `WKWebView` instances so renderers don't pay full initialization
/// cost every time an artifact appears.
///
/// `WKWebView` itself is `@MainActor`, so the pool is too. The contract is
/// simple: `acquire` returns a clean view (newly created or recycled), and
/// `release` resets the view's state before returning it to the pool. Use
/// inside SwiftUI views via `Coordinator` patterns where the view's lifecycle
/// matches the artifact's display lifecycle.
@MainActor
public final class WebViewPool {
    public static let shared = WebViewPool(capacity: 4)

    public let capacity: Int
    private var available: [WKWebView] = []

    public init(capacity: Int = 4) {
        self.capacity = max(0, capacity)
    }

    /// Take a clean `WKWebView`. A pre-configured one is returned if any
    /// remain; otherwise a fresh instance is created.
    public func acquire() -> WKWebView {
        if let view = available.popLast() {
            return view
        }
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        return WKWebView(frame: .zero, configuration: config)
    }

    /// Return a `WKWebView` to the pool. The view is reset; if the pool is
    /// already at capacity the view is dropped.
    public func release(_ view: WKWebView) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.loadHTMLString("", baseURL: nil)
        guard available.count < capacity else { return }
        available.append(view)
    }
}
