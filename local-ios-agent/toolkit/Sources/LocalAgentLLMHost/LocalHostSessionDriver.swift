import Foundation
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
        let decoded = try decodeHostGenerationTurn(turn)
        guard turn.payload.attachments.isEmpty,
              decoded.input.messages.allSatisfy({ message in
                  message.content.allSatisfy { content in
                      if case .attachment = content { return false }
                      return true
                  }
              })
        else {
            throw LLMHostFailure(
                code: "unsupported_capability",
                message: "local attachment byte resolution is unavailable"
            )
        }
        let runtime = runtime
        let sessionID = sessionID
        return AuthorizedHostGenerationLaunch {
            let sequence: LLMBackendEventSequence
            switch mode {
            case .start:
                sequence = try await runtime.startGeneration(
                    sessionID: sessionID,
                    input: decoded.input,
                    attachments: [],
                    toolSchema: decoded.toolSchema
                )
            case .resume:
                sequence = try await runtime.resumeGeneration(
                    sessionID: sessionID,
                    input: try localResumeInput(
                        decoded.input,
                        semanticHistory: decoded.semanticHistoryMessages,
                        toolResults: decoded.toolResults
                    ),
                    attachments: [],
                    toolSchema: decoded.toolSchema
                )
            }
            return HostGenerationOperation(
                opaqueOperationID: try HostSessionHandleGenerator.generate(),
                events: stream(sequence)
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

package func localResumeInput(
    _ input: AgentLLMInput,
    semanticHistory: [LLMInputMessage],
    toolResults: [NormalizedToolResult]
) throws -> AgentLLMInput {
    let messages = try toolResults.map { result in
        let document = try CanonicalJSONValue.object(entries: [
            .init(name: "call_id", value: .string(result.callID)),
            .init(name: "is_error", value: .bool(result.isError)),
            .init(name: "result", value: result.result),
            .init(name: "tool_name", value: .string(result.toolName)),
        ])
        return LLMInputMessage(
            role: .tool,
            content: [
                .text(String(
                    decoding: try CanonicalDigestV1.canonicalize(document),
                    as: UTF8.self
                )),
            ]
        )
    }
    return AgentLLMInput(
        inputID: input.inputID,
        messages: (semanticHistory.isEmpty ? input.messages : semanticHistory)
            + messages
    )
}

private func stream(
    _ sequence: LLMBackendEventSequence
) -> LLMBackendEventStream {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await event in sequence {
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
    }
}
