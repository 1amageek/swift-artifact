import SwiftUI
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders CSV payloads as a spreadsheet-style table. The first row is
/// treated as the column header unless `hasHeader="false"` is set on the
/// artifact. See `CSVTableView` for the visual contract (sticky header,
/// type-aware alignment, zebra striping, lazy body rendering, and copy
/// affordances).
public struct CSVRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .csv

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        // Quote-aware truncation: newlines inside `"..."` fields are not row
        // terminators. See `PartialCSVScanner`.
        guard let prefix = PartialCSVScanner.longestValidPrefix(artifact.payload) else {
            return .preRenderable(
                PreRenderableProgress(
                    receivedCharacters: artifact.payload.count,
                    hint: "waiting for first complete row"
                )
            )
        }
        return .renderable(prefix)
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        let hasHeader = (artifact.attributes["hasHeader"] ?? "true") != "false"
        let rows = CSVParser.parse(payload)
        let header: [String]
        let body: [[String]]
        if hasHeader, let first = rows.first {
            header = first
            body = Array(rows.dropFirst())
        } else {
            header = []
            body = rows
        }
        return CSVTableView(header: header, rows: body)
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
        renderer: CSVRenderer()
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
    .artifactRenderer(CSVRenderer())
    .padding()
    .frame(width: 360)
}

#Preview("Streaming — chunked at 0.3s") {
    StreamingPreviewHarness(
        id: ArtifactIdentifier("csv3"),
        type: .csv,
        title: "Quarterly sales",
        fullPayload: """
        Region,Q1,Q2,Q3,Q4,YTD
        North,120,134,148,162,564
        South,98,110,121,140,469
        East,75,82,91,99,347
        West,140,155,170,185,650
        Central,88,95,102,118,403
        """,
        chunkSize: 5,
        interval: .milliseconds(300)
    ) { artifact in
        ArtifactCard(artifact)
    }
    .artifactRenderer(CSVRenderer())
    .padding()
    .frame(width: 520, height: 460)
}
