import Foundation
import Testing

@testable import ArtifactCore

@Suite("Artifact chart specification")
struct ArtifactChartSpecTests {
    private let lineJSON = """
        {
          "version": 1,
          "dimension": "2d",
          "mark": { "type": "line" },
          "data": [
            { "date": "2026-09-01T00:00:00Z", "value": 4.5, "series": "A" },
            { "date": "2026-09-02T00:00:00Z", "value": 7.0, "series": "A" }
          ],
          "encoding": {
            "x": { "field": "date", "type": "temporal", "label": "Day" },
            "y": { "field": "value", "type": "quantitative", "label": "Value" },
            "series": { "field": "series", "type": "nominal" }
          },
          "options": { "showLegend": true },
          "extensions": { "com.example.note": { "source": "agent" } }
        }
        """

    @Test func decodesAndRoundTripsDynamicChannelsAndValues() throws {
        let spec = try ArtifactChartSpec(json: lineJSON)
        #expect(spec.mark.type == .line)
        #expect(spec.encoding["x"]?.type == .temporal)
        #expect(spec.encoding["series"]?.field == "series")
        #expect(spec.options["showLegend"] == .boolean(true))
        #expect(spec.extensions["com.example.note"] == .object(["source": .string("agent")]))

        let encoded = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(ArtifactChartSpec.self, from: encoded)
        #expect(decoded == spec)
    }

    @Test func directDecoderValidatesSchema() throws {
        let json = lineJSON.replacing("\"version\": 1", with: "\"version\": 2")
        do {
            _ = try JSONDecoder().decode(ArtifactChartSpec.self, from: Data(json.utf8))
            Issue.record("Expected unsupported version")
        } catch let error as ArtifactChartSpecError {
            #expect(error == .unsupportedVersion(2))
        }
    }

    @Test func rejectsMissingRequiredChannel() {
        let json = """
            {"version":1,"dimension":"2d","mark":{"type":"line"},"data":[{"value":1}],"encoding":{"y":{"field":"value","type":"quantitative"}}}
            """
        expectError(.missingChannel("x"), json: json)
    }

    @Test func rejectsInvalidTemporalValue() {
        let json = """
            {"version":1,"dimension":"2d","mark":{"type":"point"},"data":[{"date":"tomorrow","value":1}],"encoding":{"x":{"field":"date","type":"temporal"},"y":{"field":"value","type":"quantitative"}}}
            """
        expectError(.invalidDate(row: 0, field: "date"), json: json)
    }

    @Test func rejectsNonPositiveSectorValue() {
        let json = """
            {"version":1,"dimension":"2d","mark":{"type":"sector"},"data":[{"amount":0}],"encoding":{"angle":{"field":"amount","type":"quantitative"}}}
            """
        expectError(.invalidSectorValue(row: 0, field: "amount"), json: json)
    }

    @Test func rejectsNonFiniteNumbers() {
        let data = [ArtifactChartDataRow(values: ["x": .number(.infinity), "y": .number(1)])]
        do {
            _ = try ArtifactChartSpec(
                mark: ArtifactChartMarkConfiguration(type: .line),
                data: data,
                encoding: ArtifactChartEncoding(channels: [
                    "x": ArtifactChartField(field: "x", type: .quantitative),
                    "y": ArtifactChartField(field: "y", type: .quantitative),
                ])
            )
            Issue.record("Expected non-finite number rejection")
        } catch let error as ArtifactChartSpecError {
            #expect(error == .nonFiniteNumber)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func acceptsEverySupportedMarkWithItsRequiredChannels() throws {
        let data = [ArtifactChartDataRow(values: ["x": .string("A"), "y": .number(1)])]
        let encoding = ArtifactChartEncoding(channels: [
            "x": ArtifactChartField(field: "x", type: .nominal),
            "y": ArtifactChartField(field: "y", type: .quantitative),
        ])
        for mark in [ArtifactChartMark.area, .bar, .line, .point, .rectangle] {
            _ = try ArtifactChartSpec(
                mark: ArtifactChartMarkConfiguration(type: mark),
                data: data,
                encoding: encoding
            )
        }
        _ = try ArtifactChartSpec(
            mark: ArtifactChartMarkConfiguration(type: .rule),
            data: data,
            encoding: encoding
        )
        _ = try ArtifactChartSpec(
            mark: ArtifactChartMarkConfiguration(type: .sector),
            data: [ArtifactChartDataRow(values: ["amount": .number(1)])],
            encoding: ArtifactChartEncoding(channels: [
                "angle": ArtifactChartField(field: "amount", type: .quantitative)
            ])
        )
    }

    private func expectError(_ expected: ArtifactChartSpecError, json: String) {
        do {
            _ = try ArtifactChartSpec(json: json)
            Issue.record("Expected \(expected)")
        } catch let error as ArtifactChartSpecError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
