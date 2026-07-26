import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore

package struct CloudHostSessionReserver: LLMHostSessionReserving {
    private let runtime: CloudLLMRuntime
    private let context: CloudSessionPreparationContext
    private let configuration: AgentHostConfiguration
    private let target: LLMTargetRevision

    package init(
        runtime: CloudLLMRuntime,
        context: CloudSessionPreparationContext,
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision
    ) {
        self.runtime = runtime
        self.context = context
        self.configuration = configuration
        self.target = target
    }

    package func reserve(
        preview: RunPreparationPreviewDTO
    ) async throws -> ReservedHostSession {
        guard context.preparationID == preview.preparationId,
              context.proposedRunID == preview.proposedRunId,
              preview.binding.requirementsHash == configuration.requirementsHash,
              try context.initialTurn.disclosure.computedDigest().hex
                == preview.binding.initialDisclosureDigest
        else {
            throw LLMHostFailure(
                code: "llm.host.preparation_binding_mismatch",
                message: "cloud reservation input differs from the Rust preview"
            )
        }
        let capability = try preparedCapabilityAttestation(preview)
        let reserved = try await runtime.reserveSession(
            context: CloudSessionPreparationContext(
                preparationID: context.preparationID,
                proposedRunID: context.proposedRunID,
                initialTurn: context.initialTurn,
                signedToolDisplayKeys: context.signedToolDisplayKeys,
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
                        sessionID: opened.sessionID
                    )
                )
            }
        )
    }
}

package struct CloudHostSessionDriver: LLMHostSessionDriver {
    private let runtime: CloudLLMRuntime
    private let sessionID: String

    package init(runtime: CloudLLMRuntime, sessionID: String) {
        self.runtime = runtime
        self.sessionID = sessionID
    }

    package func makeAuthorizedLaunch(
        for turn: HostGenerationTurn,
        mode: HostGenerationMode
    ) async throws -> AuthorizedHostGenerationLaunch {
        throw LLMHostFailure(
            code: "llm.host.generation_not_connected",
            message: "generation dispatch is installed by Phase 4 Task 8"
        )
    }

    package func cancel() async throws {
        try await runtime.cancel(sessionID: sessionID)
    }

    package func close() async throws {
        try await runtime.closeSession(sessionID: sessionID)
    }
}
