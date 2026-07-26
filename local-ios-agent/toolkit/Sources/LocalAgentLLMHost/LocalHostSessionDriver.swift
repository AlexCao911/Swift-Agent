import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMCore
import LocalAgentLLMLocal

package struct LocalHostSessionReserver: LLMHostSessionReserving {
    private let runtime: LocalModelRuntime
    private let configuration: AgentHostConfiguration
    private let target: LLMTargetRevision

    package init(
        runtime: LocalModelRuntime,
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
                code: "llm.host.requirements_mismatch",
                message: "Rust preview and exact host binding requirements differ"
            )
        }
        let capability = try preparedCapabilityAttestation(preview)
        let reserved = try await runtime.reserveSession(
            context: LocalSessionPreparationContext(
                preparationID: preview.preparationId,
                proposedRunID: preview.proposedRunId,
                initialDisclosureDigest: preview.binding.initialDisclosureDigest,
                capabilityAttestationDigest: capability.attestationDigest,
                attestationExpiresAt: hostAttestationExpiration(
                    preview.totalDeadlineMillis
                )
            ),
            hostConfiguration: configuration,
            target: target
        )
        guard reserved.hostProcessEpoch.rawValue == preview.hostProcessEpoch else {
            await runtime.abortReservedSession(reserved)
            throw LLMHostFailure(
                code: "llm.host.wrong_epoch",
                message: "local reservation and Rust preparation use different epochs"
            )
        }

        let owner = PreparedSessionCleanupOwner()
        await owner.register(id: "local:\(reserved.sessionID)") {
            await runtime.cleanupReservedOrOpenedSession(reserved)
        }
        let registration = PreparedSessionRegistrationDTO(
            idempotencyKey: "register:\(preview.preparationId)",
            preparationId: preview.preparationId,
            proposedRunId: preview.proposedRunId,
            sessionHandle: reserved.sessionID,
            swiftSnapshotId: reserved.snapshotID,
            hostProcessEpoch: reserved.hostProcessEpoch.rawValue,
            bindingId: reserved.binding.bindingID,
            bindingRevision: reserved.binding.bindingRevision,
            bindingHash: reserved.binding.bindingHash,
            registrationDigest: reserved.registrationDigest
        )
        let allocation = AllocatedHostSession(
            sessionHandle: reserved.sessionID,
            preparationID: preview.preparationId,
            proposedRunID: preview.proposedRunId,
            swiftSnapshotID: reserved.snapshotID,
            bindingHash: reserved.binding.bindingHash,
            hostProcessEpoch: reserved.hostProcessEpoch,
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
                        hostBindingID: reserved.binding.bindingID,
                        hostBindingRevision: reserved.binding.bindingRevision,
                        hostBindingHash: reserved.binding.bindingHash,
                        preparedSessionRegistrationDigest: reserved.registrationDigest,
                        hostAttestation: reserved.hostAttestation,
                        credentialUseLeaseID: nil,
                        egressAttestationDigest: try reserved.hostAttestation
                            .computedDigest().hex,
                        sanitizedSnapshotID: reserved.snapshotID,
                        hostProcessEpoch: reserved.hostProcessEpoch,
                        disclosureGrantID: "not_applicable",
                        dataClasses: initialDataClasses(preview),
                        highestSensitivity: preview.binding.initialHighestSensitivity
                            ?? "routine"
                    ),
                    driver: LocalHostSessionDriver(
                        runtime: runtime,
                        sessionID: opened.sessionID
                    )
                )
            }
        )
    }
}

package struct LocalHostSessionDriver: LLMHostSessionDriver {
    private let runtime: LocalModelRuntime
    private let sessionID: String

    package init(runtime: LocalModelRuntime, sessionID: String) {
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
