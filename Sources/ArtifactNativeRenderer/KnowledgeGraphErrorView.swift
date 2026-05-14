import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Error UI for the RDF renderer family.
///
/// Visually parallels `MermaidErrorView`: a `ContentUnavailableView` with the
/// parse-error message, plus a collapsed "Show source" panel underneath so
/// the user can inspect (and copy) the raw payload that failed.
///
/// Source is collapsed by default — RDF documents are often long, and the
/// error message alone is usually enough to diagnose the issue. Expanding
/// reveals a scrollable monospaced view with selection enabled.
struct KnowledgeGraphErrorView: View {
    let error: Error
    let source: String

    @State private var isSourceExpanded = false
    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 12) {
            ContentUnavailableView {
                Label("Cannot render graph", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
                    .font(.footnote)
                    .monospaced()
                    .multilineTextAlignment(.leading)
            }

            sourcePanel
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isSourceExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isSourceExpanded ? 90 : 0))
                            .imageScale(.small)
                        Text(isSourceExpanded ? "Hide source" : "Show source")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                if isSourceExpanded {
                    Button {
                        copy()
                    } label: {
                        Label(
                            didCopy ? "Copied" : "Copy",
                            systemImage: didCopy ? "checkmark" : "doc.on.doc"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if isSourceExpanded {
                ScrollView {
                    Text(source)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary)
                )
            }
        }
    }

    private func copy() {
        copyToPasteboard(source)
        didCopy = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
                didCopy = false
            } catch {
                // Cancelled by a newer copy press — the newer Task resets the flag.
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
