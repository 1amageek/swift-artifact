import SwiftUI

/// Package-level fallback insets used when neither the host environment nor
/// the resolved renderer specifies a preference. Sized for textual bodies.
public let defaultArtifactCardContentInsets = EdgeInsets(
    top: 12, leading: 12, bottom: 12, trailing: 12
)

extension EnvironmentValues {
    /// Explicit override for the inner padding between an `ArtifactCard`'s
    /// frame and its content slot. `nil` means "consult the resolved
    /// renderer's ``ArtifactRenderable/preferredContentInsets`` (Map / HTML
    /// WebView opt out edge-to-edge), and otherwise fall back to
    /// ``defaultArtifactCardContentInsets``".
    @Entry public var artifactCardContentInsets: EdgeInsets? = nil
}

extension View {
    /// Override the inner padding of any `ArtifactCard` below this view.
    /// Once set, this takes precedence over each renderer's
    /// `preferredContentInsets`.
    public func artifactCardContentInsets(_ insets: EdgeInsets) -> some View {
        environment(\.artifactCardContentInsets, insets)
    }
}
