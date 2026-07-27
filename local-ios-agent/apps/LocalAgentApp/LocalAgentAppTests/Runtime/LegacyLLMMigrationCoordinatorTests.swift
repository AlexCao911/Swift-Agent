import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentApp

@Suite("Legacy LLM migration")
struct LegacyLLMMigrationCoordinatorTests {
    @Test("startup exposes only Rust-owned minimal migration actions")
    func pendingActionsComeFromRustInventory() async throws {
        let expected = try JSONDecoder().decode(
            [LegacyMigrationActionDTO].self,
            from: """
            [{
              "migration_subject":"legacy:1",
              "source_digest":"source-digest",
              "display_name":"Legacy",
              "requirements":{
                "slot_id":"slot.model.primary",
                "capabilities":[],
                "input_modalities":["text"],
                "context_budget":"4096",
                "streaming_required":true,
                "tool_calling_mode":"allowed"
              },
              "redacted_model_hint":"gpt-4.1",
              "state":"pending"
            }]
            """.data(using: .utf8)!
        )
        let rust = RecordingLegacyMigrationClient(actions: expected)
        let coordinator = LegacyLLMMigrationCoordinator(
            rust: rust,
            targets: StaticAgentLLMTargetCatalog(options: []),
            bindingSaga: AgentHostBindingSaga(store: .inMemory())
        )

        #expect(try await coordinator.pendingActions() == expected)
    }

    @Test("legacy model hint never selects a target automatically")
    func migrationRequiresExplicitExactTarget() async throws {
        let rust = RecordingLegacyMigrationClient()
        let target = migrationTarget()
        let coordinator = LegacyLLMMigrationCoordinator(
            rust: rust,
            targets: StaticAgentLLMTargetCatalog(options: [
                AgentLLMTargetOption(
                    target: target,
                    parameterSchema: LLMParameterSchema(definitions: [])
                ),
            ]),
            bindingSaga: AgentHostBindingSaga(store: .inMemory())
        )

        await #expect(throws: LegacyLLMMigrationError.targetRequired) {
            try await coordinator.migrate(
                profileID: "legacy",
                revision: 1,
                selectedTarget: nil
            )
        }
        let requests = await rust.beginRequests
        #expect(requests.isEmpty)
    }

    @Test("completion occurs only after the exact Swift binding is active")
    func migrationCompletesExactBinding() async throws {
        let rust = RecordingLegacyMigrationClient()
        let target = migrationTarget()
        let store = LLMStore.inMemory()
        try await store.publishTarget(target)
        let saga = AgentHostBindingSaga(store: store)
        let coordinator = LegacyLLMMigrationCoordinator(
            rust: rust,
            targets: StaticAgentLLMTargetCatalog(options: [
                AgentLLMTargetOption(
                    target: target,
                    parameterSchema: LLMParameterSchema(definitions: [])
                ),
            ]),
            bindingSaga: saga
        )

        let record = try await coordinator.migrate(
            profileID: "legacy",
            revision: 1,
            selectedTarget: target.reference
        )

        guard case .migrated = record.state else {
            Issue.record("migration did not reach migrated")
            return
        }
        let completion = await rust.completion
        let confirmation = try #require(completion)
        let activeBindings = try await store.activeHostBindings()
        let active = try #require(activeBindings.first)
        #expect(active.targetReference == target.reference)
        #expect(confirmation.binding.bindingHash == active.binding.bindingHash)
    }

    @Test("startup reconciliation completes only an exact active Swift binding")
    func reconciliationCompletesExactActiveBinding() async throws {
        let successor = LegacyProfileSuccessorSubjectDTO(
            profileId: "legacy",
            profileRevision: 2,
            llmSlotId: "slot.model.primary",
            requirementsHash: "requirements-hash",
            hostBindingOperationId: "migration-operation"
        )
        let rust = RecordingLegacyMigrationClient(records: [
            LegacyProfileMigrationRecordDTO(
                sourceProfileId: "legacy",
                sourceRevision: 1,
                sourceDigest: "source-digest",
                state: .pending(LegacyProfileMigrationAttemptDTO(
                    attemptId: "attempt",
                    successor: successor,
                    hostBindingOperationId: successor.hostBindingOperationId
                ))
            ),
        ])
        let target = migrationTarget()
        let store = LLMStore.inMemory()
        try await store.publishTarget(target)
        let saga = AgentHostBindingSaga(store: store)
        let configuration = AgentHostConfiguration(
            bindingID: "binding.legacy.2",
            revision: 1,
            agentProfileID: successor.profileId,
            agentProfileRevision: successor.profileRevision,
            llmSlotID: successor.llmSlotId,
            requirementsHash: successor.requirementsHash,
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            parameterOverrides: GenerationConfiguration()
        )
        let receipt = try await saga.stageHostBinding(HostBindingStageRequest(
            operationToken: "migration-token",
            tokenDigest: "migration-token-digest",
            llmSlotID: successor.llmSlotId,
            requirementsHash: successor.requirementsHash,
            configuration: configuration
        ))
        try await saga.activateHostBinding(
            operationToken: "migration-token",
            binding: receipt.binding
        )
        let coordinator = LegacyLLMMigrationCoordinator(
            rust: rust,
            targets: StaticAgentLLMTargetCatalog(options: []),
            bindingSaga: saga
        )

        let outcome = try await coordinator.reconcilePendingActivations()

        #expect(outcome.completedSourceDigests == ["source-digest"])
        #expect(outcome.selectionRequiredSourceDigests.isEmpty)
        #expect(outcome.bindingRequiredSourceDigests.isEmpty)
        #expect(await rust.completion?.binding.bindingHash == receipt.binding.bindingHash)
    }
}

private actor RecordingLegacyMigrationClient: LegacyProfileMigrationClient {
    private(set) var beginRequests: [BeginLegacyProfileMigrationDTO] = []
    private(set) var completion: HostBindingActivationConfirmationDTO?
    private let migrationRecords: [LegacyProfileMigrationRecordDTO]
    private let migrationActions: [LegacyMigrationActionDTO]

    init(
        records: [LegacyProfileMigrationRecordDTO] = [],
        actions: [LegacyMigrationActionDTO] = []
    ) {
        migrationRecords = records
        migrationActions = actions
    }

    func begin(
        _ request: BeginLegacyProfileMigrationDTO
    ) async throws -> LegacyMigrationActionDTO {
        beginRequests.append(request)
        let data = """
        {
          "migration_subject":"legacy:1",
          "source_digest":"source-digest",
          "display_name":"Legacy",
          "requirements":{
            "slot_id":"slot.model.primary",
            "capabilities":[],
            "input_modalities":["text"],
            "context_budget":"4096",
            "streaming_required":true,
            "tool_calling_mode":"allowed"
          },
          "redacted_model_hint":"gpt-4.1",
          "state":"pending",
          "successor":{
            "profile_id":"legacy",
            "profile_revision":2,
            "llm_slot_id":"slot.model.primary",
            "requirements_hash":"requirements-hash",
            "host_binding_operation_id":"migration-operation"
          }
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(LegacyMigrationActionDTO.self, from: data)
    }

    func records() async throws -> [LegacyProfileMigrationRecordDTO] {
        migrationRecords
    }

    func actions() async throws -> [LegacyMigrationActionDTO] {
        migrationActions
    }

    func prepareProfilePublish(
        _ request: ProfilePublishPreparationDTO
    ) async throws -> HostBindingOperationDTO {
        HostBindingOperationDTO(
            kind: "profile_publish",
            idempotencyKey: request.idempotencyKey,
            token: "migration-token",
            tokenDigest: "migration-token-digest",
            subjectId: request.agentProfileId,
            agentProfileId: request.agentProfileId,
            agentProfileRevision: request.agentProfileRevision,
            llmSlotId: request.llmSlotId,
            requirementsHash: request.requirementsHash,
            state: "pending"
        )
    }

    func commitProfilePublish(
        _ request: HostBindingCommitDTO
    ) async throws -> HostBindingCrossLinkDTO {
        HostBindingCrossLinkDTO(
            operationToken: request.token,
            tokenDigest: request.receipt.tokenDigest,
            kind: "profile_publish",
            llmSlotId: request.receipt.llmSlotId,
            requirementsHash: request.receipt.requirementsHash,
            binding: request.binding,
            stagingReceiptDigest: request.receipt.receiptDigest,
            state: "host_unbound"
        )
    }

    func complete(
        _ confirmation: HostBindingActivationConfirmationDTO
    ) async throws -> LegacyProfileMigrationRecordDTO {
        completion = confirmation
        let successor = LegacyProfileSuccessorSubjectDTO(
            profileId: confirmation.agentProfileId,
            profileRevision: confirmation.agentProfileRevision,
            llmSlotId: confirmation.llmSlotId,
            requirementsHash: confirmation.requirementsHash,
            hostBindingOperationId: "migration-operation"
        )
        return LegacyProfileMigrationRecordDTO(
            sourceProfileId: "legacy",
            sourceRevision: 1,
            sourceDigest: "source-digest",
            state: .migrated(successor)
        )
    }
}

private func migrationTarget() -> LLMTargetRevision {
    LLMTargetRevision(
        targetID: LLMTargetID(rawValue: "target.explicit"),
        revision: 3,
        kind: .local(installationID: "installation.explicit"),
        modelID: "selected-model",
        defaultParameters: GenerationConfiguration()
    )
}
