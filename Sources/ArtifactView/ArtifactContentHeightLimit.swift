import SwiftUI

extension EnvironmentValues {
    @Entry public var artifactContentMaxHeight: CGFloat? = 360
}

public extension View {
    func artifactContentMaxHeight(_ maxHeight: CGFloat?) -> some View {
        environment(\.artifactContentMaxHeight, maxHeight)
    }

    func artifactContentHeightLimit() -> some View {
        modifier(ArtifactContentHeightLimitModifier())
    }
}

private struct ArtifactContentHeightLimitModifier: ViewModifier {
    @Environment(\.artifactContentMaxHeight) private var maxHeight

    func body(content: Content) -> some View {
        content.frame(maxHeight: maxHeight)
    }
}
