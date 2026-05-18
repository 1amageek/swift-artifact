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

    func artifactViewport(
        minHeight: CGFloat = 240,
        alignment: Alignment = .center
    ) -> some View {
        modifier(
            ArtifactViewportModifier(
                minHeight: minHeight,
                alignment: alignment
            )
        )
    }
}

public struct ArtifactBoundedScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let showsIndicators: Bool
    private let minHeight: CGFloat
    private let contentInsets: EdgeInsets
    private let content: Content

    @Environment(\.artifactContentMaxHeight) private var maxHeight
    @State private var measuredContentHeight: CGFloat = 0

    public init(
        _ axes: Axis.Set = .vertical,
        showsIndicators: Bool = true,
        minHeight: CGFloat = 0,
        contentInsets: EdgeInsets = EdgeInsets(),
        @ViewBuilder content: () -> Content
    ) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.minHeight = minHeight
        self.contentInsets = contentInsets
        self.content = content()
    }

    public var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content
                .padding(contentInsets)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ArtifactScrollContentHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
        .modifier(
            ArtifactMeasuredHeightLimitModifier(
                measuredHeight: measuredContentHeight,
                minHeight: minHeight
            )
        )
        .onPreferenceChange(ArtifactScrollContentHeightPreferenceKey.self) { height in
            guard height.isFinite, height > 0 else { return }
            guard abs(measuredContentHeight - height) > 0.5 else { return }
            measuredContentHeight = height
        }
    }
}

private struct ArtifactContentHeightLimitModifier: ViewModifier {
    @Environment(\.artifactContentMaxHeight) private var maxHeight

    func body(content: Content) -> some View {
        content.frame(maxHeight: maxHeight)
    }
}

private struct ArtifactViewportModifier: ViewModifier {
    @Environment(\.artifactContentMaxHeight) private var maxHeight

    let minHeight: CGFloat
    let alignment: Alignment

    func body(content: Content) -> some View {
        if let maxHeight {
            content.frame(
                maxWidth: .infinity,
                minHeight: min(minHeight, maxHeight),
                maxHeight: maxHeight,
                alignment: alignment
            )
        } else {
            content.frame(
                maxWidth: .infinity,
                minHeight: minHeight,
                maxHeight: .infinity,
                alignment: alignment
            )
        }
    }
}

private struct ArtifactMeasuredHeightLimitModifier: ViewModifier {
    @Environment(\.artifactContentMaxHeight) private var maxHeight

    let measuredHeight: CGFloat
    let minHeight: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if let maxHeight {
            if measuredHeight > 0 {
                let boundedHeight = min(max(measuredHeight, minHeight), maxHeight)
                content.frame(height: boundedHeight)
            } else {
                content.frame(maxHeight: maxHeight)
            }
        } else {
            content
        }
    }
}

private struct ArtifactScrollContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
