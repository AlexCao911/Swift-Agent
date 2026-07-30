import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMHost
import Testing
@testable import LocalAgentApp

@Suite("Rust ReAct product path")
struct RustReActProductPathTests {
    @Test("Rust drives a two-tool turn and projects the final answer")
    @MainActor
    func rustDrivesToolTurnAndFinalProjection() async throws {
        let epoch = try HostProcessEpoch.generate()
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try AppBootstrapper.makeContainer(
            hostProcessEpoch: epoch,
            store: .inMemory,
            attachmentStoreRoot: root.appending(path: "attachments")
        )
        let rust = try #require(container.rustRuntimeClient)
        let providerRoute = ProductPathProviderRoute()
        let modelRegistry = OpenMinisModelExecutionRegistry()
        let modelExecutor = OpenMinisModelExecutor(
            plans: modelRegistry,
            runtime: modelRegistry
        )
        let host = try await AppBootstrapper.bootstrapLLMHost(
            container: container,
            modelExecutor: modelExecutor
        )
        let conversation = RustConversationBridgeClient(
            gateway: rust,
            legacyClient: rust
        )
        let chatStore = ChatStore()
        let projectionStore = try TranscriptProjectionStore(fileURL: nil)
        let applier = ChatStoreProjectionApplier(
            store: chatStore,
            persistence: projectionStore
        )
        let projections = ProjectionFeedController(
            client: conversation,
            applier: applier
        )
        let coordinator = RustAgentCoordinator(
            conversation: conversation,
            snapshots: RustAgentInputSnapshotProvider(
                promptDocuments: try PromptDocumentStore(
                    fileURL: root.appending(path: "prompt-documents.json")
                ),
                skills: try SkillStore(
                    skillsDirectory: root.appending(path: "skills"),
                    metadataURL: root.appending(path: "skills.json"),
                    overridesURL: root.appending(path: "skill-overrides.json")
                ),
                nativeToolkit: container.nativeToolkitClient
            ),
            models: ProductPathModelRunPreparer(
                registry: modelRegistry,
                route: providerRoute
            ),
            projections: projections
        )

        let result = try await coordinator.send(
            requestID: "product-request",
            conversationStreamID: "product-conversation",
            clientMessageID: "product-user-message",
            text: "run both tools",
            attachments: [],
            agentProfileID: "product-agent",
            agentProfileRevisionID: 1
        )
        #expect(result.runID != nil)
        let reachedFinalProjection = await waitForProductProjection {
            (try? applier.cursor(for: "product-conversation")) == 7
        }

        let requests = await providerRoute.requests
        let cursor = try applier.cursor(for: "product-conversation")
        let projectedEvents = try projectionStore.events(
            for: "product-conversation"
        )
        #expect(
            reachedFinalProjection,
            """
            expected final sequence 7, received \(cursor) after \
            \(requests.count) model requests; events: \
            \(projectedEvents.map { "\($0.kind.rawValue)=\($0.payload)" })
            """
        )
        if requests.count == 2 {
            #expect(requests[0].orderedToolResults.isEmpty)
            #expect(
                requests[1].orderedToolResults.map(\.callID)
                    == ["call-1", "call-2"]
            )
        } else {
            Issue.record("expected two model requests, received \(requests.count)")
        }
        #expect(
            requests.last?.orderedToolResults.map(\.toolName)
                == ["native.list_tools", "native.permission_status"]
        )
        #expect(
            chatStore.projectedMessages(
                conversationStreamID: "product-conversation"
            ).last?.text == "Both tools finished."
        )

        await projections.stopAll()
        try host.shutdown()
    }
}

@MainActor
private func waitForProductProjection(
    _ condition: () -> Bool
) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor
private struct ProductPathModelRunPreparer: RustAgentModelRunPreparing {
    let registry: OpenMinisModelExecutionRegistry
    let route: ProductPathProviderRoute

    func modelContextWindow(
        agentProfileID _: String,
        agentProfileRevisionID _: UInt64
    ) async throws -> ModelContextWindowDTO {
        ModelContextWindowDTO(
            contextWindowTokens: 32_768,
            maxOutputTokens: 4_096
        )
    }

    func prepareModelRun(
        runID: String,
        agentProfileID _: String,
        agentProfileRevisionID _: UInt64
    ) async throws {
        let candidate = ProviderRunCandidate(
            id: "product-provider",
            kind: .cloud,
            providerConfigurationID: "product-provider-configuration",
            providerType: "openAI",
            modelID: "product-model",
            baseURL: URL(string: "https://example.com/v1"),
            presetID: .openAIChatCompletions
        )
        try await registry.bind(
            runID: runID,
            plan: ProviderRunPlan(
                logicalModelID: candidate.modelID,
                orderedCandidates: [candidate],
                modelContextWindow: ModelContextWindowDTO(
                    contextWindowTokens: 32_768,
                    maxOutputTokens: 4_096
                )
            ),
            routes: [candidate.id: route]
        )
    }

    func finishModelRun(runID: String) async {
        await registry.finish(runID: runID)
    }
}

private actor ProductPathProviderRoute: ProviderCandidateModelRoute {
    private(set) var requests: [HostModelRequest] = []

    func generate(
        _ request: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws {
        requests.append(request)
        if request.orderedToolResults.isEmpty {
            try await emit(.toolCallDelta(
                callID: "call-1",
                toolName: "native.list_tools",
                argumentsFragment: "{}"
            ))
            try await emit(.toolCallDelta(
                callID: "call-2",
                toolName: "native.permission_status",
                argumentsFragment: "{}"
            ))
        } else {
            try await emit(.textDelta("Both tools finished."))
        }
    }

    func cancel(runID _: String) async {}
    func finish(runID _: String) async {}
}
