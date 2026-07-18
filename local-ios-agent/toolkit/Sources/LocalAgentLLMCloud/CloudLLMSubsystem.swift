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

    public static func bootstrap(
        appSupportRoot: URL,
        hostProcessEpoch: HostProcessEpoch,
        remoteCatalog: Data?,
        approvalPrompt: any CloudLLMApprovalPrompting,
        localUnloader: any LocalRouteUnloading
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
            originValidator: StablePublicOriginValidator()
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
        originValidator: any ProviderOriginValidating
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
        let bindingStore = try LLMStore(fileURL: databaseURL)
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
