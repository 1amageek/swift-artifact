import ArtifactCore
import ArtifactRenderer
import ArtifactView
import Charts
import SwiftUI

/// Renders the portable chart artifact contract with Apple's Swift Charts.
public struct SwiftChartsRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .swiftCharts
    public static let preferredContentInsets: EdgeInsets? = EdgeInsets()

    public init() {}

    public static func refine(_ artifact: AnyArtifact) -> RefinedPayload {
        if artifact.isComplete {
            return .renderable(artifact.payload)
        }
        return .preRenderable(
            PreRenderableProgress(
                receivedCharacters: artifact.payload.count,
                hint: "waiting for complete chart JSON"
            )
        )
    }

    public func body(artifact: AnyArtifact, payload: String) -> some View {
        do {
            let spec = try ArtifactChartSpec(json: payload)
            try Self.validateRendererOptions(spec)
            return AnyView(_SwiftChartsArtifactView(spec: spec))
        } catch {
            return AnyView(
                Text("Chart unavailable: \(error.localizedDescription)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            )
        }
    }

    private static func validateRendererOptions(_ spec: ArtifactChartSpec) throws {
        for key in spec.options.keys where key != "showLegend" {
            throw ArtifactChartSpecError.unsupportedOption("options.\(key)")
        }
        if let showLegend = spec.options["showLegend"],
            case .boolean = showLegend
        {
            // Supported by the native renderer.
        } else if spec.options["showLegend"] != nil {
            throw ArtifactChartSpecError.unsupportedOption("options.showLegend")
        }
        for key in spec.mark.options.keys {
            throw ArtifactChartSpecError.unsupportedOption("mark.options.\(key)")
        }
    }
}

private struct _SwiftChartsArtifactView: View {
    let spec: ArtifactChartSpec

    var body: some View {
        Chart {
            chartContent()
        }
        .chartLegend(legendVisibility)
        .artifactViewport(minHeight: 280)
    }

    private var xField: ArtifactChartField? {
        spec.encoding["x"]
    }

    private var yField: ArtifactChartField? {
        spec.encoding["y"]
    }

    private var seriesField: ArtifactChartField? {
        spec.encoding["series"] ?? spec.encoding["color"]
    }

    private var legendVisibility: Visibility {
        if case .boolean(false) = spec.options["showLegend"] {
            return .hidden
        }
        return seriesField == nil ? .hidden : .visible
    }

    @ChartContentBuilder
    private func chartContent() -> some ChartContent {
        if spec.mark.type == .sector {
            sectorMarks()
        } else if spec.mark.type == .rule, xField == nil {
            yRuleMarks()
        } else if let xField {
            switch xField.type {
            case .quantitative:
                marks(xField: xField) { value(in: $0, field: xField.field)?.numberValue }
            case .temporal:
                marks(xField: xField) { value(in: $0, field: xField.field)?.dateValue }
            case .nominal, .ordinal:
                marks(xField: xField) { value(in: $0, field: xField.field)?.stringValue }
            }
        }
    }

    @ChartContentBuilder
    private func marks<X: Plottable>(
        xField: ArtifactChartField,
        xValue: @escaping (ArtifactChartDataRow) -> X?
    ) -> some ChartContent {
        ForEach(Array(spec.data.enumerated()), id: \.offset) { _, row in
            if let x = xValue(row) {
                if let mark = chartMark(row: row, x: x, xField: xField) {
                    mark
                }
            }
        }
    }

    @ChartContentBuilder
    private func yRuleMarks() -> some ChartContent {
        if let yField {
            ForEach(Array(spec.data.enumerated()), id: \.offset) { index, row in
                if let y = value(in: row, field: yField.field)?.numberValue {
                    styled(
                        RuleMark(y: .value(yField.label ?? yField.field, y)),
                        row: row
                    )
                }
            }
        }
    }

    @ChartContentBuilder
    private func sectorMarks() -> some ChartContent {
        if let angleField = spec.encoding["angle"] {
            ForEach(Array(spec.data.enumerated()), id: \.offset) { _, row in
                if let angle = value(in: row, field: angleField.field)?.numberValue {
                    styled(
                        SectorMark(angle: .value(angleField.label ?? angleField.field, angle)),
                        row: row
                    )
                }
            }
        }
    }

    private func chartMark<X: Plottable>(
        row: ArtifactChartDataRow,
        x: X,
        xField: ArtifactChartField
    ) -> AnyChartContent? {
        guard let yField,
            let y = value(in: row, field: yField.field)?.numberValue
        else {
            return nil
        }

        let xLabel = xField.label ?? xField.field
        let yLabel = yField.label ?? yField.field
        switch spec.mark.type {
        case .line:
            return styled(
                LineMark(x: .value(xLabel, x), y: .value(yLabel, y)),
                row: row
            )
        case .bar:
            return styled(
                BarMark(x: .value(xLabel, x), y: .value(yLabel, y)),
                row: row
            )
        case .area:
            return styled(
                AreaMark(x: .value(xLabel, x), y: .value(yLabel, y)),
                row: row
            )
        case .point:
            return styled(
                PointMark(x: .value(xLabel, x), y: .value(yLabel, y)),
                row: row
            )
        case .rectangle:
            return styled(
                RectangleMark(x: .value(xLabel, x), y: .value(yLabel, y)),
                row: row
            )
        case .rule:
            return styled(
                RuleMark(x: .value(xLabel, x)),
                row: row
            )
        default:
            return nil
        }
    }

    private func styled<Content: ChartContent>(
        _ mark: Content,
        row: ArtifactChartDataRow
    ) -> AnyChartContent {
        guard let seriesField,
            let series = value(in: row, field: seriesField.field)?.stringValue
        else {
            return AnyChartContent(erasing: mark)
        }
        return AnyChartContent(
            erasing: mark.foregroundStyle(
                by: .value(seriesField.label ?? seriesField.field, series)
            ))
    }

    private func value(
        in row: ArtifactChartDataRow,
        field: String
    ) -> ArtifactChartValue? {
        row[field]
    }
}

extension ArtifactChartValue {
    fileprivate var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    fileprivate var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    fileprivate var dateValue: Date? {
        guard case .string(let value) = self else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

#Preview("Swift Charts gallery") {
    ScrollView {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 500), spacing: 20)],
            spacing: 20
        ) {
            ForEach(["line", "bar", "area", "point", "rectangle", "rule"], id: \.self) { mark in
                ArtifactCard(
                    AnyArtifact(
                        id: ArtifactIdentifier("chart-preview-\(mark)"),
                        type: .swiftCharts,
                        title: mark.capitalized,
                        payload: """
                            {
                              "version": 1,
                              "dimension": "2d",
                              "mark": { "type": "\(mark)" },
                              "data": [
                                { "category": "A", "value": 4, "series": "First" },
                                { "category": "B", "value": 7, "series": "First" },
                                { "category": "C", "value": 5, "series": "Second" },
                                { "category": "D", "value": 9, "series": "Second" },
                                { "category": "E", "value": 6, "series": "First" },
                                { "category": "F", "value": 11, "series": "Second" },
                                { "category": "G", "value": 8, "series": "First" },
                                { "category": "H", "value": 13, "series": "Second" },
                                { "category": "I", "value": 10, "series": "First" },
                                { "category": "J", "value": 15, "series": "Second" },
                                { "category": "K", "value": 12, "series": "First" },
                                { "category": "L", "value": 17, "series": "Second" }
                              ],
                              "encoding": {
                                "x": { "field": "category", "type": "nominal", "label": "Category" },
                                "y": { "field": "value", "type": "quantitative", "label": "Value" },
                                "series": { "field": "series", "type": "nominal", "label": "Series" }
                              },
                              "options": { "showLegend": true }
                            }
                            """,
                        isComplete: true
                    ),
                    renderer: SwiftChartsRenderer()
                )
                .frame(minHeight: 300)
            }

            ArtifactCard(
                AnyArtifact(
                    id: ArtifactIdentifier("chart-preview-sector"),
                    type: .swiftCharts,
                    title: "Sector",
                    payload: """
                        {
                          "version": 1,
                          "dimension": "2d",
                          "mark": { "type": "sector" },
                          "data": [
                            { "amount": 40, "series": "Completed" },
                            { "amount": 35, "series": "In progress" },
                            { "amount": 25, "series": "Remaining" },
                            { "amount": 18, "series": "Blocked" },
                            { "amount": 12, "series": "Planned" }
                          ],
                          "encoding": {
                            "angle": { "field": "amount", "type": "quantitative", "label": "Amount" },
                            "series": { "field": "series", "type": "nominal", "label": "Status" }
                          },
                          "options": { "showLegend": true }
                        }
                        """,
                    isComplete: true
                ),
                renderer: SwiftChartsRenderer()
            )
            .frame(minHeight: 300)
        }
        .padding()
    }
    .frame(width: 1120, height: 1200)
}
