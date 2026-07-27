import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

public protocol CloudLLMApprovalPrompting:
    EgressApprovalPrompting,
    ProviderRetentionApprovalPrompting,
    Sendable
{}

public struct CloudLLMSubsystem: Sendable {
    public let hostProcessEpoch: HostProcessEpoch
    public let profiles: ProviderProfileStore
    public let credentials: ProviderCredentialStore
    public let retention: ProviderRetentionPolicy
    public let egress: ProviderEgressPolicy
    public let validation: ProviderValidationService
    public let runtime: CloudLLMRuntime
    package let catalog: CloudCapabilityCatalogStore
    package let sessions: PreparedCloudSessionStore
    package let bindingStore: LLMStore

    private init(
        hostProcessEpoch: HostProcessEpoch,
        profiles: ProviderProfileStore,
        credentials: ProviderCredentialStore,
        retention: ProviderRetentionPolicy,
        egress: ProviderEgressPolicy,
        validation: ProviderValidationService,
        runtime: CloudLLMRuntime,
        catalog: CloudCapabilityCatalogStore,
        sessions: PreparedCloudSessionStore,
        bindingStore: LLMStore
    ) {
        self.hostProcessEpoch = hostProcessEpoch
        self.profiles = profiles
        self.credentials = credentials
        self.retention = retention
        self.egress = egress
        self.validation = validation
        self.runtime = runtime
        self.catalog = catalog
        self.sessions = sessions
        self.bindingStore = bindingStore
    }

    public func createProviderProfile(
        _ revision: ProviderProfileRevision,
        initialSecret: SecretBytes,
        proposedOperationID: String = UUID().uuidString.lowercased()
    ) async throws -> PublishedProviderProfileRevision {
        defer { initialSecret.erase() }
        if let existing = await profiles.profile(
            profileID: revision.profileID,
            revision: revision.revision
        ) {
            guard existing.revision == revision, existing.lifecycle == .active else {
                throw ProviderProfileFailure(
                    code: "provider_profile.revision_conflict",
                    message: "profile revision is already published with different content"
                )
            }
            return existing
        }
        let operationID = try await profiles.prepareCreatingRevision(
            revision,
            proposedOperationID: proposedOperationID
        )
        try await credentials.createSlot(
            credentialRef: revision.credentialRef,
            initialSecret: initialSecret,
            operationID: operationID
        )
        return try await profiles.activateCreatingRevision(
            profileID: revision.profileID,
            revision: revision.revision,
            operationID: operationID,
            credentialStore: credentials
        )
    }

    public func providerInventory() async throws -> [CloudProviderProductState] {
        var result: [CloudProviderProductState] = []
        for profile in await profiles.allProfiles() where profile.lifecycle == .active {
            let state = await profiles.state(
                profileID: profile.revision.profileID,
                profileRevision: profile.revision.revision
            )
            let credential = try await credentials.slot(
                profile.revision.credentialRef
            )
            result.append(CloudProviderProductState(
                profileID: profile.revision.profileID,
                revision: profile.revision.revision,
                presetID: profile.revision.presetID,
                displayName: profile.revision.displayName,
                displayOrigin: profile.origin.serialized,
                baseURL: profile.revision.baseURL,
                retentionMode: profile.revision.retentionMode,
                validation: try await productValidationStatus(
                    state,
                    credentialRef: profile.revision.credentialRef,
                    modelID: nil
                ),
                hasStoredCredential: credential?.lifecycle == .active
            ))
        }
        return result
    }

    public func publishProviderProfileRevision(
        profileID proposedProfileID: String?,
        replacingRevision: UInt64?,
        presetID: ProviderPresetID,
        displayName: String,
        baseURL: URL,
        retentionMode: ProviderRetentionMode,
        initialSecret: SecretBytes?,
        proposedOperationID: String = UUID().uuidString.lowercased()
    ) async throws -> PublishedProviderProfileRevision {
        defer { initialSecret?.erase() }
        let profileID = proposedProfileID ?? UUID().uuidString.lowercased()
        let previous: PublishedProviderProfileRevision?
        if let replacingRevision {
            previous = await profiles.profile(
                profileID: profileID,
                revision: replacingRevision
            )
            guard previous?.lifecycle == .active else {
                throw ProviderProfileFailure(
                    code: "provider_profile.not_found",
                    message: "the profile revision being edited does not exist"
                )
            }
        } else {
            previous = nil
        }
        let credentialRef: String
        if initialSecret != nil {
            credentialRef = UUID().uuidString.lowercased()
        } else if let previous {
            credentialRef = previous.revision.credentialRef
        } else {
            throw CredentialFailure(
                code: "credential.secret_required",
                message: "a new provider profile requires an API key"
            )
        }
        let revision = (replacingRevision ?? 0) + 1
        let value = ProviderProfileRevision(
            profileID: profileID,
            revision: revision,
            presetID: presetID,
            displayName: displayName,
            baseURL: baseURL,
            credentialRef: credentialRef,
            retentionMode: retentionMode
        )
        let operationID = try await profiles.prepareCreatingRevision(
            value,
            proposedOperationID: proposedOperationID
        )
        if let initialSecret {
            try await credentials.createSlot(
                credentialRef: credentialRef,
                initialSecret: initialSecret,
                operationID: operationID
            )
        } else {
            guard try await credentials.slot(credentialRef)?.lifecycle == .active else {
                throw CredentialFailure(
                    code: "credential.slot_not_active",
                    message: "the existing provider credential is unavailable"
                )
            }
        }
        return try await profiles.activateCreatingRevision(
            profileID: profileID,
            revision: revision,
            operationID: operationID,
            credentialStore: credentials
        )
    }

    public func modelInventory(
        profileID: String,
        profileRevision: UInt64,
        manualModelID: String? = nil
    ) async throws -> [CloudModelProductState] {
        guard let profile = await profiles.profile(
            profileID: profileID,
            revision: profileRevision
        ), profile.lifecycle == .active else {
            throw ProviderProfileFailure(
                code: "provider_profile.not_found",
                message: "active provider profile revision does not exist"
            )
        }
        let state = await profiles.state(
            profileID: profileID,
            profileRevision: profileRevision
        )
        var entries = try await catalog.modelEntries(
            presetID: profile.revision.presetID
        ).map { entry in
            CloudModelProductState(
                profileID: profileID,
                profileRevision: profileRevision,
                modelID: entry.identity.modelID,
                modelRevision: entry.identity.modelRevision,
                capabilities: productCapabilitySnapshot(entry),
                parameterSchema: entry.parameterSchema,
                validation: .unvalidated
            )
        }
        var additionalModelIDs: [String] = []
        if let manualModelID, !manualModelID.isEmpty {
            additionalModelIDs.append(manualModelID)
        }
        if case .validated(let evidence) = state?.validationState {
            additionalModelIDs.append(evidence.modelID)
        }
        for manualModelID in Set(additionalModelIDs)
        where !entries.contains(where: { $0.modelID == manualModelID }) {
            entries.append(CloudModelProductState(
                profileID: profileID,
                profileRevision: profileRevision,
                modelID: manualModelID,
                modelRevision: nil,
                capabilities: CapabilitySnapshot(capabilities: [:]),
                parameterSchema: LLMParameterSchema(definitions: []),
                validation: .unvalidated
            ))
        }
        var result: [CloudModelProductState] = []
        for model in entries {
            result.append(CloudModelProductState(
                profileID: model.profileID,
                profileRevision: model.profileRevision,
                modelID: model.modelID,
                modelRevision: model.modelRevision,
                capabilities: model.capabilities,
                parameterSchema: model.parameterSchema,
                validation: try await productValidationStatus(
                    state,
                    credentialRef: profile.revision.credentialRef,
                    modelID: model.modelID
                )
            ))
        }
        return result
    }

    public func rotateProviderCredential(
        profileID: String,
        profileRevision: UInt64,
        replacement: SecretBytes,
        operationID: String = UUID().uuidString.lowercased()
    ) async throws {
        defer { replacement.erase() }
        guard let profile = await profiles.profile(
            profileID: profileID,
            revision: profileRevision
        ), profile.lifecycle == .active,
            let slot = try await credentials.slot(profile.revision.credentialRef),
            slot.lifecycle == .active
        else {
            throw CredentialFailure(
                code: "credential.slot_not_active",
                message: "provider credential slot is not active"
            )
        }
        try await credentials.rotateCredential(
            credentialRef: profile.revision.credentialRef,
            expectedGeneration: slot.currentGeneration,
            replacement: replacement,
            operationID: operationID
        )
    }

    public func archiveProviderProfile(
        profileID: String,
        operationID: String = UUID().uuidString.lowercased()
    ) async throws {
        let credentialRefs = try await profiles.archiveLogicalProfile(
            profileID: profileID
        )
        for (index, credentialRef) in credentialRefs.enumerated() {
            guard let slot = try await credentials.slot(credentialRef),
                  slot.lifecycle == .active else { continue }
            try await credentials.beginCredentialDeletion(
                credentialRef: credentialRef,
                expectedGeneration: slot.currentGeneration,
                operationID: "\(operationID)-\(index)"
            )
        }
    }

    private func productValidationStatus(
        _ state: ProviderProfileState?,
        credentialRef: String,
        modelID: String?
    ) async throws -> ProviderValidationStatus {
        guard let state else { return .unvalidated }
        switch state.validationState {
        case .unvalidated:
            return .unvalidated
        case let .invalidated(reasonCode):
            return .invalidated(reasonCode: reasonCode)
        case let .validated(evidence):
            guard modelID == nil || evidence.modelID == modelID else {
                return .unvalidated
            }
            guard evidence.expiresAt > Date(),
                  let slot = try await credentials.slot(credentialRef),
                  slot.lifecycle == .active,
                  slot.currentGeneration == evidence.credentialGeneration
            else {
                return .stale
            }
            return .current(expiresAt: evidence.expiresAt)
        }
    }

    public static func bootstrap(
        appSupportRoot: URL,
        hostProcessEpoch: HostProcessEpoch,
        remoteCatalog: Data?,
        approvalPrompt: any CloudLLMApprovalPrompting,
        localUnloader: any LocalRouteUnloading,
        llmStore: LLMStore? = nil
    ) async throws -> CloudLLMSubsystem {
        let resources = try CloudCapabilityCatalogResources.loadBundled()
        let vault = SecurityCredentialVault()
        return try await bootstrap(
            appSupportRoot: appSupportRoot,
            hostProcessEpoch: hostProcessEpoch,
            bundledCatalog: resources.envelope,
            trustedKeyRing: resources.keyRing,
            remoteCatalog: remoteCatalog,
            vault: vault,
            approvalPrompt: approvalPrompt,
            transportFactory: { credentials in
                URLSessionCloudHTTPTransport(credentialStore: credentials)
            },
            localUnloader: localUnloader,
            originValidator: StablePublicOriginValidator(),
            llmStore: llmStore
        )
    }

    package static func bootstrap(
        appSupportRoot: URL,
        hostProcessEpoch: HostProcessEpoch,
        bundledCatalog: Data,
        trustedKeyRing: Data,
        remoteCatalog: Data?,
        vault: any CredentialVault,
        approvalPrompt: any CloudLLMApprovalPrompting,
        transportFactory: @Sendable (ProviderCredentialStore) throws -> any CloudHTTPTransport,
        localUnloader: any LocalRouteUnloading,
        originValidator: any ProviderOriginValidating,
        llmStore: LLMStore? = nil
    ) async throws -> CloudLLMSubsystem {
        let root = appSupportRoot.appending(
            path: "LocalAgent/LLM",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "llm-state.sqlite")

        let profiles = try ProviderProfileStore(
            fileURL: databaseURL,
            originValidator: originValidator
        )
        let credentials = try ProviderCredentialStore(
            fileURL: databaseURL,
            vault: vault
        )
        _ = try await CredentialOperationReconciler(
            credentialStore: credentials,
            currentHostProcessEpoch: hostProcessEpoch
        ).reconcileStartup()
        try await profiles.reconcileCreatingRevisions(
            credentialStore: credentials
        )
        let sessions = try PreparedCloudSessionStore(fileURL: databaseURL)
        _ = try sessions.recoverOldEpoch(hostProcessEpoch)

        let catalog = try CloudCapabilityCatalogStore(
            fileURL: databaseURL,
            trustedKeyRing: trustedKeyRing
        )
        let bundled = try CloudCapabilityCatalogVerifier.verify(
            envelope: bundledCatalog,
            keyRing: trustedKeyRing
        )
        if let current = try await catalog.current() {
            if bundled.catalogRevision == current.catalogRevision {
                _ = try await catalog.accept(envelope: bundledCatalog)
            } else if bundled.catalogRevision > current.catalogRevision {
                _ = try await catalog.accept(envelope: bundledCatalog)
            }
        } else {
            _ = try await catalog.accept(envelope: bundledCatalog)
        }
        if let remoteCatalog {
            let remote = try CloudCapabilityCatalogVerifier.verify(
                envelope: remoteCatalog,
                keyRing: trustedKeyRing
            )
            if let current = try await catalog.current() {
                if remote.catalogRevision >= current.catalogRevision {
                    _ = try await catalog.accept(envelope: remoteCatalog)
                }
            } else {
                _ = try await catalog.accept(envelope: remoteCatalog)
            }
        }
        _ = try CloudProviderAdapterRegistry.shipped()

        let retention = try ProviderRetentionPolicy(
            fileURL: databaseURL,
            prompt: approvalPrompt
        )
        let egress = try ProviderEgressPolicy(
            fileURL: databaseURL,
            credentialStore: credentials,
            retentionPolicy: retention,
            prompt: approvalPrompt
        )
        let transport = try transportFactory(credentials)
        let validation = try ProviderValidationService(
            fileURL: databaseURL,
            profileStore: profiles,
            catalogStore: catalog,
            credentialStore: credentials,
            egressPolicy: egress,
            transport: transport,
            hostProcessEpoch: hostProcessEpoch
        )
        let bindingStore = try llmStore ?? LLMStore(fileURL: databaseURL)
        let runtime = CloudLLMRuntime(
            profileStore: profiles,
            catalogStore: catalog,
            credentialStore: credentials,
            validationService: validation,
            egressPolicy: egress,
            sessionStore: sessions,
            bindingSaga: AgentHostBindingSaga(store: bindingStore),
            attachmentResolver: PhaseThreeAttachmentIdentityResolver(),
            transport: transport,
            localUnloader: localUnloader,
            adapters: try .shipped(),
            hostProcessEpoch: hostProcessEpoch
        )
        return CloudLLMSubsystem(
            hostProcessEpoch: hostProcessEpoch,
            profiles: profiles,
            credentials: credentials,
            retention: retention,
            egress: egress,
            validation: validation,
            runtime: runtime,
            catalog: catalog,
            sessions: sessions,
            bindingStore: bindingStore
        )
    }
}

private struct PhaseThreeAttachmentIdentityResolver: CloudAttachmentIdentityResolving {
    func resolveIdentities(
        for input: AgentLLMInput,
        sourceRevisionDocument: CanonicalJSONValue
    ) throws -> [CloudResolvedAttachmentIdentity] {
        []
    }
}

private func productCapabilitySnapshot(
    _ entry: CloudModelCatalogEntry
) -> CapabilitySnapshot {
    var capabilities: [String: ResolvedCapability] = [:]
    for declaration in entry.capabilities {
        capabilities[declaration.capabilityID] = switch declaration.value {
        case let .support(support):
            ResolvedCapability(support: support, verifiedUpperBound: nil)
        case let .verifiedUpperBound(bound):
            ResolvedCapability(support: .supported, verifiedUpperBound: bound)
        }
    }
    return CapabilitySnapshot(capabilities: capabilities)
}
