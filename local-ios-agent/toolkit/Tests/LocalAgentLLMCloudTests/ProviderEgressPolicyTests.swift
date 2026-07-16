import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("Cloud egress authorization")
struct ProviderEgressPolicyTests {
    @Test
    func statelessOriginAndScopePromptOnceWhileEveryTurnGetsAuthorization() async throws {
        let harness = try await EgressHarness.make()
        defer { harness.cleanup() }
        let first = try validatedTurn(turnID: "turn-1", text: "hello")

        let authorized1 = try await harness.policy.authorizeTurn(
            first,
            session: harness.session,
            priorGrant: nil
        )
        let authorized2 = try await harness.policy.authorizeTurn(
            try validatedTurn(turnID: "turn-2", text: "changed content"),
            session: harness.session,
            priorGrant: authorized1.scopeGrant
        )

        #expect(await harness.prompt.originRequestCount == 1)
        #expect(await harness.prompt.scopeRequestCount == 1)
        #expect(await harness.prompt.retentionRequestCount == 0)
        #expect(authorized1.scopeGrant.grantID == authorized2.scopeGrant.grantID)
        #expect(authorized1.authorization.authorizationID != authorized2.authorization.authorizationID)
        #expect(authorized1.authorization.authorizationDigest != authorized2.authorization.authorizationDigest)
        #expect(authorized1.validated.semantic.disclosure.contentDigest != authorized2.validated.semantic.disclosure.contentDigest)
        #expect(await harness.vault.loadCount == 0)
    }

    @Test
    func exactTurnReplayReturnsTheSameAuthorizationWithoutNewPromptOrAudit() async throws {
        let harness = try await EgressHarness.make()
        defer { harness.cleanup() }
        let turn = try validatedTurn(turnID: "turn-1", text: "hello")

        let first = try await harness.policy.authorizeTurn(
            turn,
            session: harness.session,
            priorGrant: nil
        )
        let replay = try await harness.policy.authorizeTurn(
            turn,
            session: harness.session,
            priorGrant: first.scopeGrant
        )

        #expect(replay.authorization == first.authorization)
        #expect(replay.scopeGrant == first.scopeGrant)
        #expect(await harness.prompt.scopeRequestCount == 1)
        #expect(try await harness.policy.auditRecords(runID: "run-1").count == 1)
    }

    @Test
    func expandedToolResultDenialStopsBeforeAdapterCredentialOrNetworkBoundary() async throws {
        let harness = try await EgressHarness.make()
        defer { harness.cleanup() }
        let initial = try await harness.policy.authorizeTurn(
            try validatedTurn(turnID: "turn-1", text: "hello"),
            session: harness.session,
            priorGrant: nil
        )
        await harness.prompt.enqueueScopeDecision(.deny)
        let expanded = try validatedTurn(
            turnID: "turn-2",
            text: "resume",
            classes: [.text, .contacts, .toolResult],
            sensitivity: .sensitive,
            toolDisplayKeys: ["contacts.search"],
            includeToolResult: true
        )

        await expectEgressFailure("egress.denied") {
            try await harness.policy.authorizeTurn(
                expanded,
                session: harness.session,
                priorGrant: initial.scopeGrant
            )
        }

        #expect(await harness.vault.loadCount == 0)
        #expect(try await harness.policy.authorizationCount() == 1)
        #expect(try await harness.policy.auditRecords(runID: "run-1").count == 1)
    }

    @Test
    func approvedExpansionLinksPriorGrantAndAuditChain() async throws {
        let harness = try await EgressHarness.make()
        defer { harness.cleanup() }
        let first = try await harness.policy.authorizeTurn(
            try validatedTurn(turnID: "turn-1", text: "hello"),
            session: harness.session,
            priorGrant: nil
        )
        let expanded = try await harness.policy.authorizeTurn(
            try validatedTurn(
                turnID: "turn-2",
                text: "resume",
                classes: [.text, .contacts, .toolResult],
                sensitivity: .sensitive,
                toolDisplayKeys: ["contacts.search"],
                includeToolResult: true
            ),
            session: harness.session,
            priorGrant: first.scopeGrant
        )

        #expect(await harness.prompt.scopeRequestCount == 2)
        #expect(expanded.scopeGrant.grantID != first.scopeGrant.grantID)
        #expect(expanded.scopeGrant.allowedDataClasses == [.text, .contacts, .toolResult])
        #expect(expanded.approvalSummary.priorScopeGrantDigest == first.scopeGrant.grantDigest)
        let records = try await harness.policy.auditRecords(runID: "run-1")
        #expect(records.count == 2)
        #expect(records[1].previousChainDigest == records[0].chainDigest)
    }

    @Test
    func reopenRejectsAValidlyRehashedAuditFork() async throws {
        let harness = try await EgressHarness.make()
        defer { harness.cleanup() }
        let first = try await harness.policy.authorizeTurn(
            try validatedTurn(turnID: "turn-1", text: "hello"),
            session: harness.session,
            priorGrant: nil
        )
        _ = try await harness.policy.authorizeTurn(
            try validatedTurn(turnID: "turn-2", text: "changed"),
            session: harness.session,
            priorGrant: first.scopeGrant
        )
        let database = try SQLiteConnection(
            path: harness.directory.appendingPathComponent("llm-state.sqlite").path
        )
        let rows = try database.queryRows(
            "SELECT audit_id, record_json FROM egress_audit_records ORDER BY rowid"
        )
        let second = try #require(rows.last)
        let json = try #require(second.text("record_json"))
        let persisted = try decodeEgressRecord(
            VersionedEgressRecord<EgressAuditRecord>.self,
            json: json
        ).value
        let forkBase = EgressAuditRecord(
            auditID: persisted.auditID,
            runID: persisted.runID,
            previousChainDigest: String(repeating: "a", count: 64),
            generationTurnID: persisted.generationTurnID,
            disclosureDigest: persisted.disclosureDigest,
            scopeGrantDigest: persisted.scopeGrantDigest,
            generationAuthorizationDigest: persisted.generationAuthorizationDigest,
            recordedAt: persisted.recordedAt,
            chainDigest: ""
        )
        let fork = EgressAuditRecord(
            auditID: forkBase.auditID,
            runID: forkBase.runID,
            previousChainDigest: forkBase.previousChainDigest,
            generationTurnID: forkBase.generationTurnID,
            disclosureDigest: forkBase.disclosureDigest,
            scopeGrantDigest: forkBase.scopeGrantDigest,
            generationAuthorizationDigest: forkBase.generationAuthorizationDigest,
            recordedAt: forkBase.recordedAt,
            chainDigest: try egressAuditChainDigest(forkBase).hex
        )
        try database.execute(
            "UPDATE egress_audit_records SET previous_chain_digest = ?1, chain_digest = ?2, record_json = ?3 WHERE audit_id = ?4",
            bindings: [
                .text(try #require(fork.previousChainDigest)), .text(fork.chainDigest),
                .text(try encodeEgressRecord(VersionedEgressRecord(fork))),
                .text(fork.auditID),
            ]
        )

        do {
            _ = try ProviderEgressPolicy(
                fileURL: harness.directory.appendingPathComponent("llm-state.sqlite"),
                credentialStore: harness.credentials,
                retentionPolicy: harness.retentionPolicy,
                prompt: harness.prompt
            )
            Issue.record("expected an invalid audit chain to fail reopen")
        } catch let failure as LLMFailure {
            #expect(failure.code == "egress.corrupt_record")
        }
    }

    @Test
    func unknownToolDisplayKeyForcesUnknownDataAndMaximumSensitivity() async throws {
        let harness = try await EgressHarness.make()
        defer { harness.cleanup() }

        let authorized = try await harness.policy.authorizeTurn(
            try validatedTurn(
                turnID: "turn-1",
                text: "hello",
                toolDisplayKeys: ["attacker supplied label"]
            ),
            session: harness.session,
            priorGrant: nil
        )

        #expect(authorized.scopeGrant.allowedDataClasses.contains(.unknownData))
        #expect(authorized.scopeGrant.maximumSensitivity == .unknown)
        let shown = try #require(await harness.prompt.lastScopeSummary)
        #expect(shown.newlyAddedDataClasses.contains(.unknownData))
        #expect(shown.sourceSummary.triggeringToolDisplayKeys.isEmpty)
    }

    @Test
    func missingToolResultLabelsForceUnknownScope() async throws {
        let harness = try await EgressHarness.make()
        defer { harness.cleanup() }

        let authorized = try await harness.policy.authorizeTurn(
            try validatedTurn(
                turnID: "turn-1",
                text: "resume",
                toolDisplayKeys: ["contacts.search"],
                includeToolResult: true,
                toolResultClasses: [],
                toolResultSensitivity: .routine
            ),
            session: harness.session,
            priorGrant: nil
        )

        #expect(authorized.scopeGrant.allowedDataClasses.contains(.unknownData))
        #expect(authorized.scopeGrant.maximumSensitivity == .unknown)
    }

    @Test
    func providerStateRequiresExactExplicitRetentionApproval() async throws {
        let harness = try await EgressHarness.make(
            retentionMode: .providerStateApproved
        )
        defer { harness.cleanup() }
        let turn = try validatedTurn(turnID: "turn-1", text: "hello")

        await expectEgressFailure("retention.approval_required") {
            try await harness.policy.authorizeTurn(
                turn,
                session: harness.session,
                priorGrant: nil
            )
        }
        let approval = try await harness.retentionPolicy.approveProviderState(
            profileID: "profile-main",
            profileRevision: 1,
            disclosure: ProviderRetentionDisclosure(
                behavior: .serverSideConversationState,
                windowClass: .thirtyOneToSixtyDays
            )
        )
        let replay = try await harness.retentionPolicy.approveProviderState(
            profileID: "profile-main",
            profileRevision: 1,
            disclosure: ProviderRetentionDisclosure(
                behavior: .serverSideConversationState,
                windowClass: .thirtyOneToSixtyDays
            )
        )
        #expect(approval == replay)
        #expect(await harness.prompt.retentionRequestCount == 1)

        let authorized = try await harness.policy.authorizeTurn(
            turn,
            session: harness.session,
            priorGrant: nil
        )
        #expect(authorized.authorization.retentionApprovalRevision == approval.decisionRevision)
        #expect(authorized.authorization.retentionApprovalDigest == approval.approvalDigest)
    }

    @Test
    func providerStateRejectsAProfileStateCrossLinkToTheWrongApprovalRevision() async throws {
        let harness = try await EgressHarness.make(retentionMode: .providerStateApproved)
        defer { harness.cleanup() }
        _ = try await harness.retentionPolicy.approveProviderState(
            profileID: "profile-main",
            profileRevision: 1,
            disclosure: ProviderRetentionDisclosure(
                behavior: .serverSideConversationState,
                windowClass: .thirtyOneToSixtyDays
            )
        )
        let state = try #require(await harness.profileStore.state(
            profileID: "profile-main",
            profileRevision: 1
        ))
        _ = try await harness.profileStore.updateState(
            profileID: "profile-main",
            profileRevision: 1,
            expectedStateRevision: state.stateRevision
        ) { value in
            value.retentionApprovalRevision = 999
        }

        await expectEgressFailure("retention.approval_invalid") {
            try await harness.policy.authorizeTurn(
                try validatedTurn(turnID: "turn-1", text: "hello"),
                session: harness.session,
                priorGrant: nil
            )
        }
    }

    @Test
    func aNewProfileRevisionRequiresFreshOriginAndScopeApproval() async throws {
        let harness = try await EgressHarness.make()
        defer { harness.cleanup() }
        _ = try await harness.policy.authorizeTurn(
            try validatedTurn(turnID: "turn-1", text: "hello"),
            session: harness.session,
            priorGrant: nil
        )
        let revision = try await harness.profileStore.publish(ProviderProfileRevision(
            profileID: "profile-main",
            revision: 2,
            presetID: .openAI,
            displayName: "Main Provider v2",
            baseURL: URL(string: "https://api-alt.example.com/v1")!,
            credentialRef: "credential-main"
        ))
        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target-main-v2"),
            revision: 1,
            kind: .cloud(providerProfileID: "profile-main", providerProfileRevision: 2),
            modelID: "model-main",
            defaultParameters: GenerationConfiguration()
        )
        try await harness.profileStore.publishTarget(target)
        let session = CloudEgressSessionContext(
            runID: "run-2",
            targetID: target.targetID,
            targetRevision: target.revision,
            profileID: "profile-main",
            profileRevision: 2,
            origin: revision.origin,
            credentialRef: "credential-main",
            credentialGeneration: 1,
            credentialUseLeaseID: harness.lease.leaseID,
            signedToolDisplayKeys: ["contacts.search"]
        )

        _ = try await harness.policy.authorizeTurn(
            try validatedTurn(turnID: "turn-v2", text: "hello"),
            session: session,
            priorGrant: nil
        )
        #expect(await harness.prompt.originRequestCount == 2)
        #expect(await harness.prompt.scopeRequestCount == 2)
    }

    @Test
    func credentialRotationInvalidatesPriorGrantWithoutTouchingUnrelatedRows() async throws {
        let harness = try await EgressHarness.make()
        defer { harness.cleanup() }
        let first = try await harness.policy.authorizeTurn(
            try validatedTurn(turnID: "turn-1", text: "hello"),
            session: harness.session,
            priorGrant: nil
        )
        try await harness.closePreparationLease()
        try await harness.credentials.rotateCredential(
            credentialRef: "credential-main",
            expectedGeneration: 1,
            replacement: SecretBytes(utf8: "replacement"),
            operationID: "rotate"
        )
        let nextLease = try await harness.credentials.acquireUseLease(
            credentialRef: "credential-main",
            purpose: .preparation,
            preparationID: "prep-2",
            hostProcessEpoch: harness.epoch
        )
        let nextSession = harness.session.replacing(
            credentialGeneration: 2,
            credentialUseLeaseID: nextLease.leaseID
        )

        _ = try await harness.policy.authorizeTurn(
            try validatedTurn(turnID: "turn-2", text: "hello again"),
            session: nextSession,
            priorGrant: first.scopeGrant
        )
        #expect(await harness.prompt.scopeRequestCount == 2)
    }

    @Test
    func rawConversationAndToolValuesNeverEnterPromptsOrSQLite() async throws {
        let harness = try await EgressHarness.make()
        defer { harness.cleanup() }
        let sentinel = "SENTINEL-CONTACT-NAME-NEVER-PERSIST"
        _ = try await harness.policy.authorizeTurn(
            try validatedTurn(
                turnID: "turn-1",
                text: sentinel,
                classes: [.text, .contacts, .toolResult],
                sensitivity: .sensitive,
                toolDisplayKeys: ["contacts.search"],
                includeToolResult: true,
                toolResultValue: sentinel
            ),
            session: harness.session,
            priorGrant: nil
        )

        #expect(try await harness.policy.persistedTextValuesForTesting().allSatisfy {
            !$0.contains(sentinel)
        })
        let promptJSON = try JSONEncoder().encode(await harness.prompt.scopeSummaries)
        #expect(!String(decoding: promptJSON, as: UTF8.self).contains(sentinel))
    }
}

private struct EgressHarness: Sendable {
    let directory: URL
    let profileStore: ProviderProfileStore
    let credentials: ProviderCredentialStore
    let vault: EgressCountingVault
    let prompt: EgressPromptRecorder
    let retentionPolicy: ProviderRetentionPolicy
    let policy: ProviderEgressPolicy
    let epoch: HostProcessEpoch
    let lease: CredentialUseLease
    let session: CloudEgressSessionContext

    static func make(
        retentionMode: ProviderRetentionMode = .statelessRequired
    ) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provider-egress-policy-\(UUID().uuidString)",
            isDirectory: true
        )
        let url = directory.appendingPathComponent("llm-state.sqlite")
        let profiles = try ProviderProfileStore(
            fileURL: url,
            originValidator: EgressOriginValidator()
        )
        let vault = EgressCountingVault()
        let credentials = try ProviderCredentialStore(fileURL: url, vault: vault)
        try await credentials.createSlot(
            credentialRef: "credential-main",
            initialSecret: SecretBytes(utf8: "test-only-key"),
            operationID: "create"
        )
        let published = try await profiles.publish(ProviderProfileRevision(
            profileID: "profile-main",
            revision: 1,
            presetID: .openAI,
            displayName: "Main Provider",
            baseURL: URL(string: "https://api.example.com/v1")!,
            credentialRef: "credential-main",
            retentionMode: retentionMode
        ))
        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target-main"),
            revision: 1,
            kind: .cloud(providerProfileID: "profile-main", providerProfileRevision: 1),
            modelID: "model-main",
            defaultParameters: GenerationConfiguration()
        )
        try await profiles.publishTarget(target)
        let epoch = try HostProcessEpoch.generate()
        let lease = try await credentials.acquireUseLease(
            credentialRef: "credential-main",
            purpose: .preparation,
            preparationID: "prep-1",
            hostProcessEpoch: epoch
        )
        let prompt = EgressPromptRecorder()
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let identifiers = EgressSequentialIDs()
        let retention = try ProviderRetentionPolicy(
            fileURL: url,
            prompt: prompt,
            clock: { fixedDate }
        )
        let policy = try ProviderEgressPolicy(
            fileURL: url,
            credentialStore: credentials,
            retentionPolicy: retention,
            prompt: prompt,
            clock: { fixedDate },
            idGenerator: identifiers.next
        )
        return Self(
            directory: directory,
            profileStore: profiles,
            credentials: credentials,
            vault: vault,
            prompt: prompt,
            retentionPolicy: retention,
            policy: policy,
            epoch: epoch,
            lease: lease,
            session: CloudEgressSessionContext(
                runID: "run-1",
                targetID: target.targetID,
                targetRevision: target.revision,
                profileID: published.revision.profileID,
                profileRevision: published.revision.revision,
                origin: published.origin,
                credentialRef: published.revision.credentialRef,
                credentialGeneration: lease.generation,
                credentialUseLeaseID: lease.leaseID,
                signedToolDisplayKeys: ["contacts.search"]
            )
        )
    }

    func closePreparationLease() async throws {
        let bound = try await credentials.bindPreparationLease(
            lease.leaseID,
            expectedRevision: lease.revision
        )
        let closing = try await credentials.beginClosingLease(
            lease.leaseID,
            expectedRevision: bound.revision
        )
        try await credentials.closeLease(
            lease.leaseID,
            expectedRevision: closing.revision
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private actor EgressPromptRecorder: EgressApprovalPrompting, ProviderRetentionApprovalPrompting {
    private(set) var originRequestCount = 0
    private(set) var scopeRequestCount = 0
    private(set) var retentionRequestCount = 0
    private(set) var scopeSummaries: [EgressApprovalDisplaySummary] = []
    private var scopeDecisions: [EgressDecision] = []
    var lastScopeSummary: EgressApprovalDisplaySummary? { scopeSummaries.last }

    func enqueueScopeDecision(_ decision: EgressDecision) { scopeDecisions.append(decision) }

    func requestOriginApproval(
        _ origin: EgressOrigin,
        profileName: String
    ) async -> EgressDecision {
        originRequestCount += 1
        return .allow
    }

    func requestScopeApproval(
        origin: EgressOrigin,
        summary: EgressApprovalDisplaySummary
    ) async -> EgressDecision {
        scopeRequestCount += 1
        scopeSummaries.append(summary)
        return scopeDecisions.isEmpty ? .allow : scopeDecisions.removeFirst()
    }

    func requestProviderStateApproval(
        profileName: String,
        origin: EgressOrigin,
        disclosure: ProviderRetentionDisclosure
    ) async -> EgressDecision {
        retentionRequestCount += 1
        return .allow
    }
}

private actor EgressCountingVault: CredentialVault {
    private var values: [String: Data] = [:]
    private(set) var loadCount = 0

    package func writeStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String,
        secret: SecretBytes
    ) async throws {
        values[CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )] = secret.dataCopyForVault()
    }

    package func promoteStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String
    ) async throws {
        let staged = CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )
        let final = CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )
        if values[final] != nil, values[staged] == nil { return }
        guard let value = values.removeValue(forKey: staged) else {
            throw CredentialFailure(code: "credential.missing", message: "missing staged key")
        }
        values[final] = value
    }

    package func finalExists(credentialRef: String, generation: UInt64) async throws -> Bool {
        values[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] != nil
    }

    package func loadFinal(credentialRef: String, generation: UInt64) async throws -> SecretBytes {
        loadCount += 1
        guard let value = values[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] else { throw CredentialFailure(code: "credential.missing", message: "missing key") }
        return SecretBytes(bytes: value)
    }

    package func deleteStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String
    ) async throws {
        values.removeValue(forKey: CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        ))
    }

    package func deleteFinal(credentialRef: String, generation: UInt64) async throws {
        values.removeValue(forKey: CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        ))
    }
}

private struct EgressOriginValidator: ProviderOriginValidating {
    func validate(_ baseURL: URL) async throws -> EgressOrigin {
        EgressOrigin(scheme: "https", host: baseURL.host ?? "invalid", port: 443)
    }
}

private final class EgressSequentialIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() throws -> String {
        lock.withLock {
            value += 1
            return "egress-id-\(value)"
        }
    }
}

private func validatedTurn(
    turnID: String,
    text: String,
    classes: Set<EgressDataClass> = [.text],
    sensitivity: DataSensitivity = .routine,
    toolDisplayKeys: Set<String> = [],
    includeToolResult: Bool = false,
    toolResultValue: String = "two contacts",
    toolResultClasses: Set<EgressDataClass> = [.contacts, .toolResult],
    toolResultSensitivity: DataSensitivity = .sensitive
) throws -> ValidatedCloudGenerationTurn {
    let toolResults = includeToolResult ? [NormalizedToolResult(
        callID: "call-1",
        toolName: "contacts.search",
        result: .string(toolResultValue),
        isError: false,
        dataClasses: toolResultClasses,
        highestSensitivity: toolResultSensitivity
    )] : []
    let placeholder = GenerationDisclosure(
        schemaVersion: "1",
        generationTurnID: turnID,
        contentDigest: String(repeating: "0", count: 64),
        sourceRevisionDigest: String(repeating: "0", count: 64),
        dataClasses: classes,
        highestSensitivity: sensitivity,
        safeDisplaySummary: SafeDisplaySummary(
            sourceKinds: includeToolResult ? [.conversation, .toolResult] : [.conversation],
            addedItemCounts: includeToolResult
                ? [.init(dataClass: .contacts, count: 2)]
                : [],
            approximateAddedSize: .lessThanOneKiB,
            triggeringToolDisplayKeys: toolDisplayKeys
        )
    )
    let base = CloudGenerationTurnCandidate(
        input: AgentLLMInput(
            inputID: "input-\(turnID)",
            messages: [.init(role: .user, content: [.text(text)])]
        ),
        canonicalToolSchema: try .object(entries: [
            .init(name: "tools", value: .array([.string("contacts.search")])),
        ]),
        sourceRevisionDocument: try .object(entries: [
            .init(name: "sources", value: .array([
                try .object(entries: [
                    .init(name: "revision", value: .string("1")),
                    .init(name: "source_id", value: .string("frame-1")),
                ]),
            ])),
        ]),
        resolvedAttachments: [],
        toolResults: toolResults,
        providerRequiredSemanticHistory: .array([]),
        disclosure: placeholder,
        resolvedParameters: GenerationConfiguration()
    )
    let contentDigest = try CanonicalDigestV1.digest(
        domain: "agent-input:v1",
        document: try egressSemanticDocument(base)
    ).hex
    let sourceDigest = try CanonicalDigestV1.digest(
        domain: "source-revisions:v1",
        document: try .object(entries: [
            .init(name: "resolved_attachments", value: .array([])),
            .init(name: "schema_version", value: .string("1")),
            .init(name: "source_revision_document", value: base.sourceRevisionDocument),
        ])
    ).hex
    let candidate = CloudGenerationTurnCandidate(
        input: base.input,
        canonicalToolSchema: base.canonicalToolSchema,
        sourceRevisionDocument: base.sourceRevisionDocument,
        resolvedAttachments: [],
        toolResults: toolResults,
        providerRequiredSemanticHistory: .array([]),
        disclosure: GenerationDisclosure(
            schemaVersion: "1",
            generationTurnID: turnID,
            contentDigest: contentDigest,
            sourceRevisionDigest: sourceDigest,
            dataClasses: classes,
            highestSensitivity: sensitivity,
            safeDisplaySummary: placeholder.safeDisplaySummary
        ),
        resolvedParameters: GenerationConfiguration()
    )
    return try CloudSemanticTurnValidator().validate(candidate)
}

private func egressSemanticDocument(
    _ candidate: CloudGenerationTurnCandidate
) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(name: "canonical_tool_schema", value: candidate.canonicalToolSchema),
        .init(name: "input_id", value: .string(candidate.input.inputID)),
        .init(name: "messages", value: .array(try candidate.input.messages.map { message in
            try .object(entries: [
                .init(name: "content", value: .array(try message.content.map { content in
                    switch content {
                    case let .text(value):
                        try .object(entries: [
                            .init(name: "text", value: .string(value)),
                            .init(name: "type", value: .string("text")),
                        ])
                    case let .attachment(modality, attachmentID, mediaType):
                        try .object(entries: [
                            .init(name: "attachment_id", value: .string(attachmentID)),
                            .init(name: "media_type", value: .string(mediaType)),
                            .init(name: "modality", value: .string(modality.rawValue)),
                            .init(name: "type", value: .string("attachment")),
                        ])
                    }
                })),
                .init(name: "role", value: .string(message.role.rawValue)),
            ])
        })),
        .init(name: "provider_required_semantic_history", value: .array([])),
        .init(name: "resolved_attachments", value: .array([])),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "tool_results", value: .array(try candidate.toolResults.map { result in
            try .object(entries: [
                .init(name: "call_id", value: .string(result.callID)),
                .init(name: "data_classes", value: .array(result.dataClasses
                    .map(\.rawValue).sorted().map(CanonicalJSONValue.string))),
                .init(name: "highest_sensitivity", value: .string(result.highestSensitivity.rawValue)),
                .init(name: "is_error", value: .bool(result.isError)),
                .init(name: "result", value: result.result),
                .init(name: "tool_name", value: .string(result.toolName)),
            ])
        })),
    ])
}

private func expectEgressFailure<T>(
    _ code: String,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("expected LLMFailure with code \(code)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private extension CloudEgressSessionContext {
    func replacing(
        credentialGeneration: UInt64,
        credentialUseLeaseID: String
    ) -> Self {
        Self(
            runID: runID,
            targetID: targetID,
            targetRevision: targetRevision,
            profileID: profileID,
            profileRevision: profileRevision,
            origin: origin,
            credentialRef: credentialRef,
            credentialGeneration: credentialGeneration,
            credentialUseLeaseID: credentialUseLeaseID,
            signedToolDisplayKeys: signedToolDisplayKeys
        )
    }
}
