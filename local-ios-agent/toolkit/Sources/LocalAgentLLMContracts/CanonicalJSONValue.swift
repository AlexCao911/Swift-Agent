import Foundation

public struct CanonicalJSONObjectEntry: Equatable, Sendable {
    public let name: String
    public let value: CanonicalJSONValue

    public init(name: String, value: CanonicalJSONValue) {
        self.name = name
        self.value = value
    }
}

public struct CanonicalJSONObject: Equatable, Sendable {
    let entries: [CanonicalJSONObjectEntry]

    public init(entries: [CanonicalJSONObjectEntry]) throws {
        var names = Set<String>()
        for entry in entries {
            guard names.insert(entry.name).inserted else {
                throw CanonicalDigestError(
                    code: "canonical_digest.object_duplicate_name",
                    message: "canonical JSON object contains a duplicate name: \(entry.name)"
                )
            }
        }
        self.entries = entries
    }
}

public indirect enum CanonicalJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case string(String)
    case number(Double)
    case array([CanonicalJSONValue])
    case object(CanonicalJSONObject)

    public static func object(entries: [CanonicalJSONObjectEntry]) throws -> Self {
        .object(try CanonicalJSONObject(entries: entries))
    }

    public var objectKeys: Set<String>? {
        guard case let .object(object) = self else { return nil }
        return Set(object.entries.map(\.name))
    }

    public func objectValue(forKey key: String) -> CanonicalJSONValue? {
        guard case let .object(object) = self else { return nil }
        return object.entries.first { $0.name == key }?.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let values = try? container.decode([CanonicalJSONValue].self) {
            self = .array(values)
        } else {
            let values = try container.decode([String: CanonicalJSONValue].self)
            self = try .object(entries: values.map {
                CanonicalJSONObjectEntry(name: $0.key, value: $0.value)
            })
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values)
        case let .object(object):
            try container.encode(Dictionary(
                uniqueKeysWithValues: object.entries.map { ($0.name, $0.value) }
            ))
        }
    }
}
