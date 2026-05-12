import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders CSV payloads as a scrollable `Grid`. `hasHeader` attribute (default
/// `"true"`) controls whether the first row is treated as column headers.
public struct CSVNativeRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .csv

    public init() {}

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        return artifact.isComplete ? .complete : .partial
    }

    public func body(artifact: AnyArtifact) -> some View {
        let hasHeader = (artifact.attributes["hasHeader"] ?? "true") != "false"
        let rows = CSVParser.parse(artifact.payload)
        let header: [String]
        let body: [[String]]
        if hasHeader, let first = rows.first {
            header = first
            body = Array(rows.dropFirst())
        } else {
            header = []
            body = rows
        }

        return ScrollView([.vertical, .horizontal]) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                if !header.isEmpty {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.callout.weight(.semibold))
                        }
                    }
                    Divider().gridCellColumns(max(header.count, 1))
                }
                ForEach(Array(body.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.callout)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 360)
    }
}

enum CSVParser {
    static func parse(_ source: String) -> [[String]] {
        var rows: [[String]] = []
        var fields: [String] = []
        var field = ""
        var insideQuotes = false
        var iterator = source.makeIterator()
        while let char = iterator.next() {
            if insideQuotes {
                if char == "\"" {
                    // Peek for escaped quote.
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            insideQuotes = false
                            // re-process `next`
                            if next == "," {
                                fields.append(field)
                                field = ""
                            } else if next == "\n" || next == "\r" {
                                fields.append(field)
                                field = ""
                                rows.append(fields)
                                fields = []
                            } else {
                                field.append(next)
                            }
                        }
                    } else {
                        insideQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case ",":
                    fields.append(field)
                    field = ""
                case "\n":
                    fields.append(field)
                    field = ""
                    rows.append(fields)
                    fields = []
                case "\r":
                    continue
                case "\"":
                    if field.isEmpty {
                        insideQuotes = true
                    } else {
                        field.append(char)
                    }
                default:
                    field.append(char)
                }
            }
        }
        if !field.isEmpty || !fields.isEmpty {
            fields.append(field)
            rows.append(fields)
        }
        return rows
    }
}

#Preview("Card — with header") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("csv1"),
            type: .csv,
            title: "Sales by region",
            payload: """
            Region,Q1,Q2,Q3,Q4
            North,120,134,148,162
            South,98,110,121,140
            East,75,82,91,99
            West,140,155,170,185
            """,
            isComplete: true
        ),
        renderer: CSVNativeRenderer()
    )
    .padding()
    .frame(width: 480)
}

#Preview("Bare — header disabled") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("csv2"),
            type: .csv,
            attributes: ["hasHeader": "false"],
            payload: "a,1,true\nb,2,false\nc,3,true",
            isComplete: true
        )
    )
    .artifactRenderer(CSVNativeRenderer())
    .padding()
    .frame(width: 360)
}
