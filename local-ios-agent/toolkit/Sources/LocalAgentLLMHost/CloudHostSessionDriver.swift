import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore

package struct CloudHostSessionReserver: LLMHostSessionReserving {
    private let runtime: CloudLLMRuntime
    private let configuration: AgentHostConfiguration
    private let target: LLMTargetRevision

    package init(
        runtime: CloudLLMRuntime,
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision
    ) {
        self.runtime = runtime
        self.configuration = configuration
        self.target = target
    }

    package func reserve(
        preview: RunPreparationPreviewDTO
    ) async throws -> ReservedHostSession {
        guard preview.binding.requirementsHash == configuration.requirementsHash else {
            throw LLMHostFailure(
                code: "llm.host.preparation_binding_mismatch",
                message: "cloud reservation input differs from the Rust preview"
            )
        }
        let resolvedParameters = try await runtime.resolvedGenerationConfiguration(
            hostConfiguration: configuration,
            target: target
        )
        let initialTurn = try FrozenPreparationTurn.cloudRequest(
            preview: preview,
            resolvedParameters: resolvedParameters
        )
        let capability = try preparedCapabilityAttestation(preview)
        let reserved = try await runtime.reserveSession(
            context: CloudSessionPreparationContext(
                preparationID: preview.preparationId,
                proposedRunID: preview.proposedRunId,
                initialTurn: initialTurn,
                signedToolDisplayKeys: [],
                capabilityAttestationDigest: capability.attestationDigest
            ),
            hostConfiguration: configuration,
            target: target
        )
        guard reserved.prepared.hostProcessEpoch.rawValue == preview.hostProcessEpoch else {
            try? await runtime.abortReservedSession(reserved)
            throw LLMHostFailure(
                code: "llm.host.wrong_epoch",
                message: "cloud reservation and Rust preparation use different epochs"
            )
        }

        let owner = PreparedSessionCleanupOwner()
        await owner.register(id: "cloud:\(reserved.sessionID)") {
            await runtime.cleanupReservedOrOpenedSession(reserved)
        }
        let prepared = reserved.prepared
        let registration = PreparedSessionRegistrationDTO(
            idempotencyKey: "register:\(preview.preparationId)",
            preparationId: preview.preparationId,
            proposedRunId: preview.proposedRunId,
            sessionHandle: reserved.sessionID,
            swiftSnapshotId: reserved.snapshotID,
            hostProcessEpoch: prepared.hostProcessEpoch.rawValue,
            bindingId: prepared.bindingID,
            bindingRevision: prepared.bindingRevision,
            bindingHash: prepared.bindingHash,
            registrationDigest: reserved.registrationDigest
        )
        let allocation = AllocatedHostSession(
            sessionHandle: reserved.sessionID,
            preparationID: preview.preparationId,
            proposedRunID: preview.proposedRunId,
            swiftSnapshotID: reserved.snapshotID,
            bindingHash: prepared.bindingHash,
            hostProcessEpoch: prepared.hostProcessEpoch,
            preparedSessionRegistrationDigest: reserved.registrationDigest,
            cleanupOwner: owner
        )
        return ReservedHostSession(
            registration: registration,
            allocation: allocation,
            open: {
                let opened = try await runtime.openReservedSession(reserved)
                return OpenedHostSession(
                    prepared: PreparedLLMSession(
                        handle: opened.sessionID,
                        capabilitySnapshot: reserved.capabilitySnapshot,
                        publicCapabilityAttestation: capability,
                        hostBindingID: opened.bindingID,
                        hostBindingRevision: opened.bindingRevision,
                        hostBindingHash: opened.bindingHash,
                        preparedSessionRegistrationDigest: reserved.registrationDigest,
                        hostAttestation: reserved.hostAttestation,
                        credentialUseLeaseID: opened.credentialUseLeaseID,
                        egressAttestationDigest: opened.egressAttestationDigest,
                        sanitizedSnapshotID: reserved.snapshotID,
                        hostProcessEpoch: opened.hostProcessEpoch,
                        disclosureGrantID: opened.scopeGrantID,
                        dataClasses: initialDataClasses(preview),
                        highestSensitivity: preview.binding.initialHighestSensitivity
                            ?? "routine"
                    ),
                    driver: CloudHostSessionDriver(
                        runtime: runtime,
                        sessionID: opened.sessionID,
                        resolvedParameters: resolvedParameters
                    )
                )
            }
        )
    }
}

package struct CloudHostSessionDriver: LLMHostSessionDriver {
    private let runtime: CloudLLMRuntime
    private let sessionID: String
    private let resolvedParameters: GenerationConfiguration

    package init(
        runtime: CloudLLMRuntime,
        sessionID: String,
        resolvedParameters: GenerationConfiguration
    ) {
        self.runtime = runtime
        self.sessionID = sessionID
        self.resolvedParameters = resolvedParameters
    }

    package func makeAuthorizedLaunch(
        for turn: HostGenerationTurn,
        mode: HostGenerationMode
    ) async throws -> AuthorizedHostGenerationLaunch {
        let decoded = try decodeHostGenerationTurn(turn)
        let launch = try await runtime.makeAuthorizedGenerationLaunch(
            sessionID: sessionID,
            turn: CloudGenerationTurnRequest(
                input: decoded.input,
                canonicalToolSchema: decoded.toolSchema,
                sourceRevisionDocument: decoded.sourceRevisions,
                toolResults: decoded.toolResults,
                providerRequiredSemanticHistory: decoded.semanticHistory,
                disclosure: turn.disclosure,
                resolvedParameters: resolvedParameters
            ),
            resume: mode == .resume
        )
        return AuthorizedHostGenerationLaunch {
            let operation = try await launch.run()
            return HostGenerationOperation(
                opaqueOperationID: operation.opaqueOperationID,
                events: operation.events
            )
        }
    }

    package func cancel() async throws {
        try await runtime.cancel(sessionID: sessionID)
    }

    package func close() async throws {
        try await runtime.closeSession(sessionID: sessionID)
    }
}
