import Foundation

/// A JSON value used by the portable chart contract.
public enum ArtifactChartValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([ArtifactChartValue])
    case object([String: ArtifactChartValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        do {
            self = .boolean(try container.decode(Bool.self))
            return
        } catch {
            // Probe the remaining JSON shapes.
        }

        do {
            let value = try container.decode(Double.self)
            guard value.isFinite else {
                throw ArtifactChartSpecError.nonFiniteNumber
            }
            self = .number(value)
            return
        } catch let error as ArtifactChartSpecError {
            throw error
        } catch {
            // Probe the remaining JSON shapes.
        }

        do {
            self = .string(try container.decode(String.self))
            return
        } catch {
            // Probe the remaining JSON shapes.
        }

        do {
            self = .array(try container.decode([ArtifactChartValue].self))
            return
        } catch {
            // Probe the final JSON shape.
        }

        do {
            self = .object(try container.decode([String: ArtifactChartValue].self))
            return
        } catch {
            throw DecodingError.typeMismatch(
                ArtifactChartValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw ArtifactChartSpecError.nonFiniteNumber
            }
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// The chart dimension supported by a chart artifact.
public enum ArtifactChartDimension: String, Codable, Sendable, Equatable, Hashable {
    case twoD = "2d"
    case threeD = "3d"
}

/// A chart value category used to convert JSON values into Swift Charts
/// plottable values.
public enum ArtifactChartValueType: String, Codable, Sendable, Equatable, Hashable {
    case quantitative
    case temporal
    case nominal
    case ordinal
}

/// An open-ended chart mark identifier. Unknown marks decode successfully and
/// are reported as typed unsupported features by the native renderer.
public struct ArtifactChartMark: RawRepresentable, Codable, Sendable, Equatable, Hashable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let area: ArtifactChartMark = "area"
    public static let bar: ArtifactChartMark = "bar"
    public static let line: ArtifactChartMark = "line"
    public static let point: ArtifactChartMark = "point"
    public static let rectangle: ArtifactChartMark = "rectangle"
    public static let rule: ArtifactChartMark = "rule"
    public static let sector: ArtifactChartMark = "sector"
}

/// A mark and its renderer-neutral options.
public struct ArtifactChartMarkConfiguration: Codable, Sendable, Equatable, Hashable {
    public let type: ArtifactChartMark
    public let options: [String: ArtifactChartValue]

    public init(
        type: ArtifactChartMark,
        options: [String: ArtifactChartValue] = [:]
    ) {
        self.type = type
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(ArtifactChartMark.self, forKey: .type)
        options =
            try container.decodeIfPresent(
                [String: ArtifactChartValue].self,
                forKey: .options
            ) ?? [:]
    }
}

/// A field encoding for one chart channel.
public struct ArtifactChartField: Codable, Sendable, Equatable, Hashable {
    public let field: String
    public let type: ArtifactChartValueType
    public let label: String?

    public init(
        field: String,
        type: ArtifactChartValueType,
        label: String? = nil
    ) {
        self.field = field
        self.type = type
        self.label = label
    }
}

/// Dynamic channel map. Keeping channels open lets the schema add channels
/// without changing the ArtifactCore model for every new Swift Charts feature.
public struct ArtifactChartEncoding: Codable, Sendable, Equatable, Hashable {
    public let channels: [String: ArtifactChartField]

    public init(channels: [String: ArtifactChartField] = [:]) {
        self.channels = channels
    }

    public subscript(channel: String) -> ArtifactChartField? {
        channels[channel]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in channels {
            guard let codingKey = DynamicCodingKey(stringValue: key) else {
                throw ArtifactChartSpecError.invalidChannelName(key)
            }
            try container.encode(value, forKey: codingKey)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var decoded: [String: ArtifactChartField] = [:]
        for key in container.allKeys {
            decoded[key.stringValue] = try container.decode(ArtifactChartField.self, forKey: key)
        }
        channels = decoded
    }
}

/// One row of chart data. Rows are encoded as plain JSON objects.
public struct ArtifactChartDataRow: Codable, Sendable, Equatable, Hashable {
    public let values: [String: ArtifactChartValue]

    public init(values: [String: ArtifactChartValue]) {
        self.values = values
    }

    public subscript(field: String) -> ArtifactChartValue? {
        values[field]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = try container.decode([String: ArtifactChartValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// Typed failures for chart payload validation.
public enum ArtifactChartSpecError: Error, LocalizedError, Sendable, Equatable {
    case invalidJSON(String)
    case nonFiniteNumber
    case unsupportedVersion(Int)
    case unsupportedDimension(String)
    case unsupportedMark(String)
    case unsupportedOption(String)
    case emptyData
    case invalidChannelName(String)
    case missingChannel(String)
    case invalidFieldName(String)
    case missingValue(row: Int, field: String)
    case incompatibleValue(row: Int, field: String, expected: ArtifactChartValueType)
    case invalidDate(row: Int, field: String)
    case invalidSectorValue(row: Int, field: String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let reason):
            return "Invalid chart JSON: \(reason)"
        case .nonFiniteNumber:
            return "Chart values must be finite numbers."
        case .unsupportedVersion(let version):
            return "Unsupported chart schema version: \(version)."
        case .unsupportedDimension(let dimension):
            return "Unsupported chart dimension: \(dimension)."
        case .unsupportedMark(let mark):
            return "Unsupported chart mark: \(mark)."
        case .unsupportedOption(let option):
            return "Unsupported chart option: \(option)."
        case .emptyData:
            return "Chart data must contain at least one row."
        case .invalidChannelName(let channel):
            return "Invalid chart channel name: \(channel)."
        case .missingChannel(let channel):
            return "Required chart channel is missing: \(channel)."
        case .invalidFieldName(let field):
            return "Invalid chart field name: \(field)."
        case .missingValue(let row, let field):
            return "Chart row \(row) is missing field \(field)."
        case .incompatibleValue(let row, let field, let expected):
            return "Chart row \(row) field \(field) is not \(expected.rawValue)."
        case .invalidDate(let row, let field):
            return "Chart row \(row) field \(field) is not a valid ISO-8601 date."
        case .invalidSectorValue(let row, let field):
            return "Chart row \(row) field \(field) must be a positive number."
        }
    }
}

/// Versioned, renderer-neutral chart document.
public struct ArtifactChartSpec: Codable, Sendable, Equatable, Hashable {
    public static let currentVersion = 1

    public let version: Int
    public let dimension: ArtifactChartDimension
    public let mark: ArtifactChartMarkConfiguration
    public let data: [ArtifactChartDataRow]
    public let encoding: ArtifactChartEncoding
    public let options: [String: ArtifactChartValue]
    public let extensions: [String: ArtifactChartValue]

    public init(
        version: Int = ArtifactChartSpec.currentVersion,
        dimension: ArtifactChartDimension = .twoD,
        mark: ArtifactChartMarkConfiguration,
        data: [ArtifactChartDataRow],
        encoding: ArtifactChartEncoding,
        options: [String: ArtifactChartValue] = [:],
        extensions: [String: ArtifactChartValue] = [:]
    ) throws {
        self.version = version
        self.dimension = dimension
        self.mark = mark
        self.data = data
        self.encoding = encoding
        self.options = options
        self.extensions = extensions
        try validate()
    }

    public init(json: String) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        } catch let error as ArtifactChartSpecError {
            throw error
        } catch {
            throw ArtifactChartSpecError.invalidJSON(error.localizedDescription)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case dimension
        case mark
        case data
        case encoding
        case options
        case extensions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        dimension = try container.decode(ArtifactChartDimension.self, forKey: .dimension)
        mark = try container.decode(ArtifactChartMarkConfiguration.self, forKey: .mark)
        data = try container.decode([ArtifactChartDataRow].self, forKey: .data)
        encoding = try container.decode(ArtifactChartEncoding.self, forKey: .encoding)
        options =
            try container.decodeIfPresent(
                [String: ArtifactChartValue].self,
                forKey: .options
            ) ?? [:]
        extensions =
            try container.decodeIfPresent(
                [String: ArtifactChartValue].self,
                forKey: .extensions
            ) ?? [:]
        try validate()
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw ArtifactChartSpecError.unsupportedVersion(version)
        }
        guard dimension == .twoD else {
            throw ArtifactChartSpecError.unsupportedDimension(dimension.rawValue)
        }
        guard !data.isEmpty else {
            throw ArtifactChartSpecError.emptyData
        }

        for (channel, field) in encoding.channels {
            guard !channel.isEmpty else {
                throw ArtifactChartSpecError.invalidChannelName(channel)
            }
            guard !field.field.isEmpty else {
                throw ArtifactChartSpecError.invalidFieldName(field.field)
            }
            for (rowIndex, row) in data.enumerated() {
                guard let value = row[field.field] else {
                    throw ArtifactChartSpecError.missingValue(row: rowIndex, field: field.field)
                }
                try validate(value: value, field: field, row: rowIndex)
            }
        }

        switch mark.type {
        case .line, .bar, .area, .point, .rectangle:
            try requireChannel("x")
            try requireChannel("y")
            guard encoding["y"]?.type == .quantitative else {
                throw ArtifactChartSpecError.incompatibleValue(
                    row: 0,
                    field: encoding["y"]?.field ?? "y",
                    expected: .quantitative
                )
            }
        case .rule:
            guard encoding["x"] != nil || encoding["y"] != nil else {
                throw ArtifactChartSpecError.missingChannel("x or y")
            }
        case .sector:
            try requireChannel("angle")
            guard encoding["angle"]?.type == .quantitative else {
                throw ArtifactChartSpecError.incompatibleValue(
                    row: 0,
                    field: encoding["angle"]?.field ?? "angle",
                    expected: .quantitative
                )
            }
            let angleField = encoding["angle"]!.field
            for (rowIndex, row) in data.enumerated() {
                guard case .number(let value) = row[angleField], value > 0 else {
                    throw ArtifactChartSpecError.invalidSectorValue(
                        row: rowIndex, field: angleField)
                }
            }
        default:
            throw ArtifactChartSpecError.unsupportedMark(mark.type.rawValue)
        }
    }

    private func requireChannel(_ name: String) throws {
        guard encoding[name] != nil else {
            throw ArtifactChartSpecError.missingChannel(name)
        }
    }

    private func validate(
        value: ArtifactChartValue,
        field: ArtifactChartField,
        row: Int
    ) throws {
        switch field.type {
        case .quantitative:
            guard case .number(let number) = value else {
                throw ArtifactChartSpecError.incompatibleValue(
                    row: row,
                    field: field.field,
                    expected: field.type
                )
            }
            guard number.isFinite else {
                throw ArtifactChartSpecError.nonFiniteNumber
            }
        case .temporal:
            guard case .string(let string) = value else {
                throw ArtifactChartSpecError.incompatibleValue(
                    row: row,
                    field: field.field,
                    expected: field.type
                )
            }
            let formatter = ISO8601DateFormatter()
            guard formatter.date(from: string) != nil else {
                throw ArtifactChartSpecError.invalidDate(row: row, field: field.field)
            }
        case .nominal, .ordinal:
            guard case .string = value else {
                throw ArtifactChartSpecError.incompatibleValue(
                    row: row,
                    field: field.field,
                    expected: field.type
                )
            }
        }
    }
}

private struct DynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}
