import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Security

public protocol EgressApprovalPrompting: Sendable {
    func requestOriginApproval(
        _ origin: EgressOrigin,
        profileName: String
    ) async -> EgressDecision

    func requestScopeApproval(
        origin: EgressOrigin,
        summary: EgressApprovalDisplaySummary
    ) async -> EgressDecision
}

package struct CloudEgressSessionContext: Equatable, Sendable {
    package let runID: String
    package let targetID: LLMTargetID
    package let targetRevision: UInt64
    package let profileID: String
    package let profileRevision: UInt64
    package let origin: EgressOrigin
    package let credentialRef: String
    package let credentialGeneration: UInt64
    package let credentialUseLeaseID: String
    package let signedToolDisplayKeys: Set<String>

    package init(
        runID: String,
        targetID: LLMTargetID,
        targetRevision: UInt64,
        profileID: String,
        profileRevision: UInt64,
        origin: EgressOrigin,
        credentialRef: String,
        credentialGeneration: UInt64,
        credentialUseLeaseID: String,
        signedToolDisplayKeys: Set<String>
    ) {
        self.runID = runID
        self.targetID = targetID
        self.targetRevision = targetRevision
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.origin = origin
        self.credentialRef = credentialRef
        self.credentialGeneration = credentialGeneration
        self.credentialUseLeaseID = credentialUseLeaseID
        self.signedToolDisplayKeys = signedToolDisplayKeys
    }
}

package struct AuthorizedCloudGenerationTurn: Equatable, Sendable {
    package let validated: ValidatedCloudGenerationTurn
    package let scopeGrant: EgressScopeGrant
    package let approvalSummary: EgressApprovalDisplaySummary
    package let authorization: GenerationEgressAuthorization
    package let egressSubjectDigest: String
    package let targetID: LLMTargetID
    package let targetRevision: UInt64
    package let profileID: String
    package let profileRevision: UInt64
    package let origin: EgressOrigin
    package let credentialRef: String
    package let credentialGeneration: UInt64
    package let credentialUseLeaseID: String
    package let credentialUseLeaseDigest: String
    package let retentionMode: ProviderRetentionMode
    package let retentionApprovalRevision: UInt64?
    package let retentionApprovalDigest: String?
    package let runID: String

    fileprivate init(
        validated: ValidatedCloudGenerationTurn,
        scopeGrant: EgressScopeGrant,
        approvalSummary: EgressApprovalDisplaySummary,
        authorization: GenerationEgressAuthorization,
        egressSubjectDigest: String,
        session: CloudEgressSessionContext,
        credentialUseLeaseDigest: String,
        retentionApproval: ProviderRetentionApproval?
    ) {
        self.validated = validated
        self.scopeGrant = scopeGrant
        self.approvalSummary = approvalSummary
        self.authorization = authorization
        self.egressSubjectDigest = egressSubjectDigest
        targetID = session.targetID
        targetRevision = session.targetRevision
        profileID = session.profileID
        profileRevision = session.profileRevision
        origin = session.origin
        credentialRef = session.credentialRef
        credentialGeneration = session.credentialGeneration
        credentialUseLeaseID = session.credentialUseLeaseID
        self.credentialUseLeaseDigest = credentialUseLeaseDigest
        retentionMode = scopeGrant.retentionMode
        retentionApprovalRevision = retentionApproval?.decisionRevision
        retentionApprovalDigest = retentionApproval?.approvalDigest
        runID = session.runID
    }
}

package struct AuthorizedCloudHTTPRequest: Equatable, Sendable {
    package let wire: CloudWireRequest
    package let authorization: CloudRequestAuthorization
    package let profileID: String
    package let profileRevision: UInt64
    package let origin: EgressOrigin
    package let baseURL: URL
    package let presetID: ProviderPresetID
    package let authentication: ProviderAuthentication
    package let semanticAdapterID: String
    package let credentialRef: String
    package let credentialUseLeaseID: String
    package let credentialUseLeaseDigest: String
    package let credentialGeneration: UInt64
    package let retentionMode: ProviderRetentionMode
    package let retentionApprovalRevision: UInt64?
    package let retentionApprovalDigest: String?

    fileprivate init(
        wire: CloudWireRequest,
        authorization: CloudRequestAuthorization,
        profileID: String,
        profileRevision: UInt64,
        origin: EgressOrigin,
        baseURL: URL,
        preset: ProviderPreset,
        credentialRef: String,
        credentialUseLeaseID: String,
        credentialUseLeaseDigest: String,
        credentialGeneration: UInt64,
        retentionMode: ProviderRetentionMode,
        retentionApprovalRevision: UInt64?,
        retentionApprovalDigest: String?
    ) {
        self.wire = wire
        self.authorization = authorization
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.origin = origin
        self.baseURL = baseURL
        presetID = preset.id
        authentication = preset.authentication
        semanticAdapterID = preset.semanticAdapterID
        self.credentialRef = credentialRef
        self.credentialUseLeaseID = credentialUseLeaseID
        self.credentialUseLeaseDigest = credentialUseLeaseDigest
        self.credentialGeneration = credentialGeneration
        self.retentionMode = retentionMode
        self.retentionApprovalRevision = retentionApprovalRevision
        self.retentionApprovalDigest = retentionApprovalDigest
    }
}

public actor ProviderEgressPolicy {
    private let database: SQLiteConnection
    private let credentialStore: ProviderCredentialStore
    private let retentionPolicy: ProviderRetentionPolicy
    private let prompt: any EgressApprovalPrompting
    private let clock: @Sendable () -> Date
    private let idGenerator: @Sendable () throws -> String

    package init(
        fileURL: URL,
        credentialStore: ProviderCredentialStore,
        retentionPolicy: ProviderRetentionPolicy,
        prompt: any EgressApprovalPrompting,
        clock: @escaping @Sendable () -> Date = Date.init,
        idGenerator: @escaping @Sendable () throws -> String = secureEgressID
    ) throws {
        let database = try SQLiteConnection(path: fileURL.path)
        guard try LLMStoreSchema.userVersion(database) == 2 else {
            throw egressFailure("egress.schema_not_ready", "egress policy requires schema version 2")
        }
        self.database = database
        self.credentialStore = credentialStore
        self.retentionPolicy = retentionPolicy
        self.prompt = prompt
        self.clock = clock
        self.idGenerator = idGenerator
        try validatePersistedEgressRecords()
    }

    package func authorizeTurn(
        _ validated: ValidatedCloudGenerationTurn,
        session: CloudEgressSessionContext,
        priorGrant: EgressScopeGrant?
    ) async throws -> AuthorizedCloudGenerationTurn {
        let disclosure = validated.semantic.disclosure
        let disclosureDigest: String
        do {
            disclosureDigest = try disclosure.computedDigest().hex
        } catch {
            throw egressFailure("egress.disclosure_invalid", "generation disclosure is invalid")
        }
        guard disclosure.contentDigest == validated.contentDigest.hex,
              disclosure.sourceRevisionDigest == validated.sourceRevisionDigest.hex
        else {
            throw egressFailure("egress.disclosure_mismatch", "validated turn no longer matches disclosure")
        }
        let route = try readRoute(session)
        _ = try await requireOriginApproval(route)
        let retentionApproval = try await retentionPolicy.requireApproval(
            profileID: session.profileID,
            profileRevision: session.profileRevision,
            origin: session.origin,
            retentionMode: route.profile.revision.retentionMode
        )

        if let existing = try existingTurnAuthorization(
            disclosureDigest: disclosureDigest,
            disclosure: disclosure,
            session: session,
            route: route,
            retentionApproval: retentionApproval,
            validated: validated
        ) {
            return try await sealAuthorizedTurn(
                validated: validated,
                session: session,
                grant: existing.grant,
                summary: existing.summary,
                authorization: existing.authorization,
                retentionApproval: retentionApproval
            )
        }

        let effective = conservativeScope(
            validated: validated,
            signedToolDisplayKeys: session.signedToolDisplayKeys
        )
        let currentGrant = try resolvePriorGrant(
            supplied: priorGrant,
            session: session,
            retentionApproval: retentionApproval
        )
        let newlyAdded = effective.dataClasses.subtracting(
            currentGrant?.allowedDataClasses ?? []
        )
        let needsExpansion = currentGrant == nil
            || !currentGrant!.allowedDataClasses.isSuperset(of: effective.dataClasses)
            || currentGrant!.maximumSensitivity < effective.maximumSensitivity
        var unsignedSummary = EgressApprovalDisplaySummary(
            disclosureDigest: disclosureDigest,
            priorScopeGrantDigest: currentGrant?.grantDigest,
            sourceSummary: effective.summary,
            newlyAddedDataClasses: newlyAdded,
            approvalSummaryDigest: ""
        )
        if unsignedSummary.newlyAddedDataClasses.isEmpty, currentGrant == nil {
            unsignedSummary = EgressApprovalDisplaySummary(
                disclosureDigest: unsignedSummary.disclosureDigest,
                priorScopeGrantDigest: nil,
                sourceSummary: unsignedSummary.sourceSummary,
                newlyAddedDataClasses: effective.dataClasses,
                approvalSummaryDigest: ""
            )
        }
        let approvalSummary = EgressApprovalDisplaySummary(
            disclosureDigest: unsignedSummary.disclosureDigest,
            priorScopeGrantDigest: unsignedSummary.priorScopeGrantDigest,
            sourceSummary: unsignedSummary.sourceSummary,
            newlyAddedDataClasses: unsignedSummary.newlyAddedDataClasses,
            approvalSummaryDigest: try egressApprovalSummaryDigest(unsignedSummary).hex
        )
        if needsExpansion {
            guard await prompt.requestScopeApproval(
                origin: session.origin,
                summary: approvalSummary
            ) == .allow else {
                throw egressFailure("egress.denied", "cloud egress scope expansion was denied")
            }
        }

        let persisted = try persistAuthorization(
            disclosure: disclosure,
            disclosureDigest: disclosureDigest,
            session: session,
            route: route,
            retentionApproval: retentionApproval,
            currentGrant: currentGrant,
            effective: effective,
            summary: approvalSummary,
            needsExpansion: needsExpansion
        )
        return try await sealAuthorizedTurn(
            validated: validated,
            session: session,
            grant: persisted.grant,
            summary: approvalSummary,
            authorization: persisted.authorization,
            retentionApproval: retentionApproval
        )
    }

    package func approveOrigin(
        profileID: String,
        profileRevision: UInt64
    ) async throws -> UInt64 {
        let profile = try readActiveProfile(profileID: profileID, revision: profileRevision)
        if let current = try currentOriginApproval(
            profileID: profileID,
            profileRevision: profileRevision,
            origin: profile.origin
        ) {
            return current.approvalRevision
        }
        guard await prompt.requestOriginApproval(
            profile.origin,
            profileName: profile.revision.displayName
        ) == .allow else {
            throw egressFailure("egress.denied", "provider origin approval was denied")
        }
        return try database.transaction {
            let live = try readActiveProfile(profileID: profileID, revision: profileRevision)
            guard live == profile else {
                throw egressFailure("egress.route_changed", "cloud route changed during origin approval")
            }
            if let current = try currentOriginApproval(
                profileID: profileID,
                profileRevision: profileRevision,
                origin: profile.origin
            ) {
                return current.approvalRevision
            }
            let revision = try nextApprovalRevision(
                table: "provider_origin_approvals",
                profileID: profileID,
                profileRevision: profileRevision,
                database: database
            )
            let approval = ProviderOriginApproval(
                profileID: profileID,
                profileRevision: profileRevision,
                approvalRevision: revision,
                origin: profile.origin,
                issuedAt: millisecondDate(clock())
            )
            try insertOriginApproval(approval)
            return revision
        }
    }

    package func sealGenerationRequest(
        _ wire: CloudWireRequest,
        authorizedTurn: AuthorizedCloudGenerationTurn
    ) async throws -> AuthorizedCloudHTTPRequest {
        guard wire.dataProvenance == .generation else {
            throw egressFailure("egress.request_class_mismatch", "generation request provenance is invalid")
        }
        try validateSealedWirePath(wire.path)
        let session = CloudEgressSessionContext(
            runID: authorizedTurn.runID,
            targetID: authorizedTurn.targetID,
            targetRevision: authorizedTurn.targetRevision,
            profileID: authorizedTurn.profileID,
            profileRevision: authorizedTurn.profileRevision,
            origin: authorizedTurn.origin,
            credentialRef: authorizedTurn.credentialRef,
            credentialGeneration: authorizedTurn.credentialGeneration,
            credentialUseLeaseID: authorizedTurn.credentialUseLeaseID,
            signedToolDisplayKeys: []
        )
        let route = try readRoute(session)
        let authorization = authorizedTurn.authorization
        let disclosureDigest = try authorizedTurn.validated.semantic.disclosure.computedDigest().hex
        guard disclosureDigest == authorization.disclosureDigest,
              authorization.generationTurnID
                == authorizedTurn.validated.semantic.disclosure.generationTurnID,
              authorization.credentialGeneration == authorizedTurn.credentialGeneration,
              authorization.retentionMode == authorizedTurn.retentionMode,
              authorization.retentionApprovalRevision == authorizedTurn.retentionApprovalRevision,
              authorization.retentionApprovalDigest == authorizedTurn.retentionApprovalDigest,
              authorization.scopeGrantID == authorizedTurn.scopeGrant.grantID,
              authorization.scopeGrantDigest == authorizedTurn.scopeGrant.grantDigest,
              try egressGenerationAuthorizationDigest(authorization).hex
                == authorization.authorizationDigest,
              authorization.expiresAt > clock()
        else {
            throw egressFailure("egress.authorization_invalid", "generation authorization is stale or inconsistent")
        }
        let retentionApproval = try await retentionPolicy.requireApproval(
            profileID: authorizedTurn.profileID,
            profileRevision: authorizedTurn.profileRevision,
            origin: authorizedTurn.origin,
            retentionMode: authorizedTurn.retentionMode
        )
        guard retentionApproval?.decisionRevision == authorizedTurn.retentionApprovalRevision,
              retentionApproval?.approvalDigest == authorizedTurn.retentionApprovalDigest
        else {
            throw egressFailure("retention.approval_invalid", "retention approval changed after authorization")
        }
        try validateRetentionBinding(session: session, retentionApproval: retentionApproval)
        let lease = try await revalidateCredentialLease(
            authorizedTurn.credentialUseLeaseID,
            credentialRef: authorizedTurn.credentialRef,
            generation: authorizedTurn.credentialGeneration,
            purpose: .preparation
        )
        guard try credentialUseLeaseDigest(lease).hex == authorizedTurn.credentialUseLeaseDigest else {
            throw egressFailure("egress.credential_lease_changed", "credential lease changed after authorization")
        }
        guard try currentOriginApproval(
            profileID: authorizedTurn.profileID,
            profileRevision: authorizedTurn.profileRevision,
            origin: authorizedTurn.origin
        ) != nil,
              let preset = providerPreset(route.profile.revision.presetID)
        else {
            throw egressFailure("egress.route_invalid", "authorized provider route is unavailable")
        }
        return AuthorizedCloudHTTPRequest(
            wire: wire,
            authorization: .generation(GenerationRequestSeal(
                generationAuthorizationID: authorization.authorizationID,
                generationAuthorizationDigest: authorization.authorizationDigest,
                disclosureDigest: authorization.disclosureDigest
            )),
            profileID: authorizedTurn.profileID,
            profileRevision: authorizedTurn.profileRevision,
            origin: authorizedTurn.origin,
            baseURL: route.profile.revision.baseURL,
            preset: preset,
            credentialRef: authorizedTurn.credentialRef,
            credentialUseLeaseID: authorizedTurn.credentialUseLeaseID,
            credentialUseLeaseDigest: authorizedTurn.credentialUseLeaseDigest,
            credentialGeneration: authorizedTurn.credentialGeneration,
            retentionMode: authorizedTurn.retentionMode,
            retentionApprovalRevision: authorizedTurn.retentionApprovalRevision,
            retentionApprovalDigest: authorizedTurn.retentionApprovalDigest
        )
    }

    package func sealValidationRequest(
        _ wire: CloudWireRequest,
        profileID: String,
        profileRevision: UInt64,
        originApprovalRevision: UInt64,
        lease: CredentialUseLease,
        requestClass: CloudRequestClass
    ) async throws -> AuthorizedCloudHTTPRequest {
        guard requestClass == .discovery
                || requestClass == .accountValidation
                || requestClass == .modelValidation,
              case let .noUserData(presetEncoderID, provenanceClass) = wire.dataProvenance,
              provenanceClass == requestClass
        else {
            throw egressFailure("egress.request_class_mismatch", "validation request contains unapproved data provenance")
        }
        try validateSealedWirePath(wire.path)
        let profile = try readActiveProfile(profileID: profileID, revision: profileRevision)
        guard let preset = providerPreset(profile.revision.presetID),
              preset.codecID == presetEncoderID,
              let originApproval = try currentOriginApproval(
                  profileID: profileID,
                  profileRevision: profileRevision,
                  origin: profile.origin
              ),
              originApproval.approvalRevision == originApprovalRevision,
              lease.credentialRef == profile.revision.credentialRef,
              lease.purpose == .validation
        else {
            throw egressFailure("egress.validation_route_invalid", "validation route authorization is invalid")
        }
        let liveLease = try await revalidateCredentialLease(
            lease.leaseID,
            credentialRef: lease.credentialRef,
            generation: lease.generation,
            purpose: .validation
        )
        guard liveLease == lease else {
            throw egressFailure("egress.credential_lease_changed", "validation credential lease changed")
        }
        let retention = try readRetentionIdentity(profile: profile)
        let seal = NonGenerationRequestSeal(
            originApprovalRevision: originApprovalRevision,
            presetEncoderID: presetEncoderID,
            requestClass: requestClass
        )
        return AuthorizedCloudHTTPRequest(
            wire: wire,
            authorization: requestClass == .discovery ? .discovery(seal) : .validation(seal),
            profileID: profileID,
            profileRevision: profileRevision,
            origin: profile.origin,
            baseURL: profile.revision.baseURL,
            preset: preset,
            credentialRef: lease.credentialRef,
            credentialUseLeaseID: lease.leaseID,
            credentialUseLeaseDigest: try credentialUseLeaseDigest(lease).hex,
            credentialGeneration: lease.generation,
            retentionMode: profile.revision.retentionMode,
            retentionApprovalRevision: retention.revision,
            retentionApprovalDigest: retention.digest
        )
    }

    package func authorizationCount() throws -> Int {
        Int(try database.queryRows(
            "SELECT COUNT(*) AS value FROM egress_generation_authorizations"
        ).first?.integer("value") ?? 0)
    }

    package func auditRecords(runID: String) throws -> [EgressAuditRecord] {
        try database.queryRows(
            "SELECT audit_id FROM egress_audit_records WHERE run_id = ?1 ORDER BY rowid",
            bindings: [.text(runID)]
        ).map { row in
            guard let auditID = row.text("audit_id"), let value = try readAudit(auditID) else {
                throw egressFailure("egress.corrupt_record", "egress audit record is missing")
            }
            return value
        }
    }

    package func persistedTextValuesForTesting() throws -> [String] {
        try [
            "provider_origin_approvals", "provider_retention_approvals",
            "egress_scope_grants", "egress_generation_authorizations",
            "egress_audit_records",
        ].flatMap { table in
            try database.query("SELECT * FROM \(table)").flatMap { row in
                row.values.compactMap { $0 }
            }
        }
    }

    private func requireOriginApproval(
        _ route: EgressRoute
    ) async throws -> ProviderOriginApproval {
        let revision = try await approveOrigin(
            profileID: route.session.profileID,
            profileRevision: route.session.profileRevision
        )
        guard let approval = try currentOriginApproval(
            profileID: route.session.profileID,
            profileRevision: route.session.profileRevision,
            origin: route.profile.origin
        ), approval.approvalRevision == revision else {
            throw egressFailure("egress.origin_approval_invalid", "origin approval disappeared")
        }
        return approval
    }

    private func currentOriginApproval(
        profileID: String,
        profileRevision: UInt64,
        origin: EgressOrigin
    ) throws -> ProviderOriginApproval? {
        let rows = try database.queryRows(
            """
            SELECT approval_revision, origin, record_schema_version, record_json
            FROM provider_origin_approvals
            WHERE profile_id = ?1 AND profile_revision = ?2
            ORDER BY CAST(approval_revision AS INTEGER) DESC LIMIT 1
            """,
            bindings: [
                .text(profileID), .text(String(profileRevision)),
            ]
        )
        guard let row = rows.first else { return nil }
        guard row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw egressFailure("egress.origin_approval_invalid", "origin approval is invalid") }
        let value = try decodeEgressRecord(
            VersionedEgressRecord<ProviderOriginApproval>.self,
            json: json
        ).value
        guard value.profileID == profileID,
              value.profileRevision == profileRevision,
              value.origin == origin,
              row.text("approval_revision") == String(value.approvalRevision),
              row.text("origin") == value.origin.serialized
        else { throw egressFailure("egress.origin_approval_invalid", "origin approval does not match route") }
        return value
    }

    private func insertOriginApproval(_ approval: ProviderOriginApproval) throws {
        try database.execute(
            """
            INSERT INTO provider_origin_approvals(
              profile_id, profile_revision, approval_revision, origin,
              record_schema_version, record_json
            ) VALUES (?1, ?2, ?3, ?4, 2, ?5)
            """,
            bindings: [
                .text(approval.profileID), .text(String(approval.profileRevision)),
                .text(String(approval.approvalRevision)), .text(approval.origin.serialized),
                .text(try encodeEgressRecord(VersionedEgressRecord(approval))),
            ]
        )
    }

    private func conservativeScope(
        validated: ValidatedCloudGenerationTurn,
        signedToolDisplayKeys: Set<String>
    ) -> EffectiveEgressScope {
        let disclosure = validated.semantic.disclosure
        var classes = disclosure.dataClasses
        var sensitivity = disclosure.highestSensitivity
        var safeSummary = disclosure.safeDisplaySummary
        var invalid = !safeSummary.triggeringToolDisplayKeys.isSubset(of: signedToolDisplayKeys)
        invalid = invalid || !Set(validated.semantic.toolResults.map(\.toolName))
            .isSubset(of: signedToolDisplayKeys)
        let countClasses = safeSummary.addedItemCounts.map(\.dataClass)
        invalid = invalid
            || Set(countClasses).count != countClasses.count
            || !Set(countClasses).isSubset(of: disclosure.dataClasses)

        for result in validated.semantic.toolResults {
            if result.dataClasses.isEmpty {
                classes.insert(.unknownData)
                sensitivity = .unknown
            } else {
                classes.formUnion(result.dataClasses)
                sensitivity = max(sensitivity, result.highestSensitivity)
            }
            if result.dataClasses.contains(.unknownData) || result.highestSensitivity == .unknown {
                classes.insert(.unknownData)
                sensitivity = .unknown
            }
        }
        if invalid {
            classes.insert(.unknownData)
            sensitivity = .unknown
            safeSummary = SafeDisplaySummary(
                sourceKinds: [.other],
                addedItemCounts: [.init(dataClass: .unknownData, count: 0)],
                approximateAddedSize: safeSummary.approximateAddedSize,
                triggeringToolDisplayKeys: []
            )
        }
        return EffectiveEgressScope(
            dataClasses: classes,
            maximumSensitivity: sensitivity,
            summary: safeSummary
        )
    }

    private func resolvePriorGrant(
        supplied: EgressScopeGrant?,
        session: CloudEgressSessionContext,
        retentionApproval: ProviderRetentionApproval?
    ) throws -> EgressScopeGrant? {
        if let supplied,
           let persisted = try readGrant(supplied.grantID) {
            guard supplied == persisted else {
                throw egressFailure("egress.prior_grant_invalid", "supplied scope grant was mutated")
            }
            if grantMatchesSession(persisted, session: session, retentionApproval: retentionApproval) {
                return persisted
            }
        }
        let rows = try database.queryRows(
            """
            SELECT grant_id FROM egress_scope_grants
            WHERE run_id = ?1 AND profile_id = ?2 AND profile_revision = ?3
              AND credential_generation = ?4 ORDER BY rowid DESC
            """,
            bindings: [
                .text(session.runID), .text(session.profileID),
                .text(String(session.profileRevision)),
                .text(String(session.credentialGeneration)),
            ]
        )
        for row in rows {
            guard let id = row.text("grant_id"), let grant = try readGrant(id) else { continue }
            if grantMatchesSession(grant, session: session, retentionApproval: retentionApproval) {
                return grant
            }
        }
        return nil
    }

    private func grantMatchesSession(
        _ grant: EgressScopeGrant,
        session: CloudEgressSessionContext,
        retentionApproval: ProviderRetentionApproval?
    ) -> Bool {
        grant.runID == session.runID
            && grant.providerProfileID == session.profileID
            && grant.providerProfileRevision == session.profileRevision
            && grant.origin == session.origin
            && grant.credentialGeneration == session.credentialGeneration
            && grant.retentionMode == (retentionApproval == nil ? .statelessRequired : .providerStateApproved)
            && grant.retentionApprovalRevision == retentionApproval?.decisionRevision
            && grant.retentionApprovalDigest == retentionApproval?.approvalDigest
            && grant.revokedAt == nil
            && (grant.expiresAt == nil || grant.expiresAt! > clock())
    }

    private func persistAuthorization(
        disclosure: GenerationDisclosure,
        disclosureDigest: String,
        session: CloudEgressSessionContext,
        route: EgressRoute,
        retentionApproval: ProviderRetentionApproval?,
        currentGrant: EgressScopeGrant?,
        effective: EffectiveEgressScope,
        summary: EgressApprovalDisplaySummary,
        needsExpansion: Bool
    ) throws -> (grant: EgressScopeGrant, authorization: GenerationEgressAuthorization) {
        let now = millisecondDate(clock())
        let grantID = needsExpansion ? try idGenerator() : nil
        let authorizationID = try idGenerator()
        let auditID = try idGenerator()
        return try database.transaction {
            guard try readRoute(session) == route else {
                throw egressFailure("egress.route_changed", "cloud route changed before authorization commit")
            }
            let duplicateTurns = try database.queryRows(
                "SELECT authorization_id FROM egress_generation_authorizations WHERE generation_turn_id = ?1",
                bindings: [.text(disclosure.generationTurnID)]
            )
            guard duplicateTurns.isEmpty else {
                throw egressFailure(
                    "egress.turn_already_authorized",
                    "generation turn was concurrently authorized; retry exact replay"
                )
            }
            try validateRetentionBinding(
                session: session,
                retentionApproval: retentionApproval
            )
            let grant: EgressScopeGrant
            if needsExpansion {
                let allowed = (currentGrant?.allowedDataClasses ?? []).union(effective.dataClasses)
                let maximum = max(currentGrant?.maximumSensitivity ?? .routine, effective.maximumSensitivity)
                let priorDecisionRevision = currentGrant?.decisionRevision ?? 0
                guard priorDecisionRevision < UInt64.max else {
                    throw egressFailure(
                        "egress.decision_revision_overflow",
                        "egress decision revision overflow"
                    )
                }
                let unsigned = EgressScopeGrant(
                    grantID: try requireGeneratedID(grantID),
                    runID: session.runID,
                    providerProfileID: session.profileID,
                    providerProfileRevision: session.profileRevision,
                    origin: session.origin,
                    credentialGeneration: session.credentialGeneration,
                    retentionMode: route.profile.revision.retentionMode,
                    retentionApprovalRevision: retentionApproval?.decisionRevision,
                    retentionApprovalDigest: retentionApproval?.approvalDigest,
                    allowedDataClasses: allowed,
                    maximumSensitivity: maximum,
                    decisionRevision: priorDecisionRevision + 1,
                    issuedAt: now,
                    expiresAt: nil,
                    revokedAt: nil,
                    grantDigest: ""
                )
                grant = EgressScopeGrant(
                    grantID: unsigned.grantID,
                    runID: unsigned.runID,
                    providerProfileID: unsigned.providerProfileID,
                    providerProfileRevision: unsigned.providerProfileRevision,
                    origin: unsigned.origin,
                    credentialGeneration: unsigned.credentialGeneration,
                    retentionMode: unsigned.retentionMode,
                    retentionApprovalRevision: unsigned.retentionApprovalRevision,
                    retentionApprovalDigest: unsigned.retentionApprovalDigest,
                    allowedDataClasses: unsigned.allowedDataClasses,
                    maximumSensitivity: unsigned.maximumSensitivity,
                    decisionRevision: unsigned.decisionRevision,
                    issuedAt: unsigned.issuedAt,
                    expiresAt: unsigned.expiresAt,
                    revokedAt: unsigned.revokedAt,
                    grantDigest: try egressScopeGrantDigest(unsigned).hex
                )
                try insertGrant(grant)
            } else {
                guard let currentGrant else {
                    throw egressFailure("egress.grant_missing", "approved scope grant disappeared")
                }
                grant = currentGrant
            }
            let authorizationExpires = millisecondDate(now.addingTimeInterval(300))
            let unsignedAuthorization = GenerationEgressAuthorization(
                authorizationID: authorizationID,
                generationTurnID: disclosure.generationTurnID,
                disclosureDigest: disclosureDigest,
                approvalSummaryDigest: summary.approvalSummaryDigest,
                scopeGrantID: grant.grantID,
                scopeGrantDigest: grant.grantDigest,
                credentialGeneration: session.credentialGeneration,
                retentionMode: route.profile.revision.retentionMode,
                retentionApprovalRevision: retentionApproval?.decisionRevision,
                retentionApprovalDigest: retentionApproval?.approvalDigest,
                issuedAt: now,
                expiresAt: authorizationExpires,
                authorizationDigest: ""
            )
            let authorization = GenerationEgressAuthorization(
                authorizationID: unsignedAuthorization.authorizationID,
                generationTurnID: unsignedAuthorization.generationTurnID,
                disclosureDigest: unsignedAuthorization.disclosureDigest,
                approvalSummaryDigest: unsignedAuthorization.approvalSummaryDigest,
                scopeGrantID: unsignedAuthorization.scopeGrantID,
                scopeGrantDigest: unsignedAuthorization.scopeGrantDigest,
                credentialGeneration: unsignedAuthorization.credentialGeneration,
                retentionMode: unsignedAuthorization.retentionMode,
                retentionApprovalRevision: unsignedAuthorization.retentionApprovalRevision,
                retentionApprovalDigest: unsignedAuthorization.retentionApprovalDigest,
                issuedAt: unsignedAuthorization.issuedAt,
                expiresAt: unsignedAuthorization.expiresAt,
                authorizationDigest: try egressGenerationAuthorizationDigest(unsignedAuthorization).hex
            )
            try insertAuthorization(authorization, summary: summary)
            let previous = try database.queryRows(
                "SELECT chain_digest FROM egress_audit_records WHERE run_id = ?1 ORDER BY rowid DESC LIMIT 1",
                bindings: [.text(session.runID)]
            ).first?.text("chain_digest")
            let unsignedAudit = EgressAuditRecord(
                auditID: auditID,
                runID: session.runID,
                previousChainDigest: previous,
                generationTurnID: disclosure.generationTurnID,
                disclosureDigest: disclosureDigest,
                scopeGrantDigest: grant.grantDigest,
                generationAuthorizationDigest: authorization.authorizationDigest,
                recordedAt: now,
                chainDigest: ""
            )
            let audit = EgressAuditRecord(
                auditID: unsignedAudit.auditID,
                runID: unsignedAudit.runID,
                previousChainDigest: unsignedAudit.previousChainDigest,
                generationTurnID: unsignedAudit.generationTurnID,
                disclosureDigest: unsignedAudit.disclosureDigest,
                scopeGrantDigest: unsignedAudit.scopeGrantDigest,
                generationAuthorizationDigest: unsignedAudit.generationAuthorizationDigest,
                recordedAt: unsignedAudit.recordedAt,
                chainDigest: try egressAuditChainDigest(unsignedAudit).hex
            )
            try insertAudit(audit)
            return (grant, authorization)
        }
    }

    private func sealAuthorizedTurn(
        validated: ValidatedCloudGenerationTurn,
        session: CloudEgressSessionContext,
        grant: EgressScopeGrant,
        summary: EgressApprovalDisplaySummary,
        authorization: GenerationEgressAuthorization,
        retentionApproval: ProviderRetentionApproval?
    ) async throws -> AuthorizedCloudGenerationTurn {
        let lease = try await revalidateCredentialLease(
            session.credentialUseLeaseID,
            credentialRef: session.credentialRef,
            generation: session.credentialGeneration,
            purpose: .preparation
        )
        let leaseDigest = try credentialUseLeaseDigest(lease).hex
        let subject = EgressSubjectFixture(
            providerProfileID: session.profileID,
            providerProfileRevision: session.profileRevision,
            origin: session.origin,
            credentialGeneration: session.credentialGeneration,
            retentionMode: authorization.retentionMode,
            retentionApprovalRevision: retentionApproval?.decisionRevision,
            retentionApprovalDigest: retentionApproval?.approvalDigest,
            scopeGrantID: grant.grantID,
            scopeGrantDigest: grant.grantDigest,
            approvalSummaryDigest: summary.approvalSummaryDigest,
            generationAuthorizationID: authorization.authorizationID,
            generationAuthorizationDigest: authorization.authorizationDigest
        )
        return AuthorizedCloudGenerationTurn(
            validated: validated,
            scopeGrant: grant,
            approvalSummary: summary,
            authorization: authorization,
            egressSubjectDigest: try egressSubjectDigest(subject).hex,
            session: session,
            credentialUseLeaseDigest: leaseDigest,
            retentionApproval: retentionApproval
        )
    }

    private func readActiveProfile(
        profileID: String,
        revision: UInt64
    ) throws -> PublishedProviderProfileRevision {
        let rows = try database.queryRows(
            """
            SELECT origin, credential_ref, retention_mode, lifecycle,
              record_schema_version, record_json
            FROM provider_profile_revisions WHERE profile_id = ?1 AND revision = ?2
            """,
            bindings: [.text(profileID), .text(String(revision))]
        )
        guard let row = rows.first, rows.count == 1,
              row.integer("record_schema_version") == 2,
              row.text("lifecycle") == ProviderRevisionLifecycle.active.rawValue,
              let json = row.text("record_json")
        else { throw egressFailure("egress.profile_not_active", "provider profile is not active") }
        let profile = try decodeEgressRecord(PersistedProfileRevision.self, json: json).published
        guard profile.revision.profileID == profileID,
              profile.revision.revision == revision,
              profile.lifecycle == .active,
              row.text("origin") == profile.origin.serialized,
              row.text("credential_ref") == profile.revision.credentialRef,
              row.text("retention_mode") == profile.revision.retentionMode.rawValue
        else { throw egressFailure("egress.profile_invalid", "provider profile is inconsistent") }
        return profile
    }

    private func revalidateCredentialLease(
        _ leaseID: String,
        credentialRef: String,
        generation: UInt64,
        purpose: CredentialUsePurpose
    ) async throws -> CredentialUseLease {
        do {
            return try await credentialStore.revalidateLease(
                leaseID,
                credentialRef: credentialRef,
                generation: generation,
                purpose: purpose
            )
        } catch let failure as CredentialFailure {
            throw egressFailure(failure.code, failure.message)
        }
    }

    private func readRetentionIdentity(
        profile: PublishedProviderProfileRevision
    ) throws -> (revision: UInt64?, digest: String?) {
        let rows = try database.queryRows(
            """
            SELECT retention_approval_revision, retention_approval_digest
            FROM provider_profile_state WHERE profile_id = ?1 AND profile_revision = ?2
            """,
            bindings: [
                .text(profile.revision.profileID),
                .text(String(profile.revision.revision)),
            ]
        )
        guard let row = rows.first, rows.count == 1 else {
            throw egressFailure("retention.approval_invalid", "provider retention state is missing")
        }
        let revision = try row.text("retention_approval_revision").map { value -> UInt64 in
            guard let parsed = UInt64(value) else {
                throw egressFailure("retention.approval_invalid", "retention revision is invalid")
            }
            return parsed
        }
        let digest = row.text("retention_approval_digest")
        guard (revision == nil) == (digest == nil),
              profile.revision.retentionMode == .statelessRequired
                ? revision == nil
                : revision != nil
        else {
            throw egressFailure("retention.approval_invalid", "retention approval binding is incomplete")
        }
        return (revision, digest)
    }

    private func validateSealedWirePath(_ path: String) throws {
        do {
            try CloudTransportPolicy.validateWirePath(path)
        } catch {
            throw egressFailure("egress.request_path_forbidden", "cloud request path was rejected")
        }
    }

    private func providerPreset(_ id: ProviderPresetID) -> ProviderPreset? {
        let matches = ProviderPreset.shipped.filter { $0.id == id }
        return matches.count == 1 ? matches[0] : nil
    }

    private func readRoute(_ session: CloudEgressSessionContext) throws -> EgressRoute {
        guard !session.runID.isEmpty, !session.credentialUseLeaseID.isEmpty else {
            throw egressFailure("egress.session_invalid", "cloud egress session identity is empty")
        }
        let profile = try readActiveProfile(
            profileID: session.profileID,
            revision: session.profileRevision
        )
        guard profile.revision.profileID == session.profileID,
              profile.revision.revision == session.profileRevision,
              profile.origin == session.origin,
              profile.revision.credentialRef == session.credentialRef
        else { throw egressFailure("egress.route_mismatch", "provider profile does not match egress session") }

        let targetRows = try database.queryRows(
            """
            SELECT profile_id, profile_revision, record_schema_version, record_json
            FROM llm_target_revisions WHERE target_id = ?1 AND revision = ?2
            """,
            bindings: [.text(session.targetID.rawValue), .text(String(session.targetRevision))]
        )
        guard let targetRow = targetRows.first, targetRows.count == 1,
              targetRow.integer("record_schema_version") == 2,
              let targetJSON = targetRow.text("record_json")
        else { throw egressFailure("egress.target_invalid", "cloud target is missing") }
        let target = try decodeEgressRecord(PersistedTargetRevision.self, json: targetJSON).target
        guard target.targetID == session.targetID,
              target.revision == session.targetRevision,
              targetRow.text("profile_id") == session.profileID,
              targetRow.text("profile_revision") == String(session.profileRevision),
              target.kind == .cloud(
                providerProfileID: session.profileID,
                providerProfileRevision: session.profileRevision
              )
        else { throw egressFailure("egress.target_mismatch", "cloud target does not match profile") }

        let slotRows = try database.queryRows(
            """
            SELECT current_generation, lifecycle, record_schema_version, record_json
            FROM credential_slots WHERE credential_ref = ?1
            """,
            bindings: [.text(session.credentialRef)]
        )
        guard let slotRow = slotRows.first, slotRows.count == 1,
              slotRow.integer("record_schema_version") == 2,
              slotRow.text("lifecycle") == "active",
              slotRow.text("current_generation") == String(session.credentialGeneration),
              let slotJSON = slotRow.text("record_json")
        else { throw egressFailure("egress.credential_generation_changed", "credential generation changed") }
        let slot = try decodeEgressRecord(
            VersionedCredentialRecord<CredentialSlotState>.self,
            json: slotJSON
        ).value
        guard slot.credentialRef == session.credentialRef,
              slot.currentGeneration == session.credentialGeneration,
              slot.lifecycle == .active
        else { throw egressFailure("egress.credential_generation_changed", "credential slot is invalid") }
        return EgressRoute(session: session, profile: profile, target: target)
    }

    private func validateRetentionBinding(
        session: CloudEgressSessionContext,
        retentionApproval: ProviderRetentionApproval?
    ) throws {
        let rows = try database.queryRows(
            """
            SELECT retention_approval_revision, retention_approval_digest
            FROM provider_profile_state WHERE profile_id = ?1 AND profile_revision = ?2
            """,
            bindings: [.text(session.profileID), .text(String(session.profileRevision))]
        )
        guard let row = rows.first, rows.count == 1,
              row.text("retention_approval_revision") == retentionApproval.map({ String($0.decisionRevision) }),
              row.text("retention_approval_digest") == retentionApproval?.approvalDigest
        else { throw egressFailure("retention.approval_invalid", "retention approval changed") }
    }

    private func insertGrant(_ grant: EgressScopeGrant) throws {
        try database.execute(
            """
            INSERT INTO egress_scope_grants(
              grant_id, run_id, profile_id, profile_revision, credential_generation,
              retention_mode, retention_approval_revision, retention_approval_digest,
              record_schema_version, record_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 2, ?9)
            """,
            bindings: [
                .text(grant.grantID), .text(grant.runID), .text(grant.providerProfileID),
                .text(String(grant.providerProfileRevision)),
                .text(String(grant.credentialGeneration)), .text(grant.retentionMode.rawValue),
                grant.retentionApprovalRevision.map { .text(String($0)) } ?? .null,
                grant.retentionApprovalDigest.map(SQLiteValue.text) ?? .null,
                .text(try encodeEgressRecord(VersionedEgressRecord(grant))),
            ]
        )
    }

    private func insertAuthorization(
        _ authorization: GenerationEgressAuthorization,
        summary: EgressApprovalDisplaySummary
    ) throws {
        let persisted = PersistedGenerationAuthorization(
            authorization: authorization,
            approvalSummary: summary
        )
        try database.execute(
            """
            INSERT INTO egress_generation_authorizations(
              authorization_id, generation_turn_id, grant_id, credential_generation,
              record_schema_version, record_json
            ) VALUES (?1, ?2, ?3, ?4, 2, ?5)
            """,
            bindings: [
                .text(authorization.authorizationID),
                .text(authorization.generationTurnID),
                .text(authorization.scopeGrantID),
                .text(String(authorization.credentialGeneration)),
                .text(try encodeEgressRecord(VersionedEgressRecord(persisted))),
            ]
        )
    }

    private func insertAudit(_ audit: EgressAuditRecord) throws {
        try database.execute(
            """
            INSERT INTO egress_audit_records(
              audit_id, run_id, generation_turn_id, previous_chain_digest,
              chain_digest, record_schema_version, record_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, 2, ?6)
            """,
            bindings: [
                .text(audit.auditID), .text(audit.runID),
                .text(audit.generationTurnID),
                audit.previousChainDigest.map(SQLiteValue.text) ?? .null,
                .text(audit.chainDigest),
                .text(try encodeEgressRecord(VersionedEgressRecord(audit))),
            ]
        )
    }

    nonisolated private func readGrant(_ grantID: String) throws -> EgressScopeGrant? {
        let rows = try database.queryRows(
            "SELECT * FROM egress_scope_grants WHERE grant_id = ?1",
            bindings: [.text(grantID)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1, row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw egressFailure("egress.grant_invalid", "scope grant record is invalid") }
        let grant = try decodeEgressRecord(
            VersionedEgressRecord<EgressScopeGrant>.self,
            json: json
        ).value
        guard row.text("grant_id") == grant.grantID,
              row.text("run_id") == grant.runID,
              row.text("profile_id") == grant.providerProfileID,
              row.text("profile_revision") == String(grant.providerProfileRevision),
              row.text("credential_generation") == String(grant.credentialGeneration),
              row.text("retention_mode") == grant.retentionMode.rawValue,
              row.text("retention_approval_revision") == grant.retentionApprovalRevision.map(String.init),
              row.text("retention_approval_digest") == grant.retentionApprovalDigest,
              try egressScopeGrantDigest(grant).hex == grant.grantDigest
        else { throw egressFailure("egress.grant_invalid", "scope grant record is inconsistent") }
        return grant
    }

    nonisolated private func readAuthorization(
        _ authorizationID: String
    ) throws -> PersistedGenerationAuthorization? {
        let rows = try database.queryRows(
            "SELECT * FROM egress_generation_authorizations WHERE authorization_id = ?1",
            bindings: [.text(authorizationID)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1, row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw egressFailure("egress.authorization_invalid", "generation authorization is invalid") }
        let persisted = try decodeEgressRecord(
            VersionedEgressRecord<PersistedGenerationAuthorization>.self,
            json: json
        ).value
        let value = persisted.authorization
        guard row.text("authorization_id") == value.authorizationID,
              row.text("generation_turn_id") == value.generationTurnID,
              row.text("grant_id") == value.scopeGrantID,
              row.text("credential_generation") == String(value.credentialGeneration),
              persisted.approvalSummary.approvalSummaryDigest == value.approvalSummaryDigest,
              try egressGenerationAuthorizationDigest(value).hex == value.authorizationDigest,
              try egressApprovalSummaryDigest(persisted.approvalSummary).hex
                == persisted.approvalSummary.approvalSummaryDigest
        else { throw egressFailure("egress.authorization_invalid", "authorization record is inconsistent") }
        return persisted
    }

    nonisolated private func readAudit(_ auditID: String) throws -> EgressAuditRecord? {
        let rows = try database.queryRows(
            "SELECT * FROM egress_audit_records WHERE audit_id = ?1",
            bindings: [.text(auditID)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1, row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw egressFailure("egress.audit_invalid", "audit record is invalid") }
        let audit = try decodeEgressRecord(
            VersionedEgressRecord<EgressAuditRecord>.self,
            json: json
        ).value
        guard row.text("audit_id") == audit.auditID,
              row.text("run_id") == audit.runID,
              row.text("generation_turn_id") == audit.generationTurnID,
              row.text("previous_chain_digest") == audit.previousChainDigest,
              row.text("chain_digest") == audit.chainDigest,
              try egressAuditChainDigest(audit).hex == audit.chainDigest
        else { throw egressFailure("egress.audit_invalid", "audit record is inconsistent") }
        return audit
    }

    private func existingTurnAuthorization(
        disclosureDigest: String,
        disclosure: GenerationDisclosure,
        session: CloudEgressSessionContext,
        route: EgressRoute,
        retentionApproval: ProviderRetentionApproval?,
        validated: ValidatedCloudGenerationTurn
    ) throws -> ExistingAuthorization? {
        let auditRows = try database.queryRows(
            "SELECT audit_id FROM egress_audit_records WHERE run_id = ?1 AND generation_turn_id = ?2",
            bindings: [.text(session.runID), .text(disclosure.generationTurnID)]
        )
        guard !auditRows.isEmpty else { return nil }
        guard auditRows.count == 1,
              let auditID = auditRows.first?.text("audit_id"),
              let audit = try readAudit(auditID),
              audit.disclosureDigest == disclosureDigest
        else {
            throw egressFailure(
                "egress.turn_replay_conflict",
                "generation turn audit differs from replay input"
            )
        }
        let authorizationRows = try database.queryRows(
            "SELECT authorization_id FROM egress_generation_authorizations WHERE generation_turn_id = ?1",
            bindings: [.text(disclosure.generationTurnID)]
        )
        let matching = try authorizationRows.compactMap { row -> PersistedGenerationAuthorization? in
            guard let id = row.text("authorization_id"),
                  let persisted = try readAuthorization(id),
                  persisted.authorization.authorizationDigest == audit.generationAuthorizationDigest
            else { return nil }
            return persisted
        }
        guard matching.count == 1,
              let persisted = matching.first,
              persisted.authorization.disclosureDigest == disclosureDigest,
              persisted.authorization.credentialGeneration == session.credentialGeneration,
              persisted.authorization.retentionMode == route.profile.revision.retentionMode,
              persisted.authorization.retentionApprovalRevision == retentionApproval?.decisionRevision,
              persisted.authorization.retentionApprovalDigest == retentionApproval?.approvalDigest,
              let grant = try readGrant(persisted.authorization.scopeGrantID),
              grantMatchesSession(grant, session: session, retentionApproval: retentionApproval),
              persisted.authorization.expiresAt > clock(),
              validated.semantic.disclosure.generationTurnID == persisted.authorization.generationTurnID
        else {
            throw egressFailure(
                "egress.turn_replay_conflict",
                "generation turn ID was reused with different authorization input"
            )
        }
        return ExistingAuthorization(
            grant: grant,
            summary: persisted.approvalSummary,
            authorization: persisted.authorization
        )
    }

    nonisolated private func validatePersistedEgressRecords() throws {
        for row in try database.queryRows("SELECT grant_id FROM egress_scope_grants") {
            guard let id = row.text("grant_id"), try readGrant(id) != nil else {
                throw egressFailure("egress.corrupt_record", "scope grant identity is invalid")
            }
        }
        for row in try database.queryRows(
            "SELECT authorization_id FROM egress_generation_authorizations"
        ) {
            guard let id = row.text("authorization_id"), try readAuthorization(id) != nil else {
                throw egressFailure("egress.corrupt_record", "authorization identity is invalid")
            }
        }
        var chainHeads: [String: String] = [:]
        for row in try database.queryRows(
            "SELECT audit_id, run_id FROM egress_audit_records ORDER BY run_id, rowid"
        ) {
            guard let id = row.text("audit_id"),
                  let runID = row.text("run_id"),
                  let audit = try readAudit(id),
                  audit.previousChainDigest == chainHeads[runID]
            else {
                throw egressFailure("egress.corrupt_record", "audit identity is invalid")
            }
            chainHeads[runID] = audit.chainDigest
        }
    }
}

private struct ProviderOriginApproval: Codable, Equatable, Sendable {
    let profileID: String
    let profileRevision: UInt64
    let approvalRevision: UInt64
    let origin: EgressOrigin
    let issuedAt: Date
}

private struct PersistedGenerationAuthorization: Codable, Equatable, Sendable {
    let authorization: GenerationEgressAuthorization
    let approvalSummary: EgressApprovalDisplaySummary
}

private struct EffectiveEgressScope: Equatable, Sendable {
    let dataClasses: Set<EgressDataClass>
    let maximumSensitivity: DataSensitivity
    let summary: SafeDisplaySummary
}

private struct ExistingAuthorization: Sendable {
    let grant: EgressScopeGrant
    let summary: EgressApprovalDisplaySummary
    let authorization: GenerationEgressAuthorization
}

private struct EgressRoute: Equatable, Sendable {
    let session: CloudEgressSessionContext
    let profile: PublishedProviderProfileRevision
    let target: LLMTargetRevision
}

private func requireGeneratedID(_ id: String?) throws -> String {
    guard let id, !id.isEmpty else {
        throw egressFailure("egress.random_failed", "egress identity generation failed")
    }
    return id
}

private func secureEgressID() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw egressFailure("egress.random_failed", "secure random generation failed")
    }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func egressFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
