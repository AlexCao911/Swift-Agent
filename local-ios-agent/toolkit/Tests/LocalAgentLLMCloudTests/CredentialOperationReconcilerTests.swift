import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("Credential lifecycle startup reconciliation")
struct CredentialOperationReconcilerTests {
    @Test(arguments: [
        CredentialLifecycleCheckpoint.creationIntentPersisted,
        .creationStagedWritten,
        .creationSlotPublished,
        .creationKeyPromoted,
        .creationActivated,
    ])
    func creationRecoveryIsDirectedByPersistedPhase(
        checkpoint: CredentialLifecycleCheckpoint
    ) async throws {
        let harness = try lifecycleHarness()
        harness.faults.arm(checkpoint)
        await expectLifecycleFailure("credential.injected_crash") {
            try await harness.store.createSlot(
                credentialRef: "shared",
                initialSecret: SecretBytes(utf8: "original"),
                operationID: "create"
            )
        }

        let report = try await CredentialOperationReconciler(
            credentialStore: harness.store
        ).reconcileStartup()

        if checkpoint == .creationIntentPersisted || checkpoint == .creationStagedWritten {
            #expect(try await harness.store.operation("create") == nil)
            #expect(try await harness.store.slot("shared") == nil)
            #expect(report.abortedCreationOperationIDs == ["create"])
        } else {
            #expect(try await harness.store.operation("create")?.phase == .complete)
            #expect(try await harness.store.slot("shared")?.lifecycle == .active)
            #expect(await harness.vault.hasFinal(credentialRef: "shared", generation: 1))
            #expect(report.completedCreationOperationIDs == ["create"] || checkpoint == .creationActivated)
        }
    }

    @Test
    func recoveryDeletesOnlyThePersistedOperationsStagedAccount() async throws {
        let harness = try lifecycleHarness()
        await harness.vault.seedStaged(
            credentialRef: "untracked",
            generation: 9,
            operationID: "not-persisted",
            value: "leave-me"
        )
        harness.faults.arm(.creationStagedWritten)
        await expectLifecycleFailure("credential.injected_crash") {
            try await harness.store.createSlot(
                credentialRef: "shared",
                initialSecret: SecretBytes(utf8: "original"),
                operationID: "create"
            )
        }

        _ = try await CredentialOperationReconciler(
            credentialStore: harness.store
        ).reconcileStartup()

        #expect(!(await harness.vault.hasStaged(
            credentialRef: "shared",
            generation: 1,
            operationID: "create"
        )))
        #expect(await harness.vault.hasStaged(
            credentialRef: "untracked",
            generation: 9,
            operationID: "not-persisted"
        ))
    }

    @Test(arguments: [
        CredentialLifecycleCheckpoint.rotationSlotLocked,
        .rotationStagedWritten,
        .rotationPromotionStarted,
        .rotationKeyPromoted,
    ])
    func prePublicationRotationRecoveryRollsBackToOldGeneration(
        checkpoint: CredentialLifecycleCheckpoint
    ) async throws {
        let harness = try lifecycleHarness()
        try await harness.createActiveSlot()
        harness.faults.arm(checkpoint)
        await expectLifecycleFailure("credential.injected_crash") {
            try await harness.store.rotateCredential(
                credentialRef: "shared",
                expectedGeneration: 1,
                replacement: SecretBytes(utf8: "replacement"),
                operationID: "rotate"
            )
        }

        _ = try await CredentialOperationReconciler(
            credentialStore: harness.store
        ).reconcileStartup()

        #expect(try await harness.store.slot("shared") == CredentialSlotState(
            credentialRef: "shared",
            currentGeneration: 1,
            lifecycle: .active
        ))
        #expect(await harness.vault.hasFinal(credentialRef: "shared", generation: 1))
        #expect(!(await harness.vault.hasStaged(
            credentialRef: "shared",
            generation: 2,
            operationID: "rotate"
        )))
        #expect(try await harness.store.lifecycleOperation("rotate")?.phase == .rolledBack)
    }

    @Test(arguments: [
        CredentialLifecycleCheckpoint.rotationPublished,
        .rotationOldKeyTombstoned,
        .rotationOldKeyDeleted,
    ])
    func postPublicationRotationRecoveryFinishesOldKeyDeletion(
        checkpoint: CredentialLifecycleCheckpoint
    ) async throws {
        let harness = try lifecycleHarness()
        try await harness.createActiveSlot()
        harness.faults.arm(checkpoint)
        await expectLifecycleFailure("credential.injected_crash") {
            try await harness.store.rotateCredential(
                credentialRef: "shared",
                expectedGeneration: 1,
                replacement: SecretBytes(utf8: "replacement"),
                operationID: "rotate"
            )
        }

        _ = try await CredentialOperationReconciler(
            credentialStore: harness.store
        ).reconcileStartup()

        #expect(try await harness.store.slot("shared")?.currentGeneration == 2)
        #expect(try await harness.store.slot("shared")?.lifecycle == .active)
        #expect(!(await harness.vault.hasFinal(credentialRef: "shared", generation: 1)))
        #expect(await harness.vault.hasFinal(credentialRef: "shared", generation: 2))
        #expect(try await harness.store.lifecycleOperation("rotate")?.phase == .complete)
    }

    @Test
    func stagedWriteFailureIsRolledBackByStartup() async throws {
        let harness = try lifecycleHarness()
        try await harness.createActiveSlot()
        await harness.vault.setFailNextStagedWrite()
        await expectLifecycleFailure("credential.vault_injected") {
            try await harness.store.rotateCredential(
                credentialRef: "shared",
                expectedGeneration: 1,
                replacement: SecretBytes(utf8: "replacement"),
                operationID: "rotate"
            )
        }

        _ = try await CredentialOperationReconciler(
            credentialStore: harness.store
        ).reconcileStartup()
        #expect(try await harness.store.slot("shared")?.lifecycle == .active)
        #expect(try await harness.store.slot("shared")?.currentGeneration == 1)
    }

    @Test
    func untrackedFinalItemIsReportedAndNeverAdoptedOrDeleted() async throws {
        let harness = try lifecycleHarness()
        try await harness.createActiveSlot()
        await harness.vault.seedFinal(
            credentialRef: "shared",
            generation: 2,
            value: "untracked"
        )

        await expectLifecycleFailure("credential.untracked_keychain_item") {
            try await harness.store.rotateCredential(
                credentialRef: "shared",
                expectedGeneration: 1,
                replacement: SecretBytes(utf8: "replacement"),
                operationID: "rotate"
            )
        }
        _ = try await CredentialOperationReconciler(
            credentialStore: harness.store
        ).reconcileStartup()

        #expect(await harness.vault.hasFinal(credentialRef: "shared", generation: 2))
        #expect(try await harness.store.slot("shared")?.currentGeneration == 1)
        #expect(try await harness.store.lifecycleOperation("rotate")?.phase == .rolledBack)
    }

    @Test
    func logicalProfileDeletionArchivesAllRevisionsButRetainsSharedCredential() async throws {
        let directory = temporaryLifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        let profiles = try ProviderProfileStore(
            fileURL: url,
            originValidator: LifecycleOriginValidator()
        )
        let vault = LifecycleCredentialVault()
        let credentials = try ProviderCredentialStore(fileURL: url, vault: vault)
        try await credentials.createSlot(
            credentialRef: "shared",
            initialSecret: SecretBytes(utf8: "original"),
            operationID: "create"
        )
        _ = try await profiles.publish(lifecycleProfile(profileID: "logical-a"))
        _ = try await profiles.publish(lifecycleProfile(profileID: "logical-b"))

        let refs = try await profiles.archiveLogicalProfile(profileID: "logical-a")
        #expect(refs == ["shared"])
        await expectLifecycleFailure("credential.referenced") {
            try await credentials.beginCredentialDeletion(
                credentialRef: "shared",
                expectedGeneration: 1,
                operationID: "delete"
            )
        }
        #expect(try await credentials.slot("shared") != nil)
        #expect(await profiles.profile(profileID: "logical-a", revision: 1)?.lifecycle == .archived)
        #expect(await profiles.profile(profileID: "logical-b", revision: 1)?.lifecycle == .active)
    }

    @Test
    func pendingHostBindingBlocksCredentialDeletionAfterProfileArchive() async throws {
        let directory = temporaryLifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        let profiles = try ProviderProfileStore(
            fileURL: url,
            originValidator: LifecycleOriginValidator()
        )
        let vault = LifecycleCredentialVault()
        let credentials = try ProviderCredentialStore(fileURL: url, vault: vault)
        try await credentials.createSlot(
            credentialRef: "shared",
            initialSecret: SecretBytes(utf8: "original"),
            operationID: "create"
        )
        _ = try await profiles.publish(lifecycleProfile(profileID: "logical-a"))
        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "cloud-target"),
            revision: 1,
            kind: .cloud(providerProfileID: "logical-a", providerProfileRevision: 1),
            modelID: "model",
            defaultParameters: GenerationConfiguration()
        )
        try await profiles.publishTarget(target)
        let bindingStore = try LLMStore(fileURL: url)
        _ = try await AgentHostBindingSaga(store: bindingStore).stageHostBinding(
            HostBindingStageRequest(
                operationToken: "binding-operation",
                tokenDigest: "binding-token-digest",
                llmSlotID: "assistant",
                requirementsHash: "requirements",
                configuration: AgentHostConfiguration(
                    bindingID: "binding",
                    revision: 1,
                    agentProfileID: "agent",
                    agentProfileRevision: 1,
                    llmSlotID: "assistant",
                    requirementsHash: "requirements",
                    llmTargetID: target.targetID,
                    llmTargetRevision: target.revision,
                    parameterOverrides: GenerationConfiguration()
                )
            )
        )
        _ = try await profiles.archiveLogicalProfile(profileID: "logical-a")

        await expectLifecycleFailure("credential.binding_pending") {
            try await credentials.beginCredentialDeletion(
                credentialRef: "shared",
                expectedGeneration: 1,
                operationID: "delete"
            )
        }
    }

    @Test
    func retainedCloudSnapshotBlocksCredentialDeletion() async throws {
        let harness = try lifecycleHarness()
        try await harness.createActiveSlot()
        try harness.database.execute(
            "INSERT INTO prepared_cloud_sessions VALUES ('session', 'prep', 'run', 'epoch', 'prepared', 2, ?1)",
            bindings: [.text("{\"credential_ref\":\"shared\"}")]
        )

        await expectLifecycleFailure("credential.snapshot_retained") {
            try await harness.store.beginCredentialDeletion(
                credentialRef: "shared",
                expectedGeneration: 1,
                operationID: "delete"
            )
        }
    }

    @Test
    func completedDeletionIsIdempotentAndConflictingReplayFails() async throws {
        let harness = try lifecycleHarness()
        try await harness.createActiveSlot()
        try await harness.store.beginCredentialDeletion(
            credentialRef: "shared",
            expectedGeneration: 1,
            operationID: "delete"
        )
        try await harness.store.beginCredentialDeletion(
            credentialRef: "shared",
            expectedGeneration: 1,
            operationID: "delete"
        )
        #expect(try await harness.store.slot("shared") == nil)

        await expectLifecycleFailure("credential.operation_conflict") {
            try await harness.store.beginCredentialDeletion(
                credentialRef: "shared",
                expectedGeneration: 2,
                operationID: "delete"
            )
        }
    }

    @Test(arguments: [CredentialUseLifecycle.acquired, .sessionBound, .closing])
    func deletionRejectsEveryLeaseLifecycle(lifecycle: CredentialUseLifecycle) async throws {
        let harness = try lifecycleHarness()
        try await harness.createActiveSlot()
        let acquired = try await harness.store.acquireUseLease(
            credentialRef: "shared",
            purpose: .preparation,
            preparationID: "prep",
            hostProcessEpoch: try HostProcessEpoch.generate()
        )
        if lifecycle == .sessionBound || lifecycle == .closing {
            let bound = try await harness.store.bindPreparationLease(
                acquired.leaseID,
                expectedRevision: acquired.revision
            )
            if lifecycle == .closing {
                _ = try await harness.store.beginClosingLease(
                    bound.leaseID,
                    expectedRevision: bound.revision
                )
            }
        }

        await expectLifecycleFailure("credential.in_use") {
            try await harness.store.beginCredentialDeletion(
                credentialRef: "shared",
                expectedGeneration: 1,
                operationID: "delete"
            )
        }
    }

    @Test(arguments: [
        CredentialLifecycleCheckpoint.deletionSlotLocked,
        .deletionKeyTombstoned,
        .deletionKeyDeleted,
    ])
    func deletionRecoveryRespectsTheKeyDeletionBoundary(
        checkpoint: CredentialLifecycleCheckpoint
    ) async throws {
        let harness = try lifecycleHarness()
        try await harness.createActiveSlot()
        harness.faults.arm(checkpoint)
        await expectLifecycleFailure("credential.injected_crash") {
            try await harness.store.beginCredentialDeletion(
                credentialRef: "shared",
                expectedGeneration: 1,
                operationID: "delete"
            )
        }

        _ = try await CredentialOperationReconciler(
            credentialStore: harness.store
        ).reconcileStartup()

        if checkpoint == .deletionSlotLocked {
            #expect(try await harness.store.slot("shared")?.lifecycle == .active)
            #expect(await harness.vault.hasFinal(credentialRef: "shared", generation: 1))
            #expect(try await harness.store.lifecycleOperation("delete")?.phase == .rolledBack)
        } else {
            #expect(try await harness.store.slot("shared") == nil)
            #expect(!(await harness.vault.hasFinal(credentialRef: "shared", generation: 1)))
            #expect(try await harness.store.lifecycleOperation("delete")?.phase == .complete)
        }
    }
}
