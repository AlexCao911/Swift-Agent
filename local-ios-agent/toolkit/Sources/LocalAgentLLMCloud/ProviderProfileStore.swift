import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

private struct ProfileKey: Hashable, Sendable {
    let id: String
    let revision: UInt64
}

enum PersistedProviderProfileLifecycle: Codable, Equatable, Sendable {
    case creating(operationID: String)
    case active
    case archived

    private enum CodingKeys: String, CodingKey {
        case tag
        case operationID = "operation_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .tag) {
        case "creating":
            let operationID = try container.decode(String.self, forKey: .operationID)
            guard !operationID.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .operationID,
                    in: container,
                    debugDescription: "provider creation operation ID is empty"
                )
            }
            self = .creating(operationID: operationID)
        case "active":
            self = .active
        case "archived":
            self = .archived
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "unknown provider profile lifecycle"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .creating(operationID):
            try container.encode("creating", forKey: .tag)
            try container.encode(operationID, forKey: .operationID)
        case .active:
            try container.encode("active", forKey: .tag)
        case .archived:
            try container.encode("archived", forKey: .tag)
        }
    }
}

struct PersistedProfileRevision: Codable, Sendable {
    let recordSchemaVersion: Int
    let revision: ProviderProfileRevision
    let origin: EgressOrigin
    let lifecycle: PersistedProviderProfileLifecycle

    enum CodingKeys: String, CodingKey {
        case recordSchemaVersion = "record_schema_version"
        case revision
        case origin
        case lifecycle
    }

    init(published: PublishedProviderProfileRevision) {
        recordSchemaVersion = 3
        revision = published.revision
        origin = published.origin
        lifecycle = switch published.lifecycle {
        case .active: .active
        case .archived: .archived
        }
    }

    init(
        revision: ProviderProfileRevision,
        origin: EgressOrigin,
        creationOperationID: String
    ) {
        recordSchemaVersion = 3
        self.revision = revision
        self.origin = origin
        lifecycle = .creating(operationID: creationOperationID)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordSchemaVersion = try container.decode(Int.self, forKey: .recordSchemaVersion)
        guard recordSchemaVersion == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordSchemaVersion,
                in: container,
                debugDescription: "unsupported provider-profile record schema"
            )
        }
        revision = try container.decode(ProviderProfileRevision.self, forKey: .revision)
        origin = try container.decode(EgressOrigin.self, forKey: .origin)
        lifecycle = try container.decode(
            PersistedProviderProfileLifecycle.self,
            forKey: .lifecycle
        )
    }

    var published: PublishedProviderProfileRevision? {
        let publicLifecycle: ProviderRevisionLifecycle
        switch lifecycle {
        case .creating:
            return nil
        case .active:
            publicLifecycle = .active
        case .archived:
            publicLifecycle = .archived
        }
        return PublishedProviderProfileRevision(
            revision: revision,
            origin: origin,
            lifecycle: publicLifecycle
        )
    }
}

struct PersistedProfileState: Codable, Sendable {
    let recordSchemaVersion: Int
    var state: ProviderProfileState

    enum CodingKeys: String, CodingKey {
        case recordSchemaVersion = "record_schema_version"
        case state
    }

    init(state: ProviderProfileState) {
        recordSchemaVersion = 2
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordSchemaVersion = try container.decode(Int.self, forKey: .recordSchemaVersion)
        guard recordSchemaVersion == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordSchemaVersion,
                in: container,
                debugDescription: "unsupported provider-state record schema"
            )
        }
        state = try container.decode(ProviderProfileState.self, forKey: .state)
    }
}

public actor ProviderProfileStore {
    private let database: SQLiteConnection
    private let originValidator: any ProviderOriginValidating
    private var profiles: [ProfileKey: PublishedProviderProfileRevision]
    private var creating: [ProfileKey: PersistedProfileRevision]
    private var states: [ProfileKey: ProviderProfileState]

    package static func inMemory(
        originValidator: any ProviderOriginValidating
    ) throws -> ProviderProfileStore {
        try ProviderProfileStore(fileURL: nil, originValidator: originValidator)
    }

    package init(
        fileURL: URL,
        originValidator: any ProviderOriginValidating,
        failMigrationAfterStatement: Int? = nil
    ) throws {
        try self.init(
            fileURL: Optional(fileURL),
            originValidator: originValidator,
            failMigrationAfterStatement: failMigrationAfterStatement
        )
    }

    private init(
        fileURL: URL?,
        originValidator: any ProviderOriginValidating,
        failMigrationAfterStatement: Int? = nil
    ) throws {
        do {
            if let fileURL {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            let database = try SQLiteConnection(path: fileURL?.path ?? ":memory:")
            try LLMStoreSchema.migrateToCurrent(
                database,
                failVersionTwoAfterStatement: failMigrationAfterStatement
            )
            let loaded = try Self.load(database)
            self.database = database
            self.originValidator = originValidator
            profiles = loaded.profiles
            creating = loaded.creating
            states = loaded.states
        } catch let failure as ProviderProfileFailure {
            throw failure
        } catch let failure as LLMStoreSchemaError {
            throw ProviderProfileFailure(code: failure.code, message: failure.message)
        } catch {
            throw ProviderProfileFailure(
                code: "provider_profile.store_open_failed",
                message: "could not open or decode the provider profile store: \(error)"
            )
        }
    }

    public func prepareCreatingRevision(
        _ revision: ProviderProfileRevision,
        proposedOperationID: String
    ) async throws -> String {
        guard !proposedOperationID.isEmpty else {
            throw failure(
                "provider_profile.creation_operation_invalid",
                "profile creation operation ID is empty"
            )
        }
        let origin: EgressOrigin
        do {
            origin = try await originValidator.validate(revision.baseURL)
        } catch let profileFailure as ProviderProfileFailure {
            throw profileFailure
        } catch {
            throw failure("provider_profile.origin_forbidden", "provider origin was rejected")
        }
        let key = ProfileKey(id: revision.profileID, revision: revision.revision)
        if let existing = creating[key] {
            guard existing.revision == revision, existing.origin == origin,
                  case let .creating(operationID) = existing.lifecycle
            else {
                throw failure(
                    "provider_profile.revision_conflict",
                    "profile revision is immutable"
                )
            }
            return operationID
        }
        guard profiles[key] == nil else {
            throw failure(
                "provider_profile.already_published",
                "profile revision is already published"
            )
        }
        try validateNewRevision(revision)
        let persisted = PersistedProfileRevision(
            revision: revision,
            origin: origin,
            creationOperationID: proposedOperationID
        )
        do {
            try database.execute(
                """
                INSERT INTO provider_profile_revisions(
                  profile_id, revision, preset_id, origin, credential_ref, retention_mode,
                  lifecycle, record_schema_version, record_json
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'creating', 3, ?7)
                """,
                bindings: [
                    .text(revision.profileID), .text(String(revision.revision)),
                    .text(revision.presetID.rawValue), .text(origin.serialized),
                    .text(revision.credentialRef), .text(revision.retentionMode.rawValue),
                    .text(try Self.encode(persisted)),
                ]
            )
        } catch {
            throw failure(
                "provider_profile.persistence_failed",
                "could not persist creating profile revision"
            )
        }
        creating[key] = persisted
        return proposedOperationID
    }

    public func activateCreatingRevision(
        profileID: String,
        revision: UInt64,
        operationID: String,
        credentialStore: ProviderCredentialStore
    ) async throws -> PublishedProviderProfileRevision {
        let key = ProfileKey(id: profileID, revision: revision)
        guard let pending = creating[key],
              case let .creating(persistedOperationID) = pending.lifecycle,
              persistedOperationID == operationID
        else {
            if let existing = profiles[key], existing.lifecycle == .active {
                return existing
            }
            throw failure(
                "provider_profile.creation_not_found",
                "creating profile revision does not match the operation"
            )
        }
        guard let slot = try await credentialStore.slot(pending.revision.credentialRef),
              slot.lifecycle == .active
        else {
            throw failure(
                "provider_profile.credential_not_active",
                "profile credential slot is not active"
            )
        }
        let published = PublishedProviderProfileRevision(
            revision: pending.revision,
            origin: pending.origin,
            lifecycle: .active
        )
        let state = ProviderProfileState(
            profileID: profileID,
            profileRevision: revision
        )
        do {
            try database.transaction {
                let changed = try database.executeChanges(
                    """
                    UPDATE provider_profile_revisions
                    SET lifecycle = 'active', record_json = ?1
                    WHERE profile_id = ?2 AND revision = ?3
                      AND lifecycle = 'creating' AND record_json = ?4
                    """,
                    bindings: [
                        .text(try Self.encode(PersistedProfileRevision(published: published))),
                        .text(profileID), .text(String(revision)),
                        .text(try Self.encode(pending)),
                    ]
                )
                guard changed == 1 else {
                    throw failure(
                        "provider_profile.lifecycle_conflict",
                        "creating profile revision changed"
                    )
                }
                try database.execute(
                    """
                    INSERT INTO provider_profile_state(
                      profile_id, profile_revision, retention_approval_revision,
                      retention_approval_digest, catalog_revision, state_revision,
                      record_schema_version, record_json
                    ) VALUES (?1, ?2, NULL, NULL, NULL, ?3, 2, ?4)
                    """,
                    bindings: [
                        .text(profileID), .text(String(revision)),
                        .text(String(state.stateRevision)),
                        .text(try Self.encode(PersistedProfileState(state: state))),
                    ]
                )
            }
        } catch let profileFailure as ProviderProfileFailure {
            throw profileFailure
        } catch {
            throw failure(
                "provider_profile.persistence_failed",
                "could not activate creating profile revision"
            )
        }
        creating.removeValue(forKey: key)
        profiles[key] = published
        states[key] = state
        return published
    }

    public func reconcileCreatingRevisions(
        credentialStore: ProviderCredentialStore
    ) async throws {
        for (key, pending) in creating.sorted(by: {
            ($0.key.id, $0.key.revision) < ($1.key.id, $1.key.revision)
        }) {
            guard case let .creating(operationID) = pending.lifecycle else { continue }
            if try await credentialStore.slot(pending.revision.credentialRef)?.lifecycle == .active {
                _ = try await activateCreatingRevision(
                    profileID: key.id,
                    revision: key.revision,
                    operationID: operationID,
                    credentialStore: credentialStore
                )
            } else {
                try archiveCreatingRevision(key: key, pending: pending)
            }
        }
    }

    package func creatingOperationID(
        profileID: String,
        revision: UInt64
    ) -> String? {
        guard case let .creating(operationID)? = creating[
            ProfileKey(id: profileID, revision: revision)
        ]?.lifecycle else {
            return nil
        }
        return operationID
    }

    public func allProfiles() -> [PublishedProviderProfileRevision] {
        profiles.values.sorted {
            ($0.revision.profileID, $0.revision.revision)
                < ($1.revision.profileID, $1.revision.revision)
        }
    }

    @discardableResult
    public func publish(
        _ revision: ProviderProfileRevision
    ) async throws -> PublishedProviderProfileRevision {
        if let existing = profiles[ProfileKey(id: revision.profileID, revision: revision.revision)] {
            guard existing.revision == revision else {
                throw failure("provider_profile.revision_conflict", "profile revision is immutable")
            }
            return existing
        }
        try validateNewRevision(revision)
        try validateCredentialReference(revision.credentialRef)
        let origin: EgressOrigin
        do {
            origin = try await originValidator.validate(revision.baseURL)
        } catch let profileFailure as ProviderProfileFailure {
            throw profileFailure
        } catch {
            throw failure("provider_profile.origin_forbidden", "provider origin was rejected")
        }

        let key = ProfileKey(id: revision.profileID, revision: revision.revision)
        if let existing = profiles[key] {
            guard existing.revision == revision, existing.origin == origin else {
                throw failure("provider_profile.revision_conflict", "profile revision is immutable")
            }
            return existing
        }
        try validateNewRevision(revision)

        let published = PublishedProviderProfileRevision(
            revision: revision,
            origin: origin,
            lifecycle: .active
        )
        let state = ProviderProfileState(
            profileID: revision.profileID,
            profileRevision: revision.revision
        )
        do {
            try database.transaction {
                try validateCredentialReference(revision.credentialRef)
                try database.execute(
                    """
                    INSERT INTO provider_profile_revisions(
                      profile_id, revision, preset_id, origin, credential_ref, retention_mode,
                      lifecycle, record_schema_version, record_json
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 3, ?8)
                    """,
                    bindings: [
                        .text(revision.profileID), .text(String(revision.revision)),
                        .text(revision.presetID.rawValue), .text(origin.serialized),
                        .text(revision.credentialRef), .text(revision.retentionMode.rawValue),
                        .text(ProviderRevisionLifecycle.active.rawValue),
                        .text(try Self.encode(PersistedProfileRevision(published: published))),
                    ]
                )
                try database.execute(
                    """
                    INSERT INTO provider_profile_state(
                      profile_id, profile_revision, retention_approval_revision,
                      retention_approval_digest, catalog_revision, state_revision,
                      record_schema_version, record_json
                    ) VALUES (?1, ?2, NULL, NULL, NULL, ?3, 2, ?4)
                    """,
                    bindings: [
                        .text(revision.profileID), .text(String(revision.revision)),
                        .text(String(state.stateRevision)),
                        .text(try Self.encode(PersistedProfileState(state: state))),
                    ]
                )
            }
        } catch {
            throw failure("provider_profile.persistence_failed", "could not persist profile revision")
        }
        profiles[key] = published
        states[key] = state
        return published
    }

    public func profile(
        profileID: String,
        revision: UInt64
    ) -> PublishedProviderProfileRevision? {
        let key = ProfileKey(id: profileID, revision: revision)
        do {
            let rows = try database.queryRows(
                """
                SELECT lifecycle, record_schema_version, record_json
                FROM provider_profile_revisions
                WHERE profile_id = ?1 AND revision = ?2
                """,
                bindings: [.text(profileID), .text(String(revision))]
            )
            guard let row = rows.first else {
                profiles.removeValue(forKey: key)
                return nil
            }
            guard rows.count == 1,
                  row.integer("record_schema_version") == 3,
                  let json = row.text("record_json")
            else {
                profiles.removeValue(forKey: key)
                return nil
            }
            guard let value = try Self.decode(
                PersistedProfileRevision.self,
                json: json
            ).published else {
                profiles.removeValue(forKey: key)
                return nil
            }
            guard value.revision.profileID == profileID,
                  value.revision.revision == revision,
                  value.lifecycle.rawValue == row.text("lifecycle")
            else {
                profiles.removeValue(forKey: key)
                return nil
            }
            profiles[key] = value
            return value
        } catch {
            profiles.removeValue(forKey: key)
            return nil
        }
    }

    public func state(
        profileID: String,
        profileRevision: UInt64
    ) -> ProviderProfileState? {
        let key = ProfileKey(id: profileID, revision: profileRevision)
        do {
            let rows = try database.queryRows(
                """
                SELECT state_revision, record_schema_version, record_json
                FROM provider_profile_state
                WHERE profile_id = ?1 AND profile_revision = ?2
                """,
                bindings: [.text(profileID), .text(String(profileRevision))]
            )
            guard let row = rows.first else {
                states.removeValue(forKey: key)
                return nil
            }
            guard rows.count == 1,
                  row.integer("record_schema_version") == 2,
                  let json = row.text("record_json")
            else {
                states.removeValue(forKey: key)
                return nil
            }
            let value = try Self.decode(PersistedProfileState.self, json: json).state
            guard row.text("state_revision") == String(value.stateRevision),
                  value.profileID == profileID,
                  value.profileRevision == profileRevision
            else {
                states.removeValue(forKey: key)
                return nil
            }
            states[key] = value
            return value
        } catch {
            states.removeValue(forKey: key)
            return nil
        }
    }

    @discardableResult
    public func updateState(
        profileID: String,
        profileRevision: UInt64,
        expectedStateRevision: UInt64,
        transform: @Sendable (inout ProviderProfileState) throws -> Void
    ) throws -> ProviderProfileState {
        let key = ProfileKey(id: profileID, revision: profileRevision)
        guard let current = states[key] else {
            throw failure("provider_profile.not_found", "provider profile state does not exist")
        }
        guard current.stateRevision == expectedStateRevision else {
            throw failure("provider_profile.state_revision_conflict", "provider profile state changed")
        }
        guard expectedStateRevision < UInt64.max else {
            throw failure("provider_profile.state_revision_overflow", "provider profile state revision overflow")
        }
        var updated = current
        try transform(&updated)
        updated.stateRevision = expectedStateRevision + 1

        do {
            let changed = try database.executeChanges(
                """
                UPDATE provider_profile_state SET
                  retention_approval_revision = ?1, retention_approval_digest = ?2,
                  catalog_revision = ?3, state_revision = ?4, record_json = ?5
                WHERE profile_id = ?6 AND profile_revision = ?7 AND state_revision = ?8
                """,
                bindings: [
                    updated.retentionApprovalRevision.map { .text(String($0)) } ?? .null,
                    updated.retentionApprovalDigest.map(SQLiteValue.text) ?? .null,
                    updated.catalogRevision.map { .text(String($0)) } ?? .null,
                    .text(String(updated.stateRevision)),
                    .text(try Self.encode(PersistedProfileState(state: updated))),
                    .text(profileID), .text(String(profileRevision)),
                    .text(String(expectedStateRevision)),
                ]
            )
            guard changed == 1 else {
                throw failure("provider_profile.state_revision_conflict", "provider profile state changed")
            }
        } catch let profileFailure as ProviderProfileFailure {
            throw profileFailure
        } catch {
            throw failure("provider_profile.persistence_failed", "could not update provider profile state")
        }
        states[key] = updated
        return updated
    }

    public func archive(
        profileID: String,
        revision: UInt64,
        expectedLifecycle: ProviderRevisionLifecycle
    ) throws {
        let key = ProfileKey(id: profileID, revision: revision)
        guard let current = profiles[key] else {
            throw failure("provider_profile.not_found", "provider profile revision does not exist")
        }
        guard current.lifecycle == expectedLifecycle else {
            throw failure("provider_profile.lifecycle_conflict", "provider profile lifecycle changed")
        }
        if current.lifecycle == .archived { return }
        let archived = PublishedProviderProfileRevision(
            revision: current.revision,
            origin: current.origin,
            lifecycle: .archived
        )
        do {
            let changed = try database.executeChanges(
                """
                UPDATE provider_profile_revisions SET lifecycle = ?1, record_json = ?2
                WHERE profile_id = ?3 AND revision = ?4 AND lifecycle = ?5
                """,
                bindings: [
                    .text(ProviderRevisionLifecycle.archived.rawValue),
                    .text(try Self.encode(PersistedProfileRevision(published: archived))),
                    .text(profileID), .text(String(revision)), .text(expectedLifecycle.rawValue),
                ]
            )
            guard changed == 1 else {
                throw failure("provider_profile.lifecycle_conflict", "provider profile lifecycle changed")
            }
        } catch let profileFailure as ProviderProfileFailure {
            throw profileFailure
        } catch {
            throw failure("provider_profile.persistence_failed", "could not archive provider profile")
        }
        profiles[key] = archived
    }

    @discardableResult
    public func archiveLogicalProfile(profileID: String) throws -> [String] {
        var replacements: [ProfileKey: PublishedProviderProfileRevision] = [:]
        var credentialRefs: Set<String> = []
        do {
            try database.transaction {
                let rows = try database.queryRows(
                    """
                    SELECT revision, record_schema_version, record_json
                    FROM provider_profile_revisions
                    WHERE profile_id = ?1 ORDER BY revision
                    """,
                    bindings: [.text(profileID)]
                )
                guard !rows.isEmpty else {
                    throw failure(
                        "provider_profile.not_found",
                        "logical provider profile does not exist"
                    )
                }
                var matching: [(ProfileKey, PublishedProviderProfileRevision)] = []
                for row in rows {
                    guard row.integer("record_schema_version") == 3,
                          let revisionText = row.text("revision"),
                          let revision = UInt64(revisionText),
                          let json = row.text("record_json")
                    else { throw corruptRecord("provider profile revision") }
                    guard let published = try Self.decode(
                        PersistedProfileRevision.self,
                        json: json
                    ).published else {
                        throw corruptRecord("provider profile lifecycle")
                    }
                    guard published.revision.profileID == profileID,
                          published.revision.revision == revision
                    else { throw corruptRecord("provider profile revision index") }
                    matching.append((ProfileKey(id: profileID, revision: revision), published))
                    credentialRefs.insert(published.revision.credentialRef)
                }
                for (key, current) in matching {
                    guard current.lifecycle == .active else { continue }
                    let archived = PublishedProviderProfileRevision(
                        revision: current.revision,
                        origin: current.origin,
                        lifecycle: .archived
                    )
                    let changed = try database.executeChanges(
                        """
                        UPDATE provider_profile_revisions SET lifecycle = 'archived', record_json = ?1
                        WHERE profile_id = ?2 AND revision = ?3 AND lifecycle = 'active'
                        """,
                        bindings: [
                            .text(try Self.encode(PersistedProfileRevision(published: archived))),
                            .text(profileID), .text(String(key.revision)),
                        ]
                    )
                    guard changed == 1 else {
                        throw failure(
                            "provider_profile.lifecycle_conflict",
                            "provider profile lifecycle changed"
                        )
                    }
                    replacements[key] = archived
                }
            }
        } catch let profileFailure as ProviderProfileFailure {
            throw profileFailure
        } catch {
            throw failure(
                "provider_profile.persistence_failed",
                "could not archive logical provider profile"
            )
        }
        for (key, archived) in replacements { profiles[key] = archived }
        return credentialRefs.sorted()
    }

    package func schemaVersionForTesting() -> Int {
        (try? LLMStoreSchema.userVersion(database)) ?? 0
    }

    package func tableNamesForTesting() -> [String] {
        (try? database.queryRows(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).compactMap { $0.text("name") }) ?? []
    }

    package func indexNamesForTesting() -> [String] {
        (try? database.queryRows(
            "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).compactMap { $0.text("name") }) ?? []
    }

    private func validateNewRevision(_ revision: ProviderProfileRevision) throws {
        guard !revision.profileID.isEmpty,
              !revision.displayName.isEmpty,
              !revision.credentialRef.isEmpty,
              ProviderPreset.shipped.contains(where: { $0.id == revision.presetID })
        else {
            throw failure("provider_profile.invalid_revision", "provider profile revision is invalid")
        }
        let latest = profiles.values
            .filter { $0.revision.profileID == revision.profileID }
            .map { $0.revision.revision }
            + creating.values
                .filter { $0.revision.profileID == revision.profileID }
                .map { $0.revision.revision }
        let latestRevision = latest.max() ?? 0
        guard revision.revision > latestRevision else {
            throw failure(
                "provider_profile.revision_not_monotonic",
                "provider profile revision must increase"
            )
        }
    }

    private func validateCredentialReference(_ credentialRef: String) throws {
        let rows = try database.queryRows(
            "SELECT lifecycle, record_schema_version FROM credential_slots WHERE credential_ref = ?1",
            bindings: [.text(credentialRef)]
        )
        guard let row = rows.first else { return }
        guard rows.count == 1, row.integer("record_schema_version") == 2 else {
            throw failure("provider_profile.credential_record_invalid", "credential slot record is invalid")
        }
        guard row.text("lifecycle") == "active" else {
            throw failure(
                "provider_profile.credential_not_active",
                "provider profile cannot reference a non-active credential slot"
            )
        }
    }

    private static func load(_ database: SQLiteConnection) throws -> (
        profiles: [ProfileKey: PublishedProviderProfileRevision],
        creating: [ProfileKey: PersistedProfileRevision],
        states: [ProfileKey: ProviderProfileState]
    ) {
        var profiles: [ProfileKey: PublishedProviderProfileRevision] = [:]
        var creating: [ProfileKey: PersistedProfileRevision] = [:]
        var states: [ProfileKey: ProviderProfileState] = [:]

        for row in try database.queryRows(
            "SELECT profile_id, revision, preset_id, origin, credential_ref, retention_mode, lifecycle, record_schema_version, record_json FROM provider_profile_revisions"
        ) {
            guard row.integer("record_schema_version") == 3,
                  let id = row.text("profile_id"),
                  let revision = try parseRevision(row.text("revision")),
                  let json = row.text("record_json")
            else { throw corruptRecord("provider profile revision") }
            let persisted = try decode(
                PersistedProfileRevision.self,
                json: json
            )
            guard persisted.revision.profileID == id,
                  persisted.revision.revision == revision,
                  row.text("preset_id") == persisted.revision.presetID.rawValue,
                  row.text("origin") == persisted.origin.serialized,
                  row.text("credential_ref") == persisted.revision.credentialRef,
                  row.text("retention_mode") == persisted.revision.retentionMode.rawValue
            else {
                throw corruptRecord("provider profile revision identity")
            }
            let key = ProfileKey(id: id, revision: revision)
            switch persisted.lifecycle {
            case .creating:
                guard row.text("lifecycle") == "creating" else {
                    throw corruptRecord("provider profile lifecycle")
                }
                creating[key] = persisted
            case .active, .archived:
                guard let value = persisted.published,
                      row.text("lifecycle") == value.lifecycle.rawValue
                else {
                    throw corruptRecord("provider profile lifecycle")
                }
                profiles[key] = value
            }
        }
        for row in try database.queryRows(
            "SELECT profile_id, profile_revision, retention_approval_revision, retention_approval_digest, catalog_revision, state_revision, record_schema_version, record_json FROM provider_profile_state"
        ) {
            guard row.integer("record_schema_version") == 2,
                  let id = row.text("profile_id"),
                  let revision = try parseRevision(row.text("profile_revision")),
                  let json = row.text("record_json")
            else { throw corruptRecord("provider profile state") }
            let value = try decode(PersistedProfileState.self, json: json).state
            let retentionRevision = try optionalRevision(
                row,
                column: "retention_approval_revision"
            )
            let catalogRevision = try optionalRevision(row, column: "catalog_revision")
            guard value.profileID == id,
                  value.profileRevision == revision,
                  retentionRevision == value.retentionApprovalRevision,
                  row.text("retention_approval_digest") == value.retentionApprovalDigest,
                  catalogRevision == value.catalogRevision,
                  row.text("state_revision") == String(value.stateRevision)
            else {
                throw corruptRecord("provider profile state identity")
            }
            states[ProfileKey(id: id, revision: revision)] = value
        }
        return (profiles, creating, states)
    }

    private func archiveCreatingRevision(
        key: ProfileKey,
        pending: PersistedProfileRevision
    ) throws {
        let archived = PublishedProviderProfileRevision(
            revision: pending.revision,
            origin: pending.origin,
            lifecycle: .archived
        )
        let changed = try database.executeChanges(
            """
            UPDATE provider_profile_revisions
            SET lifecycle = 'archived', record_json = ?1
            WHERE profile_id = ?2 AND revision = ?3
              AND lifecycle = 'creating' AND record_json = ?4
            """,
            bindings: [
                .text(try Self.encode(PersistedProfileRevision(published: archived))),
                .text(key.id), .text(String(key.revision)),
                .text(try Self.encode(pending)),
            ]
        )
        guard changed == 1 else {
            throw failure(
                "provider_profile.lifecycle_conflict",
                "creating profile revision changed"
            )
        }
        creating.removeValue(forKey: key)
        profiles[key] = archived
    }

    private static func parseRevision(_ text: String?) throws -> UInt64? {
        guard let text else { return nil }
        guard text == "0" || text.first != "0", let value = UInt64(text) else {
            throw corruptRecord("revision")
        }
        return value
    }

    private static func optionalRevision(
        _ row: SQLiteRow,
        column: String
    ) throws -> UInt64? {
        if row.isNull(column) { return nil }
        guard let value = try parseRevision(row.text(column)) else {
            throw corruptRecord(column)
        }
        return value
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            throw corruptRecord("versioned JSON")
        }
    }
}

private func failure(_ code: String, _ message: String) -> ProviderProfileFailure {
    ProviderProfileFailure(code: code, message: message)
}

private func corruptRecord(_ subject: String) -> ProviderProfileFailure {
    failure("provider_profile.corrupt_record", "invalid persisted \(subject)")
}
