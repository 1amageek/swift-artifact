import SwiftUI

extension EnvironmentValues {
    /// Inner padding applied between an `ArtifactCard`'s frame and its content
    /// slot. Renderers that want edge-to-edge content (maps, large media) can
    /// override with `.zero`; the default leaves room for textual bodies.
    @Entry public var artifactCardContentInsets: EdgeInsets = EdgeInsets(
        top: 12, leading: 12, bottom: 12, trailing: 12
    )
}

extension View {
    /// Override the inner padding of any `ArtifactCard` below this view.
    public func artifactCardContentInsets(_ insets: EdgeInsets) -> some View {
        environment(\.artifactCardContentInsets, insets)
    }
}
