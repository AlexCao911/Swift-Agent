import Foundation
import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMHost

@Suite("LLM host preparation")
struct LLMHostPreparationTests {
    @Test
    func frozenPreviewProducesTheCloudInitialTurn() throws {
        let preview = try frozenCloudPreview()

        let request = try FrozenPreparationTurn.cloudRequest(
            preview: preview,
            resolvedParameters: GenerationConfiguration()
        )

        #expect(request.input.inputID == preview.binding.modelInputId)
        #expect(request.input.messages == [
            LLMInputMessage(role: .user, content: [.text("private user text")]),
        ])
        #expect(request.disclosure == preview.frozenInitialTurn.disclosure)
    }

    @Test
    func alteredFrozenPayloadFailsBeforeCloudReservation() throws {
        let preview = try frozenCloudPreview(payloadText: "different")

        #expect(throws: LLMHostFailure.self) {
            try FrozenPreparationTurn.cloudRequest(
                preview: preview,
                resolvedParameters: GenerationConfiguration()
            )
        }
    }

    @Test
    func functionSchemaCannotInjectATrustedToolDisplayKey() throws {
        let preview = try frozenCloudPreview(
            toolSchemaJSON: """
            [{"description":"contacts.search","name":"lookup"}]
            """
        )

        let request = try FrozenPreparationTurn.cloudRequest(
            preview: preview,
            resolvedParameters: GenerationConfiguration()
        )

        #expect(request.disclosure.safeDisplaySummary.triggeringToolDisplayKeys.isEmpty)
    }

    @Test
    func nonEmptyFrozenToolDisplayKeysFailBeforeCloudReservation() throws {
        let preview = try frozenCloudPreview(toolDisplayKeys: ["contacts.search"])

        #expect(throws: LLMHostFailure.self) {
            try FrozenPreparationTurn.cloudRequest(
                preview: preview,
                resolvedParameters: GenerationConfiguration()
            )
        }
    }

    @Test
    func delayedReservationRenewsUnchangedPreviewBeforeRegistration() async throws {
        let trace = PreparationTrace()
        let rust = PreparationRustFake(trace: trace)
        let harness = try PreparationHarness(
            rust: rust,
            trace: trace,
            nowMillis: 40_000
        )

        _ = try await harness.bridge.prepareAndCommit(startRequest: harness.start)

        #expect(await rust.renewCount == 1)
        #expect(await trace.values == [
            "rust.preview",
            "swift.reserve",
            "rust.renew",
            "rust.register",
            "swift.open",
            "rust.commit",
        ])
    }

    @Test
    func registrationPrecedesOpeningResources() async throws {
        let trace = PreparationTrace()
        let rust = PreparationRustFake(trace: trace)
        let harness = try PreparationHarness(rust: rust, trace: trace)

        _ = try await harness.bridge.prepareAndCommit(startRequest: harness.start)

        #expect(await trace.values == [
            "rust.preview",
            "swift.reserve",
            "rust.register",
            "swift.open",
            "rust.commit",
        ])
        #expect(await harness.runtime.bridgeActor.lifecycle(for: harness.sessionHandle) == .committed)
    }

    @Test
    func ambiguousCommitReconcilesCommittedWithoutAbortOrCleanup() async throws {
        let trace = PreparationTrace()
        let rust = PreparationRustFake(
            trace: trace,
            commitError: LLMRunPreparationRustFailure.transport,
            reconciliation: try .init(
                status: .committed,
                handle: .init(
                    runID: "run-1",
                    sessionHandle: "session-1",
                    firstCommandID: "command-1"
                ),
                cleanupIdentity: nil
            )
        )
        let harness = try PreparationHarness(rust: rust, trace: trace)

        let handle = try await harness.bridge.prepareAndCommit(startRequest: harness.start)

        #expect(handle.runID == "run-1")
        #expect(await rust.abortCount == 0)
        #expect(await harness.closeCounter.value == 0)
        #expect(await harness.runtime.bridgeActor.lifecycle(for: harness.sessionHandle) == .committed)
    }

    @Test
    func unavailableReconciliationQuarantinesUnknownCommitWithoutClosing() async throws {
        let trace = PreparationTrace()
        let rust = PreparationRustFake(
            trace: trace,
            commitError: LLMRunPreparationRustFailure.transport,
            reconciliationError: LLMRunPreparationRustFailure.transport
        )
        let harness = try PreparationHarness(rust: rust, trace: trace)

        await #expect(throws: LLMHostFailure.self) {
            try await harness.bridge.prepareAndCommit(startRequest: harness.start)
        }

        #expect(await rust.abortCount == 0)
        #expect(await harness.closeCounter.value == 0)
        #expect(
            await harness.runtime.bridgeActor.lifecycle(for: harness.sessionHandle)
                == .commitOutcomeUnknown
        )
    }

    @Test
    func reconciledPendingIsTheOnlyAmbiguousPathThatBeginsAbort() async throws {
        let trace = PreparationTrace()
        let rust = PreparationRustFake(
            trace: trace,
            commitError: LLMRunPreparationRustFailure.transport,
            reconciliation: try .init(
                status: .pending,
                handle: nil,
                cleanupIdentity: nil
            )
        )
        let harness = try PreparationHarness(rust: rust, trace: trace)

        await #expect(throws: LLMRunPreparationRustFailure.self) {
            try await harness.bridge.prepareAndCommit(startRequest: harness.start)
        }

        #expect(await rust.abortCount == 1)
        #expect(await harness.closeCounter.value == 0)
    }
}

private struct PreparationHarness {
    static let epoch = HostProcessEpoch(
        rawValue: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    )!

    let runtime: LLMHostRuntime
    let bridge: LLMRunPreparationBridge
    let start: PreviewRunPreparationRequestDTO
    let closeCounter: PreparationCounter
    let sessionHandle = "session-1"

    init(
        rust: PreparationRustFake,
        trace: PreparationTrace,
        nowMillis: UInt64 = 1_000
    ) throws {
        let sink = PreparationRustSink()
        let runtime = LLMHostRuntime(hostProcessEpoch: Self.epoch, rustSink: sink)
        let closeCounter = PreparationCounter()
        let reserver = PreparationReserverFake(
            trace: trace,
            closeCounter: closeCounter
        )
        self.runtime = runtime
        self.closeCounter = closeCounter
        bridge = LLMRunPreparationBridge(
            rust: rust,
            registry: runtime.bridgeActor,
            reserver: reserver,
            nowMillis: { nowMillis }
        )
        start = PreviewRunPreparationRequestDTO(
            idempotencyKey: "preview-1",
            preparationId: "preparation-1",
            proposedRunId: "run-1",
            startRequest: AuthoritativePreparationStartRequestDTO(
                agentProfileId: "profile-1",
                profileRevisionId: 1,
                userIntent: "hello",
                conversationRunFrameRef: ConversationRunFrameRefDTO(
                    frameId: "frame-1",
                    sessionId: "conversation-1",
                    branchHeadId: "turn-1",
                    userTurnId: "turn-1"
                )
            ),
            nowMillis: 1_000
        )
    }
}

private actor PreparationTrace {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor PreparationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private enum LLMRunPreparationRustFailure: Error, Equatable {
    case authoritative
    case transport
}

private actor PreparationRustFake: LLMRunPreparationRustClient {
    let trace: PreparationTrace
    let commitError: LLMRunPreparationRustFailure?
    let reconciliation: PreparationReconciliationDTO?
    let reconciliationError: LLMRunPreparationRustFailure?
    private(set) var abortCount = 0
    private(set) var renewCount = 0
    private var issuedPreview: RunPreparationPreviewDTO?

    init(
        trace: PreparationTrace,
        commitError: LLMRunPreparationRustFailure? = nil,
        reconciliation: PreparationReconciliationDTO? = nil,
        reconciliationError: LLMRunPreparationRustFailure? = nil
    ) {
        self.trace = trace
        self.commitError = commitError
        self.reconciliation = reconciliation
        self.reconciliationError = reconciliationError
    }

    func previewRun(
        _ request: PreviewRunPreparationRequestDTO
    ) async throws -> RunPreparationPreviewDTO {
        await trace.append("rust.preview")
        let preview = RunPreparationPreviewDTO(
            preparationId: request.preparationId,
            proposedRunId: request.proposedRunId,
            token: "token-1",
            tokenDigest: String(repeating: "1", count: 64),
            tokenGeneration: 1,
            binding: PreparationBindingDTO(
                agentProfileId: "profile-1",
                agentProfileRevision: 1,
                conversationFrameDigest: String(repeating: "2", count: 64),
                executionPlanDigest: String(repeating: "3", count: 64),
                requirementsHash: String(repeating: "4", count: 64),
                toolSchemaDigest: String(repeating: "5", count: 64),
                modelInputId: "input-1",
                modelInputDigest: String(repeating: "6", count: 64),
                sourceRevisionsDigest: String(repeating: "7", count: 64),
                initialDisclosureDigest: String(repeating: "8", count: 64)
            ),
            bindingDigest: String(repeating: "9", count: 64),
            frozenInitialTurn: frozenInitialTurnFixture(),
            hostProcessEpoch: PreparationHarness.epoch.rawValue,
            leaseGeneration: 1,
            expirationMillis: 61_000,
            totalDeadlineMillis: 121_000
        )
        issuedPreview = preview
        return preview
    }

    func registerPreparedSession(
        _ request: RegisterPreparedSessionRequestDTO
    ) async throws {
        await trace.append("rust.register")
    }

    func renewPreparation(
        _ request: RenewRunPreparationRequestDTO
    ) async throws -> RunPreparationPreviewDTO {
        renewCount += 1
        await trace.append("rust.renew")
        let preview = try #require(issuedPreview)
        let renewed = RunPreparationPreviewDTO(
            preparationId: preview.preparationId,
            proposedRunId: preview.proposedRunId,
            token: "token-2",
            tokenDigest: String(repeating: "0", count: 64),
            tokenGeneration: preview.tokenGeneration + 1,
            binding: preview.binding,
            bindingDigest: preview.bindingDigest,
            frozenInitialTurn: preview.frozenInitialTurn,
            hostProcessEpoch: preview.hostProcessEpoch,
            leaseGeneration: preview.leaseGeneration,
            expirationMillis: 100_000,
            totalDeadlineMillis: preview.totalDeadlineMillis
        )
        issuedPreview = renewed
        return renewed
    }

    func commitPreparedStart(
        _ request: CommitPreparedStartRequestDTO
    ) async throws -> HostRunHandleDTO {
        await trace.append("rust.commit")
        if let commitError { throw commitError }
        return HostRunHandleDTO(
            runID: "run-1",
            sessionHandle: "session-1",
            firstCommandID: "command-1"
        )
    }

    func reconcilePreparation(
        _ request: ReconcilePreparationRequestDTO
    ) async throws -> PreparationReconciliationDTO {
        if let reconciliationError { throw reconciliationError }
        return try #require(reconciliation)
    }

    func beginAbortPreparation(
        _ request: BeginAbortPreparationRequestDTO
    ) async throws {
        abortCount += 1
    }

    nonisolated func isAuthoritativeRejection(_ error: Error) -> Bool {
        error as? LLMRunPreparationRustFailure == .authoritative
    }
}

private func frozenInitialTurnFixture() -> FrozenInitialTurnDTO {
    let contentDigest = String(repeating: "6", count: 64)
    let sourceDigest = String(repeating: "7", count: 64)
    return FrozenInitialTurnDTO(
        payload: HostCommandPayload(
            schemaVersion: "1",
            modelInputID: "input-1",
            messages: [
                HostSemanticMessage(
                    role: "user",
                    content: [HostSemanticContent(kind: .text, text: "hello")]
                ),
            ],
            toolSchemaJSON: "[]",
            toolSchemaDigest: String(repeating: "5", count: 64),
            sourceRevisions: [],
            sourceRevisionsDigest: sourceDigest,
            attachments: [],
            semanticHistory: [],
            toolResults: []
        ),
        disclosure: GenerationDisclosure(
            schemaVersion: "1",
            generationTurnID: "turn-1",
            contentDigest: contentDigest,
            sourceRevisionDigest: sourceDigest,
            dataClasses: [.text],
            highestSensitivity: .private,
            safeDisplaySummary: SafeDisplaySummary(
                sourceKinds: [.conversation],
                addedItemCounts: [.init(dataClass: .text, count: 1)],
                approximateAddedSize: .lessThanOneKiB,
                triggeringToolDisplayKeys: []
            )
        )
    )
}

private func frozenCloudPreview(
    payloadText: String = "private user text",
    toolSchemaJSON: String = "[]",
    toolDisplayKeys: Set<String> = []
) throws -> RunPreparationPreviewDTO {
    let inputID = "input-1"
    let canonicalToolSchema = try JSONDecoder().decode(
        CanonicalJSONValue.self,
        from: Data(toolSchemaJSON.utf8)
    )
    let toolSchemaDigest = try CanonicalDigestV1.digest(
        domain: "tool-schema:v1",
        document: canonicalToolSchema
    ).hex
    let semanticHistory = try CanonicalJSONValue.object(entries: [
        .init(
            name: "content",
            value: .array([
                try .object(entries: [
                    .init(name: "kind", value: .string("text")),
                    .init(name: "text", value: .string("private user text")),
                ]),
            ])
        ),
        .init(name: "role", value: .string("user")),
    ])
    let inputMessage = try CanonicalJSONValue.object(entries: [
        .init(
            name: "content",
            value: .array([
                try .object(entries: [
                    .init(name: "text", value: .string("private user text")),
                    .init(name: "type", value: .string("text")),
                ]),
            ])
        ),
        .init(name: "role", value: .string("user")),
    ])
    let contentDigest = try CanonicalDigestV1.digest(
        domain: "agent-input:v1",
        document: try .object(entries: [
            .init(name: "canonical_tool_schema", value: canonicalToolSchema),
            .init(name: "input_id", value: .string(inputID)),
            .init(name: "messages", value: .array([inputMessage])),
            .init(
                name: "provider_required_semantic_history",
                value: .array([semanticHistory])
            ),
            .init(name: "resolved_attachments", value: .array([])),
            .init(name: "schema_version", value: .string("1")),
            .init(name: "tool_results", value: .array([])),
        ])
    ).hex
    let sourceRevisionDocument = CanonicalJSONValue.array([])
    let sourceDigest = try CanonicalDigestV1.digest(
        domain: "source-revisions:v1",
        document: try .object(entries: [
            .init(name: "resolved_attachments", value: .array([])),
            .init(name: "schema_version", value: .string("1")),
            .init(name: "source_revision_document", value: sourceRevisionDocument),
        ])
    ).hex
    let disclosure = GenerationDisclosure(
        schemaVersion: "1",
        generationTurnID: "turn-1",
        contentDigest: contentDigest,
        sourceRevisionDigest: sourceDigest,
        dataClasses: [.text],
        highestSensitivity: .private,
        safeDisplaySummary: SafeDisplaySummary(
            sourceKinds: [.conversation],
            addedItemCounts: [.init(dataClass: .text, count: 1)],
            approximateAddedSize: .lessThanOneKiB,
            triggeringToolDisplayKeys: toolDisplayKeys
        )
    )
    let payload = HostCommandPayload(
        schemaVersion: "1",
        modelInputID: inputID,
        messages: [
            HostSemanticMessage(
                role: "user",
                content: [HostSemanticContent(kind: .text, text: payloadText)]
            ),
        ],
        toolSchemaJSON: toolSchemaJSON,
        toolSchemaDigest: toolSchemaDigest,
        sourceRevisions: [],
        sourceRevisionsDigest: sourceDigest,
        attachments: [],
        semanticHistory: [
            HostSemanticMessage(
                role: "user",
                content: [HostSemanticContent(kind: .text, text: "private user text")]
            ),
        ],
        toolResults: []
    )
    let frozen = FrozenInitialTurnDTO(payload: payload, disclosure: disclosure)
    return RunPreparationPreviewDTO(
        preparationId: "preparation-1",
        proposedRunId: "run-1",
        token: "token-1",
        tokenDigest: String(repeating: "1", count: 64),
        tokenGeneration: 1,
        binding: PreparationBindingDTO(
            agentProfileId: "profile-1",
            agentProfileRevision: 1,
            conversationFrameDigest: String(repeating: "2", count: 64),
            executionPlanDigest: String(repeating: "3", count: 64),
            requirementsHash: String(repeating: "4", count: 64),
            toolSchemaDigest: toolSchemaDigest,
            modelInputId: inputID,
            modelInputDigest: contentDigest,
            sourceRevisionsDigest: sourceDigest,
            initialDisclosureDigest: try disclosure.computedDigest().hex
        ),
        bindingDigest: String(repeating: "9", count: 64),
        frozenInitialTurn: frozen,
        hostProcessEpoch: PreparationHarness.epoch.rawValue,
        leaseGeneration: 1,
        expirationMillis: 61_000,
        totalDeadlineMillis: 121_000
    )
}

private struct PreparationReserverFake: LLMHostSessionReserving {
    let trace: PreparationTrace
    let closeCounter: PreparationCounter

    func reserve(preview: RunPreparationPreviewDTO) async throws -> ReservedHostSession {
        await trace.append("swift.reserve")
        let owner = PreparedSessionCleanupOwner()
        await owner.register(id: "fake-resource") {
            await closeCounter.increment()
        }
        let hashes = PreparationHashes()
        let document = HostAttestationV1Document(
            preparationID: preview.preparationId,
            proposedRunID: preview.proposedRunId,
            sessionID: "session-1",
            swiftSnapshotID: "snapshot-1",
            preparedSessionRegistrationDigest: hashes.registration,
            bindingID: "binding-1",
            bindingRevision: "1",
            bindingHash: hashes.binding,
            requirementsHash: preview.binding.requirementsHash,
            disclosureDigest: preview.binding.initialDisclosureDigest,
            capabilitySnapshotDigest: hashes.capability,
            resolvedParametersDigest: hashes.parameters,
            hostProcessEpoch: preview.hostProcessEpoch,
            expiresAt: "2030-01-01T00:00:00.000Z",
            opaqueEgressSubjectDigest: hashes.egressSubject
        )
        let prepared = PreparedLLMSession(
            handle: "session-1",
            capabilitySnapshot: CapabilitySnapshot(capabilities: [:]),
            publicCapabilityAttestation: PreparedCapabilityAttestationDTO(
                supportedCapabilities: [],
                inputModalities: ["text"],
                contextLength: "4096",
                streaming: true,
                toolCalling: false,
                expirationMillis: preview.expirationMillis,
                attestationDigest: hashes.capability
            ),
            hostBindingID: "binding-1",
            hostBindingRevision: 1,
            hostBindingHash: hashes.binding,
            preparedSessionRegistrationDigest: hashes.registration,
            hostAttestation: document,
            credentialUseLeaseID: nil,
            egressAttestationDigest: try document.computedDigest().hex,
            sanitizedSnapshotID: "snapshot-1",
            hostProcessEpoch: PreparationHarness.epoch
        )
        let registration = PreparedSessionRegistrationDTO(
            idempotencyKey: "register-1",
            preparationId: preview.preparationId,
            proposedRunId: preview.proposedRunId,
            sessionHandle: "session-1",
            swiftSnapshotId: "snapshot-1",
            hostProcessEpoch: preview.hostProcessEpoch,
            bindingId: "binding-1",
            bindingRevision: 1,
            bindingHash: hashes.binding,
            registrationDigest: hashes.registration
        )
        let allocation = AllocatedHostSession(
            sessionHandle: "session-1",
            preparationID: preview.preparationId,
            proposedRunID: preview.proposedRunId,
            swiftSnapshotID: "snapshot-1",
            bindingHash: hashes.binding,
            hostProcessEpoch: PreparationHarness.epoch,
            preparedSessionRegistrationDigest: hashes.registration,
            cleanupOwner: owner
        )
        return ReservedHostSession(
            registration: registration,
            allocation: allocation,
            open: {
                await trace.append("swift.open")
                return OpenedHostSession(
                    prepared: prepared,
                    driver: PreparationDriver()
                )
            }
        )
    }
}

private struct PreparationHashes {
    let binding = String(repeating: "a", count: 64)
    let registration = String(repeating: "b", count: 64)
    let capability = String(repeating: "c", count: 64)
    let parameters = String(repeating: "d", count: 64)
    let egressSubject = String(repeating: "e", count: 64)
}

private struct PreparationDriver: LLMHostSessionDriver {
    func makeAuthorizedLaunch(
        for turn: HostGenerationTurn,
        mode: HostGenerationMode
    ) async throws -> AuthorizedHostGenerationLaunch {
        throw LLMHostFailure(
            code: "llm.host.not_started",
            message: "not used by preparation tests"
        )
    }
    func cancel() async throws {}
    func close() async throws {}
}

private actor PreparationRustSink: LLMHostRustSink {
    func submit(
        _ envelope: LLMEventEnvelope
    ) async throws -> LLMEventSubmissionResult { .accepted }

    func submitCommandAcknowledgement(
        _ acknowledgement: HostCommandAcknowledgement
    ) async -> Bool { true }

    func acknowledgePreparedSessionCleanup(
        _ acknowledgement: PreparedSessionCleanupAcknowledgementDTO
    ) async -> Bool { true }

    func confirmPreparedSessionClosed(
        _ receipt: PreparedSessionClosedReceiptDTO
    ) async -> Bool { true }
}
