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
}
