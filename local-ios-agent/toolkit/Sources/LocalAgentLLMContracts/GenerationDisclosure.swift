public enum EgressDataClass: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case memory
    case contacts
    case files
    case calendar
    case photos
    case location
    case attachment
    case toolResult = "tool_result"
    case unknownData = "unknown_data"
}

public enum DataSensitivity: String, Codable, CaseIterable, Sendable, Comparable {
    case routine
    case `private`
    case sensitive
    case highlySensitive = "highly_sensitive"
    case unknown

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .routine: 0
        case .private: 1
        case .sensitive: 2
        case .highlySensitive: 3
        case .unknown: 4
        }
    }
}

public enum EgressSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case conversation
    case agentConfiguration = "agent_configuration"
    case memory
    case contacts
    case files
    case calendar
    case photos
    case location
    case attachment
    case toolResult = "tool_result"
    case other
}

public enum EgressSizeBucket: String, Codable, CaseIterable, Sendable {
    case none
    case lessThanOneKiB = "less_than_1_kib"
    case oneToOneHundredKiB = "1_to_100_kib"
    case oneHundredKiBToOneMiB = "100_kib_to_1_mib"
    case greaterThanOneMiB = "greater_than_1_mib"
}

public struct EgressDataClassCount: Codable, Equatable, Sendable {
    public let dataClass: EgressDataClass
    public let count: UInt64

    public init(dataClass: EgressDataClass, count: UInt64) {
        self.dataClass = dataClass
        self.count = count
    }

    private enum CodingKeys: String, CodingKey { case dataClass = "data_class", count }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataClass = try container.decode(EgressDataClass.self, forKey: .dataClass)
        if let canonical = try? container.decode(String.self, forKey: .count),
           let value = UInt64(canonical), String(value) == canonical {
            count = value
        } else {
            count = try container.decode(UInt64.self, forKey: .count)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dataClass, forKey: .dataClass)
        try container.encode(String(count), forKey: .count)
    }
}

public struct SafeDisplaySummary: Codable, Equatable, Sendable {
    public let sourceKinds: Set<EgressSourceKind>
    public let addedItemCounts: [EgressDataClassCount]
    public let approximateAddedSize: EgressSizeBucket
    public let triggeringToolDisplayKeys: Set<String>

    public init(
        sourceKinds: Set<EgressSourceKind>,
        addedItemCounts: [EgressDataClassCount],
        approximateAddedSize: EgressSizeBucket,
        triggeringToolDisplayKeys: Set<String>
    ) {
        self.sourceKinds = sourceKinds
        self.addedItemCounts = addedItemCounts
        self.approximateAddedSize = approximateAddedSize
        self.triggeringToolDisplayKeys = triggeringToolDisplayKeys
    }

    private enum CodingKeys: String, CodingKey {
        case sourceKinds = "source_kinds", addedItemCounts = "added_item_counts"
        case approximateAddedSize = "approximate_added_size"
        case triggeringToolDisplayKeys = "triggering_tool_display_keys"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceKinds = Set(try container.decode([EgressSourceKind].self, forKey: .sourceKinds))
        addedItemCounts = try container.decode([EgressDataClassCount].self, forKey: .addedItemCounts)
        approximateAddedSize = try container.decode(EgressSizeBucket.self, forKey: .approximateAddedSize)
        triggeringToolDisplayKeys = Set(try container.decode([String].self, forKey: .triggeringToolDisplayKeys))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceKinds.sorted { $0.rawValue < $1.rawValue }, forKey: .sourceKinds)
        try container.encode(addedItemCounts.sorted { $0.dataClass.rawValue < $1.dataClass.rawValue }, forKey: .addedItemCounts)
        try container.encode(approximateAddedSize, forKey: .approximateAddedSize)
        try container.encode(triggeringToolDisplayKeys.sorted(), forKey: .triggeringToolDisplayKeys)
    }
}

public struct GenerationDisclosureError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct GenerationDisclosure: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let generationTurnID: String
    public let contentDigest: String
    public let sourceRevisionDigest: String
    public let dataClasses: Set<EgressDataClass>
    public let highestSensitivity: DataSensitivity
    public let safeDisplaySummary: SafeDisplaySummary

    public init(
        schemaVersion: String,
        generationTurnID: String,
        contentDigest: String,
        sourceRevisionDigest: String,
        dataClasses: Set<EgressDataClass>,
        highestSensitivity: DataSensitivity,
        safeDisplaySummary: SafeDisplaySummary
    ) {
        self.schemaVersion = schemaVersion
        self.generationTurnID = generationTurnID
        self.contentDigest = contentDigest
        self.sourceRevisionDigest = sourceRevisionDigest
        self.dataClasses = dataClasses
        self.highestSensitivity = highestSensitivity
        self.safeDisplaySummary = safeDisplaySummary
    }

    public func computedDigest() throws -> CanonicalDigest {
        guard schemaVersion == "1", !generationTurnID.isEmpty else {
            throw invalid("schema version and generation turn ID must be canonical")
        }
        guard Self.isLowercaseSHA256(contentDigest),
              Self.isLowercaseSHA256(sourceRevisionDigest)
        else {
            throw invalid("content and source revision digests must be lowercase SHA-256")
        }
        guard !dataClasses.isEmpty,
              !dataClasses.contains(.unknownData) || highestSensitivity == .unknown
        else {
            throw invalid("data classes must be present and unknown data must remain unknown")
        }
        let countClasses = safeDisplaySummary.addedItemCounts.map(\.dataClass)
        guard Set(countClasses).count == countClasses.count else {
            throw invalid("safe display summary contains duplicate data-class counts")
        }
        guard safeDisplaySummary.triggeringToolDisplayKeys.allSatisfy({ !$0.isEmpty }) else {
            throw invalid("tool display keys must not be empty")
        }

        let counts = try safeDisplaySummary.addedItemCounts
            .sorted { $0.dataClass.rawValue < $1.dataClass.rawValue }
            .map { count in
                try CanonicalJSONValue.object(entries: [
                    .init(name: "count", value: .string(String(count.count))),
                    .init(name: "data_class", value: .string(count.dataClass.rawValue)),
                ])
            }
        let summary = try CanonicalJSONValue.object(entries: [
            .init(
                name: "added_item_counts",
                value: .array(counts)
            ),
            .init(
                name: "approximate_added_size",
                value: .string(safeDisplaySummary.approximateAddedSize.rawValue)
            ),
            .init(
                name: "source_kinds",
                value: .array(safeDisplaySummary.sourceKinds
                    .map(\.rawValue)
                    .sorted()
                    .map(CanonicalJSONValue.string))
            ),
            .init(
                name: "triggering_tool_display_keys",
                value: .array(safeDisplaySummary.triggeringToolDisplayKeys
                    .sorted()
                    .map(CanonicalJSONValue.string))
            ),
        ])
        let document = try CanonicalJSONValue.object(entries: [
            .init(name: "content_digest", value: .string(contentDigest)),
            .init(
                name: "data_classes",
                value: .array(dataClasses.map(\.rawValue).sorted().map(CanonicalJSONValue.string))
            ),
            .init(name: "generation_turn_id", value: .string(generationTurnID)),
            .init(name: "highest_sensitivity", value: .string(highestSensitivity.rawValue)),
            .init(name: "safe_display_summary", value: summary),
            .init(name: "schema_version", value: .string(schemaVersion)),
            .init(name: "source_revision_digest", value: .string(sourceRevisionDigest)),
        ])
        return try CanonicalDigestV1.digest(
            domain: "generation-disclosure:v1",
            document: document
        )
    }

    private func invalid(_ message: String) -> GenerationDisclosureError {
        GenerationDisclosureError(
            code: "generation_disclosure.invalid",
            message: message
        )
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", generationTurnID = "generation_turn_id"
        case contentDigest = "content_digest", sourceRevisionDigest = "source_revision_digest"
        case dataClasses = "data_classes", highestSensitivity = "highest_sensitivity"
        case safeDisplaySummary = "safe_display_summary"
    }


    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        generationTurnID = try container.decode(String.self, forKey: .generationTurnID)
        contentDigest = try container.decode(String.self, forKey: .contentDigest)
        sourceRevisionDigest = try container.decode(String.self, forKey: .sourceRevisionDigest)
        dataClasses = Set(try container.decode([EgressDataClass].self, forKey: .dataClasses))
        highestSensitivity = try container.decode(DataSensitivity.self, forKey: .highestSensitivity)
        safeDisplaySummary = try container.decode(SafeDisplaySummary.self, forKey: .safeDisplaySummary)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generationTurnID, forKey: .generationTurnID)
        try container.encode(contentDigest, forKey: .contentDigest)
        try container.encode(sourceRevisionDigest, forKey: .sourceRevisionDigest)
        try container.encode(dataClasses.sorted { $0.rawValue < $1.rawValue }, forKey: .dataClasses)
        try container.encode(highestSensitivity, forKey: .highestSensitivity)
        try container.encode(safeDisplaySummary, forKey: .safeDisplaySummary)
    }
}
