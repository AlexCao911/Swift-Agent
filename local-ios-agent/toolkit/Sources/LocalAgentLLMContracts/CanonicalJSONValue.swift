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

public indirect enum CanonicalJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case string(String)
    case number(Double)
    case array([CanonicalJSONValue])
    case object(CanonicalJSONObject)

    public static func object(entries: [CanonicalJSONObjectEntry]) throws -> Self {
        .object(try CanonicalJSONObject(entries: entries))
    }
}
