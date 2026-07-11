import ArtifactCore
import SwiftUI

extension EnvironmentValues {
    @Entry public var artifactFileResolver: any ArtifactFileResolving = ArtifactFileResolver.shared
}

extension View {
    public func artifactFileResolver(
        _ resolver: some ArtifactFileResolving
    ) -> some View {
        environment(\.artifactFileResolver, resolver)
    }
}
