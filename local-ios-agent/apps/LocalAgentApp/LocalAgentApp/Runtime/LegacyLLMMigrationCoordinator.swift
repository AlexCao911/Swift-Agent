import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMCore

enum LegacyLLMMigrationError: Error, Equatable, Sendable {
    case targetRequired
    case targetMissing
    case invalidRustAction
    case completionNotMigrated
}

struct LegacyLLMMigrationReconciliation: Equatable, Sendable {
    let completedSourceDigests: [String]
    let selectionRequiredSourceDigests: [String]
    let bindingRequiredSourceDigests: [String]
}

struct LegacyLLMMigrationItem: Equatable, Identifiable, Sendable {
    let profileID: String
    let revision: UInt64
    let sourceDigest: String
    let displayName: String
    let redactedModelHint: String?

    var id: String { sourceDigest }
}

protocol LegacyLLMMigrationPresenting: Sendable {
    func pendingItems() async throws -> [LegacyLLMMigrationItem]
    func migrate(
        profileID: String,
        revision: UInt64,
        selectedTarget: LLMTargetReference?
    ) async throws -> LegacyProfileMigrationRecordDTO
}

actor LegacyLLMMigrationCoordinator: LegacyLLMMigrationPresenting {
    private let rust: any LegacyProfileMigrationClient
    private let targets: any AgentLLMTargetCatalog
    private let bindingSaga: AgentHostBindingSaga

    init(
        rust: any LegacyProfileMigrationClient,
        targets: any AgentLLMTargetCatalog,
        bindingSaga: AgentHostBindingSaga
    ) {
        self.rust = rust
        self.targets = targets
        self.bindingSaga = bindingSaga
    }

    func pendingActions() async throws -> [LegacyMigrationActionDTO] {
        try await rust.actions().filter { $0.state == "pending" }
    }

    func pendingItems() async throws -> [LegacyLLMMigrationItem] {
        let pending = try await pendingActions()
        let actions = Dictionary(
            pending.map {
                ($0.sourceDigest, $0)
            },
            uniquingKeysWith: { current, _ in current }
        )
        let records = try await rust.records()
        let items: [LegacyLLMMigrationItem] = records.compactMap { record in
            guard case .pending = record.state,
                  let action = actions[record.sourceDigest]
            else { return nil }
            return LegacyLLMMigrationItem(
                profileID: record.sourceProfileId,
                revision: record.sourceRevision,
                sourceDigest: record.sourceDigest,
                displayName: action.displayName,
                redactedModelHint: action.redactedModelHint
            )
        }
        return items.sorted {
            $0.displayName == $1.displayName
                ? $0.sourceDigest < $1.sourceDigest
                : $0.displayName < $1.displayName
        }
    }

    func migrate(
        profileID: String,
        revision: UInt64,
        selectedTarget: LLMTargetReference?
    ) async throws -> LegacyProfileMigrationRecordDTO {
        guard let selectedTarget else {
            throw LegacyLLMMigrationError.targetRequired
        }
        guard let option = try await targets.targetOptions().first(where: {
            $0.target.reference == selectedTarget
        }) else {
            throw LegacyLLMMigrationError.targetMissing
        }
        let attemptID = [
            "legacy-migration",
            profileID,
            String(revision),
            selectedTarget.targetID.rawValue,
            String(selectedTarget.revision),
        ].joined(separator: ".")
        let action = try await rust.begin(BeginLegacyProfileMigrationDTO(
            attemptId: attemptID,
            profileId: profileID,
            profileRevision: revision
        ))
        guard action.state == "pending", let successor = action.successor else {
            throw LegacyLLMMigrationError.invalidRustAction
        }
        let operation = try await rust.prepareProfilePublish(
            ProfilePublishPreparationDTO(
                idempotencyKey: successor.hostBindingOperationId,
                agentProfileId: successor.profileId,
                agentProfileRevision: successor.profileRevision,
                llmSlotId: successor.llmSlotId,
                requirementsHash: successor.requirementsHash
            )
        )
        let resolved = try LLMParameterSystem.resolve(
            targetDefaults: option.target.defaultParameters,
            hostOverrides: GenerationConfiguration(),
            schema: option.parameterSchema
        )
        let configuration = AgentHostConfiguration(
            bindingID: "binding.\(successor.profileId).\(successor.profileRevision)",
            revision: 1,
            agentProfileID: successor.profileId,
            agentProfileRevision: successor.profileRevision,
            llmSlotID: successor.llmSlotId,
            requirementsHash: successor.requirementsHash,
            llmTargetID: option.target.targetID,
            llmTargetRevision: option.target.revision,
            fallbackGroupID:
                "providers.\(successor.profileId).\(successor.profileRevision)",
            fallbackPriority: 0,
            parameterOverrides: resolved
        )
        let receipt = try await bindingSaga.stageHostBinding(HostBindingStageRequest(
            operationToken: operation.token,
            tokenDigest: operation.tokenDigest,
            llmSlotID: successor.llmSlotId,
            requirementsHash: successor.requirementsHash,
            configuration: configuration
        ))
        let binding = HostBindingTupleDTO(
            bindingId: receipt.binding.bindingID,
            bindingRevision: receipt.binding.bindingRevision,
            bindingHash: receipt.binding.bindingHash
        )
        let crossLink = try await rust.commitProfilePublish(HostBindingCommitDTO(
            token: operation.token,
            binding: binding,
            receipt: HostBindingStagingReceiptDTO(
                tokenDigest: receipt.tokenDigest,
                llmSlotId: receipt.llmSlotID,
                requirementsHash: receipt.requirementsHash,
                binding: binding,
                receiptDigest: receipt.receiptDigest
            )
        ))
        try await bindingSaga.activateHostBinding(
            operationToken: operation.token,
            binding: receipt.binding
        )
        let completed = try await rust.complete(
            HostBindingActivationConfirmationDTO(
                agentProfileId: successor.profileId,
                agentProfileRevision: successor.profileRevision,
                llmSlotId: successor.llmSlotId,
                requirementsHash: successor.requirementsHash,
                binding: binding,
                stagingReceiptDigest: crossLink.stagingReceiptDigest
            )
        )
        guard case .migrated = completed.state else {
            throw LegacyLLMMigrationError.completionNotMigrated
        }
        return completed
    }

    func reconcilePendingActivations() async throws -> LegacyLLMMigrationReconciliation {
        var completed: [String] = []
        var selectionRequired: [String] = []
        var bindingRequired: [String] = []
        for record in try await rust.records() {
            guard case let .pending(attempt) = record.state else { continue }
            guard let attempt else {
                selectionRequired.append(record.sourceDigest)
                continue
            }
            let successor = attempt.successor
            guard let receipt = await bindingSaga.activeReceipt(
                agentProfileID: successor.profileId,
                agentProfileRevision: successor.profileRevision,
                llmSlotID: successor.llmSlotId,
                requirementsHash: successor.requirementsHash
            ) else {
                bindingRequired.append(record.sourceDigest)
                continue
            }
            let binding = HostBindingTupleDTO(
                bindingId: receipt.binding.bindingID,
                bindingRevision: receipt.binding.bindingRevision,
                bindingHash: receipt.binding.bindingHash
            )
            _ = try await rust.complete(HostBindingActivationConfirmationDTO(
                agentProfileId: successor.profileId,
                agentProfileRevision: successor.profileRevision,
                llmSlotId: successor.llmSlotId,
                requirementsHash: successor.requirementsHash,
                binding: binding,
                stagingReceiptDigest: receipt.receiptDigest
            ))
            completed.append(record.sourceDigest)
        }
        return LegacyLLMMigrationReconciliation(
            completedSourceDigests: completed.sorted(),
            selectionRequiredSourceDigests: selectionRequired.sorted(),
            bindingRequiredSourceDigests: bindingRequired.sorted()
        )
    }
}
