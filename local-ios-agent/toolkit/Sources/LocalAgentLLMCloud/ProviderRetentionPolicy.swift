import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

public enum ProviderRetentionWindowClass: String, Equatable, Sendable {
    case oneDay = "one_day"
    case sevenToThirtyDays = "seven_to_thirty_days"
    case thirtyOneToSixtyDays = "thirty_one_to_sixty_days"
    case providerConfigured = "provider_configured"
    case unknown
}

extension ProviderRetentionWindowClass: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown provider retention window class"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ProviderRetentionBehavior: String, Equatable, Sendable {
    case serverSideConversationState = "server_side_conversation_state"
}

extension ProviderRetentionBehavior: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown provider retention behavior"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ProviderRetentionDisclosure: Codable, Equatable, Sendable {
    public let behavior: ProviderRetentionBehavior
    public let windowClass: ProviderRetentionWindowClass

    public init(
        behavior: ProviderRetentionBehavior,
        windowClass: ProviderRetentionWindowClass
    ) {
        self.behavior = behavior
        self.windowClass = windowClass
    }
}

public struct ProviderRetentionApproval: Codable, Equatable, Sendable {
    public let providerProfileID: String
    public let providerProfileRevision: UInt64
    public let origin: EgressOrigin
    public let retentionMode: ProviderRetentionMode
    public let behavior: ProviderRetentionBehavior
    public let disclosedWindowClass: ProviderRetentionWindowClass
    public let decisionRevision: UInt64
    public let issuedAt: Date
    public let approvalDigest: String

    public init(
        providerProfileID: String,
        providerProfileRevision: UInt64,
        origin: EgressOrigin,
        retentionMode: ProviderRetentionMode,
        behavior: ProviderRetentionBehavior,
        disclosedWindowClass: ProviderRetentionWindowClass,
        decisionRevision: UInt64,
        issuedAt: Date,
        approvalDigest: String
    ) {
        self.providerProfileID = providerProfileID
        self.providerProfileRevision = providerProfileRevision
        self.origin = origin
        self.retentionMode = retentionMode
        self.behavior = behavior
        self.disclosedWindowClass = disclosedWindowClass
        self.decisionRevision = decisionRevision
        self.issuedAt = issuedAt
        self.approvalDigest = approvalDigest
    }
}

public protocol ProviderRetentionApprovalPrompting: Sendable {
    func requestProviderStateApproval(
        profileName: String,
        origin: EgressOrigin,
        disclosure: ProviderRetentionDisclosure
    ) async -> EgressDecision
}

public actor ProviderRetentionPolicy {
    private let database: SQLiteConnection
    private let prompt: any ProviderRetentionApprovalPrompting
    private let clock: @Sendable () -> Date

    package init(
        fileURL: URL,
        prompt: any ProviderRetentionApprovalPrompting,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let database = try SQLiteConnection(path: fileURL.path)
        guard try LLMStoreSchema.userVersion(database) == LLMStoreSchema.currentVersion else {
            throw retentionFailure("retention.schema_not_ready", "retention policy requires the current schema")
        }
        self.database = database
        self.prompt = prompt
        self.clock = clock
        try validatePersistedRetentionApprovals()
    }

    public func approveProviderState(
        profileID: String,
        profileRevision: UInt64,
        disclosure: ProviderRetentionDisclosure
    ) async throws -> ProviderRetentionApproval {
        let profile = try readActiveProfile(profileID: profileID, revision: profileRevision)
        guard profile.revision.retentionMode == .providerStateApproved else {
            throw retentionFailure(
                "retention.mode_not_stateful",
                "provider profile does not enable provider-side state"
            )
        }
        if let current = try currentApproval(
            profileID: profileID,
            profileRevision: profileRevision,
            expectedOrigin: profile.origin
        ) {
            guard current.behavior == disclosure.behavior,
                  current.disclosedWindowClass == disclosure.windowClass
            else {
                throw retentionFailure(
                    "retention.disclosure_conflict",
                    "provider retention disclosure changed within an immutable profile revision"
                )
            }
            return current
        }
        guard await prompt.requestProviderStateApproval(
            profileName: profile.revision.displayName,
            origin: profile.origin,
            disclosure: disclosure
        ) == .allow else {
            throw retentionFailure("egress.denied", "provider retention approval was denied")
        }

        return try database.transaction {
            let live = try readActiveProfile(profileID: profileID, revision: profileRevision)
            guard live == profile else {
                throw retentionFailure("retention.profile_changed", "provider profile changed during approval")
            }
            if let current = try currentApproval(
                profileID: profileID,
                profileRevision: profileRevision,
                expectedOrigin: profile.origin
            ) {
                guard current.behavior == disclosure.behavior,
                      current.disclosedWindowClass == disclosure.windowClass
                else { throw retentionFailure("retention.disclosure_conflict", "retention approval changed") }
                return current
            }
            let revision = try nextApprovalRevision(
                table: "provider_retention_approvals",
                profileID: profileID,
                profileRevision: profileRevision,
                database: database
            )
            let issuedAt = millisecondDate(clock())
            let unsigned = ProviderRetentionApproval(
                providerProfileID: profileID,
                providerProfileRevision: profileRevision,
                origin: profile.origin,
                retentionMode: .providerStateApproved,
                behavior: disclosure.behavior,
                disclosedWindowClass: disclosure.windowClass,
                decisionRevision: revision,
                issuedAt: issuedAt,
                approvalDigest: ""
            )
            let approval = ProviderRetentionApproval(
                providerProfileID: unsigned.providerProfileID,
                providerProfileRevision: unsigned.providerProfileRevision,
                origin: unsigned.origin,
                retentionMode: unsigned.retentionMode,
                behavior: unsigned.behavior,
                disclosedWindowClass: unsigned.disclosedWindowClass,
                decisionRevision: unsigned.decisionRevision,
                issuedAt: unsigned.issuedAt,
                approvalDigest: try providerRetentionApprovalDigest(unsigned).hex
            )
            try database.execute(
                """
                INSERT INTO provider_retention_approvals(
                  profile_id, profile_revision, approval_revision, retention_mode,
                  behavior, window_class, decision, approval_digest,
                  record_schema_version, record_json
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'allow', ?7, 2, ?8)
                """,
                bindings: [
                    .text(profileID), .text(String(profileRevision)),
                    .text(String(revision)), .text(approval.retentionMode.rawValue),
                    .text(approval.behavior.rawValue),
                    .text(approval.disclosedWindowClass.rawValue),
                    .text(approval.approvalDigest),
                    .text(try encodeEgressRecord(VersionedEgressRecord(approval))),
                ]
            )
            try bindApprovalToProfileState(approval)
            return approval
        }
    }

    package func requireApproval(
        profileID: String,
        profileRevision: UInt64,
        origin: EgressOrigin,
        retentionMode: ProviderRetentionMode
    ) throws -> ProviderRetentionApproval? {
        switch retentionMode {
        case .statelessRequired:
            let state = try readProfileState(profileID: profileID, revision: profileRevision)
            guard state.retentionApprovalRevision == nil,
                  state.retentionApprovalDigest == nil
            else {
                throw retentionFailure(
                    "retention.approval_invalid",
                    "stateless profile carries provider-state approval"
                )
            }
            return nil
        case .providerStateApproved:
            guard let approval = try currentApproval(
                profileID: profileID,
                profileRevision: profileRevision,
                expectedOrigin: origin
            ) else {
                throw retentionFailure(
                    "retention.approval_required",
                    "provider-side state requires explicit approval"
                )
            }
            return approval
        }
    }

    nonisolated private func currentApproval(
        profileID: String,
        profileRevision: UInt64,
        expectedOrigin: EgressOrigin
    ) throws -> ProviderRetentionApproval? {
        let state = try readProfileState(profileID: profileID, revision: profileRevision)
        guard let revision = state.retentionApprovalRevision,
              let digest = state.retentionApprovalDigest
        else {
            guard state.retentionApprovalRevision == nil,
                  state.retentionApprovalDigest == nil
            else { throw retentionFailure("retention.approval_invalid", "retention approval state is incomplete") }
            return nil
        }
        let rows = try database.queryRows(
            """
            SELECT approval_revision, retention_mode, behavior, window_class,
              decision, approval_digest, record_schema_version, record_json
            FROM provider_retention_approvals
            WHERE profile_id = ?1 AND profile_revision = ?2 AND approval_revision = ?3
            """,
            bindings: [
                .text(profileID), .text(String(profileRevision)), .text(String(revision)),
            ]
        )
        guard let row = rows.first, rows.count == 1,
              row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw retentionFailure("retention.approval_invalid", "retention approval record is missing") }
        let approval = try decodeEgressRecord(
            VersionedEgressRecord<ProviderRetentionApproval>.self,
            json: json
        ).value
        guard approval.providerProfileID == profileID,
              approval.providerProfileRevision == profileRevision,
              approval.origin == expectedOrigin,
              approval.retentionMode == .providerStateApproved,
              approval.decisionRevision == revision,
              approval.approvalDigest == digest,
              row.text("approval_revision") == String(revision),
              row.text("retention_mode") == approval.retentionMode.rawValue,
              row.text("behavior") == approval.behavior.rawValue,
              row.text("window_class") == approval.disclosedWindowClass.rawValue,
              row.text("decision") == EgressDecision.allow.rawValue,
              row.text("approval_digest") == approval.approvalDigest,
              try providerRetentionApprovalDigest(approval).hex == approval.approvalDigest
        else { throw retentionFailure("retention.approval_invalid", "retention approval record is inconsistent") }
        return approval
    }

    private func bindApprovalToProfileState(_ approval: ProviderRetentionApproval) throws {
        var persisted = try readPersistedProfileState(
            profileID: approval.providerProfileID,
            revision: approval.providerProfileRevision
        )
        guard persisted.state.stateRevision < UInt64.max else {
            throw retentionFailure("retention.state_overflow", "provider profile state revision overflow")
        }
        let expectedRevision = persisted.state.stateRevision
        persisted.state.retentionApprovalRevision = approval.decisionRevision
        persisted.state.retentionApprovalDigest = approval.approvalDigest
        persisted.state.stateRevision += 1
        let changed = try database.executeChanges(
            """
            UPDATE provider_profile_state SET retention_approval_revision = ?1,
              retention_approval_digest = ?2, state_revision = ?3, record_json = ?4
            WHERE profile_id = ?5 AND profile_revision = ?6 AND state_revision = ?7
            """,
            bindings: [
                .text(String(approval.decisionRevision)), .text(approval.approvalDigest),
                .text(String(persisted.state.stateRevision)),
                .text(try encodeEgressRecord(persisted)),
                .text(approval.providerProfileID),
                .text(String(approval.providerProfileRevision)),
                .text(String(expectedRevision)),
            ]
        )
        guard changed == 1 else {
            throw retentionFailure("retention.state_conflict", "provider profile state changed")
        }
    }

    nonisolated private func readActiveProfile(
        profileID: String,
        revision: UInt64
    ) throws -> PublishedProviderProfileRevision {
        let profile = try readProfile(profileID: profileID, revision: revision)
        guard profile.lifecycle == .active else {
            throw retentionFailure("retention.profile_not_active", "provider profile is not active")
        }
        return profile
    }

    nonisolated private func readProfile(
        profileID: String,
        revision: UInt64
    ) throws -> PublishedProviderProfileRevision {
        let rows = try database.queryRows(
            """
            SELECT lifecycle, record_schema_version, record_json
            FROM provider_profile_revisions WHERE profile_id = ?1 AND revision = ?2
            """,
            bindings: [.text(profileID), .text(String(revision))]
        )
        guard let row = rows.first, rows.count == 1,
              row.integer("record_schema_version") == 3,
              let json = row.text("record_json")
        else { throw retentionFailure("retention.profile_invalid", "provider profile is missing") }
        guard let profile = try decodeEgressRecord(
            PersistedProfileRevision.self,
            json: json
        ).published,
              profile.revision.profileID == profileID,
              profile.revision.revision == revision,
              row.text("lifecycle") == profile.lifecycle.rawValue
        else { throw retentionFailure("retention.profile_invalid", "provider profile record is invalid") }
        return profile
    }

    nonisolated private func readProfileState(
        profileID: String,
        revision: UInt64
    ) throws -> ProviderProfileState {
        try readPersistedProfileState(profileID: profileID, revision: revision).state
    }

    nonisolated private func readPersistedProfileState(
        profileID: String,
        revision: UInt64
    ) throws -> PersistedProfileState {
        let rows = try database.queryRows(
            """
            SELECT state_revision, record_schema_version, record_json
            FROM provider_profile_state WHERE profile_id = ?1 AND profile_revision = ?2
            """,
            bindings: [.text(profileID), .text(String(revision))]
        )
        guard let row = rows.first, rows.count == 1,
              row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw retentionFailure("retention.profile_state_invalid", "provider profile state is missing") }
        let persisted = try decodeEgressRecord(PersistedProfileState.self, json: json)
        guard persisted.state.profileID == profileID,
              persisted.state.profileRevision == revision,
              row.text("state_revision") == String(persisted.state.stateRevision)
        else { throw retentionFailure("retention.profile_state_invalid", "provider profile state is inconsistent") }
        return persisted
    }

    nonisolated private func validatePersistedRetentionApprovals() throws {
        for row in try database.queryRows(
            "SELECT profile_id, profile_revision FROM provider_profile_state WHERE retention_approval_revision IS NOT NULL OR retention_approval_digest IS NOT NULL"
        ) {
            guard let profileID = row.text("profile_id"),
                  let revisionText = row.text("profile_revision"),
                  let revision = UInt64(revisionText)
            else { throw retentionFailure("retention.corrupt_record", "retention state identity is invalid") }
            let profile = try readProfile(profileID: profileID, revision: revision)
            _ = try currentApproval(
                profileID: profileID,
                profileRevision: revision,
                expectedOrigin: profile.origin
            )
        }
    }
}

struct VersionedEgressRecord<Value: Codable & Sendable>: Codable, Sendable {
    let recordSchemaVersion: Int
    let value: Value

    enum CodingKeys: String, CodingKey {
        case recordSchemaVersion = "record_schema_version"
        case value
    }

    init(_ value: Value) {
        recordSchemaVersion = 2
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordSchemaVersion = try container.decode(Int.self, forKey: .recordSchemaVersion)
        guard recordSchemaVersion == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordSchemaVersion,
                in: container,
                debugDescription: "unsupported egress record schema"
            )
        }
        value = try container.decode(Value.self, forKey: .value)
    }
}

func encodeEgressRecord<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func decodeEgressRecord<T: Decodable>(_ type: T.Type, json: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    } catch {
        throw retentionFailure("retention.corrupt_record", "persisted egress record is invalid")
    }
}

func nextApprovalRevision(
    table: String,
    profileID: String,
    profileRevision: UInt64,
    database: SQLiteConnection
) throws -> UInt64 {
    let rows = try database.queryRows(
        "SELECT approval_revision FROM \(table) WHERE profile_id = ?1 AND profile_revision = ?2",
        bindings: [.text(profileID), .text(String(profileRevision))]
    )
    let maximum = try rows.reduce(UInt64(0)) { current, row in
        guard let text = row.text("approval_revision"), let revision = UInt64(text) else {
            throw retentionFailure("retention.corrupt_record", "approval revision is invalid")
        }
        return max(current, revision)
    }
    guard maximum < UInt64.max else {
        throw retentionFailure("retention.revision_overflow", "approval revision overflow")
    }
    return maximum + 1
}

private func retentionFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
