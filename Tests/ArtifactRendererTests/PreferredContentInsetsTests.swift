import SwiftUI
import Testing
import ArtifactCore
import ArtifactRenderer
import ArtifactNativeRenderer
import ArtifactWebRenderer

@Suite("ArtifactRenderable.preferredContentInsets")
struct PreferredContentInsetsTests {

    private struct DefaultPreferenceRenderer: ArtifactRenderable, Sendable {
        static let artifactType: ArtifactType = .markdown
        func body(artifact: AnyArtifact, payload: String) -> some View {
            EmptyView()
        }
    }

    private struct ZeroPreferenceRenderer: ArtifactRenderable, Sendable {
        static let artifactType: ArtifactType = .html
        static let preferredContentInsets: EdgeInsets? = EdgeInsets()
        func body(artifact: AnyArtifact, payload: String) -> some View {
            EmptyView()
        }
    }

    @Test func defaultProtocolImplementationReturnsNil() {
        #expect(DefaultPreferenceRenderer.preferredContentInsets == nil)
    }

    @Test func explicitOverrideIsReadable() {
        #expect(ZeroPreferenceRenderer.preferredContentInsets == EdgeInsets())
    }

    @Test func anyArtifactRendererCapturesPreference() {
        let erased = AnyArtifactRenderer(ZeroPreferenceRenderer())
        #expect(erased.preferredContentInsets == EdgeInsets())
    }

    @Test func anyArtifactRendererPreservesNilForDefault() {
        let erased = AnyArtifactRenderer(DefaultPreferenceRenderer())
        #expect(erased.preferredContentInsets == nil)
    }

    // Verify the built-in edge-to-edge renderers actually opt out so that
    // host cards know to fill their chrome instead of stacking a margin.
    @Test func htmlWebViewRendererOptsOutOfPadding() {
        #expect(HTMLWebViewRenderer.preferredContentInsets == EdgeInsets())
    }

    @Test func geoJSONMapKitRendererOptsOutOfPadding() {
        #expect(GeoJSONMapKitRenderer.preferredContentInsets == EdgeInsets())
    }

    @Test func mermaidRendererOptsOutOfPadding() {
        #expect(MermaidRenderer.preferredContentInsets == EdgeInsets())
    }

    @Test func codeRendererOptsOutOfPadding() {
        #expect(CodeRenderer.preferredContentInsets == EdgeInsets())
    }

    @Test func markdownRendererOwnsItsReadingInset() {
        #expect(MarkdownRenderer.preferredContentInsets == EdgeInsets())
    }

    @Test func nativeSurfaceRenderersOptOutOfCardPadding() {
        #expect(CSVRenderer.preferredContentInsets == EdgeInsets())
        #expect(JSONRenderer.preferredContentInsets == EdgeInsets())
        #expect(SVGRenderer.preferredContentInsets == EdgeInsets())
        #expect(USDZModel3DRenderer.preferredContentInsets == EdgeInsets())
    }

    @Test func knowledgeGraphRenderersOptOutOfCardPadding() {
        #expect(TurtleRenderer.preferredContentInsets == EdgeInsets())
        #expect(TriGRenderer.preferredContentInsets == EdgeInsets())
        #expect(NQuadsRenderer.preferredContentInsets == EdgeInsets())
        #expect(RDFXMLRenderer.preferredContentInsets == EdgeInsets())
        #expect(JSONLDRenderer.preferredContentInsets == EdgeInsets())
    }

    @Test func webSurfaceRenderersOptOutOfCardPadding() {
        #expect(ReactWebViewRenderer.preferredContentInsets == EdgeInsets())
        #expect(VegaLiteWebViewRenderer.preferredContentInsets == EdgeInsets())
        #expect(LaTeXWebViewRenderer.preferredContentInsets == EdgeInsets())
    }
}
