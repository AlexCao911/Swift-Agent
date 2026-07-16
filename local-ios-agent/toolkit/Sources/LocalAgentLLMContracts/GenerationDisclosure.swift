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
}
