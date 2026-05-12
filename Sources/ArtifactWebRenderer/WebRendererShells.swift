import Foundation

/// HTML shells for the WebKit-backed renderers.
///
/// The shells reference CDN URLs in this MVP build. To run fully offline,
/// replace the `<script src>` tags with file URLs pointing at JS resources
/// bundled in `Resources/`. The renderer surface does not change.
enum WebRendererShells {

    static func html(payload: String) -> String { payload }

    static func react(payload: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:light dark}html,body{margin:0;padding:12px;font-family:-apple-system,system-ui,sans-serif;background:transparent;color:light-dark(#111,#eee)}</style>
        <script crossorigin src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
        <script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
        <script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
        </head>
        <body>
        <div id="root"></div>
        <script type="text/babel" data-presets="env,react">
        \(payload)
        const __default = (typeof exports !== 'undefined' && exports.default) || (typeof module !== 'undefined' && module.exports && module.exports.default) || (typeof Counter !== 'undefined' ? Counter : null);
        const __root = ReactDOM.createRoot(document.getElementById('root'));
        const Comp = (typeof exports !== 'undefined' && exports.default) ? exports.default : (typeof window.__ARTIFACT_DEFAULT__ !== 'undefined' ? window.__ARTIFACT_DEFAULT__ : null);
        if (Comp) { __root.render(React.createElement(Comp)); }
        </script>
        </body>
        </html>
        """
    }

    static func vegaLite(payload: String) -> String {
        let escaped = payload.replacingOccurrences(of: "</script>", with: "<\\/script>")
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:light dark}html,body{margin:0;padding:12px;background:transparent;color:light-dark(#111,#eee);font-family:-apple-system,system-ui,sans-serif}#chart{display:flex;justify-content:center}</style>
        <script src="https://cdn.jsdelivr.net/npm/vega@5"></script>
        <script src="https://cdn.jsdelivr.net/npm/vega-lite@5"></script>
        <script src="https://cdn.jsdelivr.net/npm/vega-embed@6"></script>
        </head>
        <body>
        <div id="chart"></div>
        <script>
        const spec = \(escaped);
        vegaEmbed('#chart', spec, {actions: false}).catch(console.error);
        </script>
        </body>
        </html>
        """
    }

    static func latex(payload: String, displayMode: Bool) -> String {
        let escaped = payload
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        // `color-scheme: light dark` lets WKWebView pick up the system
        // appearance; `light-dark()` resolves the text color in CSS so KaTeX
        // glyphs (which inherit `color`) are legible in both modes.
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
        <style>:root{color-scheme:light dark}html,body{margin:0;padding:12px;background:transparent;color:light-dark(#111,#eee);font-family:-apple-system,system-ui,sans-serif;font-size:1.1em}#math{display:flex;justify-content:center;align-items:center;min-height:60px}</style>
        </head>
        <body>
        <div id="math"></div>
        <script>
        katex.render("\(escaped)", document.getElementById('math'), {throwOnError: false, displayMode: \(displayMode)});
        </script>
        </body>
        </html>
        """
    }
}
