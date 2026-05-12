import SwiftUI

extension EnvironmentValues {
    /// Controls whether `ArtifactCard` shows its built-in expand/collapse
    /// disclosure button. `.hidden` keeps the card permanently expanded —
    /// useful when displaying a single artifact in its own view where
    /// collapsing has no meaning.
    @Entry public var artifactCardDisclosureVisibility: Visibility = .automatic
}

extension View {
    /// Override the visibility of an `ArtifactCard`'s disclosure button.
    public func artifactCardDisclosure(_ visibility: Visibility) -> some View {
        environment(\.artifactCardDisclosureVisibility, visibility)
    }
}
