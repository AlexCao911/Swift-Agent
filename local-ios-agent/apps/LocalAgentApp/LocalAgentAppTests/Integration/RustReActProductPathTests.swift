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
        let rust = try RustRuntimeClient(configuration: RustRuntimeConfiguration(
            hostProcessEpoch: epoch,
            store: .inMemory
        ))
        let model = ProductPathModelExecutor()
        let dispatcher = ProductPathToolDispatcher()
        let tools = OpenMinisToolBatchExecutor(
            dispatcher: dispatcher,
            definitions: try OpenMinisToolDefinitionSnapshotProvider.productDefaults()
        )
        let host = try await LLMHostProductRuntime.bootstrap(
            rust: rust,
            hostProcessEpoch: epoch,
            modelExecutor: model,
            toolExecutor: tools
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
            snapshots: ProductPathSnapshotProvider(),
            models: ProductPathModelRunPreparer(),
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

        let requests = await model.requests
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
        #expect(await dispatcher.maximumActive == 2)
        #expect(
            await dispatcher.completedCallIDs.sorted()
                == ["call-1", "call-2"]
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
private struct ProductPathSnapshotProvider: RustAgentSnapshotProviding {
    func snapshot(
        conversationStreamID _: String?,
        modelContextWindow: ModelContextWindowDTO
    ) async throws -> RunStartSnapshotDTO {
        try RunStartSnapshotDTO.make(
            orderedPromptDocuments: [],
            skillDescriptors: [],
            orderedToolDefinitions: [
                ToolDefinitionSnapshotDTO(
                    name: "shell_execute",
                    description: "Execute a shell command.",
                    inputSchema: try .object(entries: [
                        .init(name: "type", value: .string("object")),
                        .init(
                            name: "properties",
                            value: try .object(entries: [
                                .init(
                                    name: "command",
                                    value: try .object(entries: [
                                        .init(name: "type", value: .string("string")),
                                    ])
                                ),
                            ])
                        ),
                        .init(
                            name: "required",
                            value: .array([.string("command")])
                        ),
                    ])
                ),
            ],
            modelContextWindow: modelContextWindow
        )
    }
}

@MainActor
private struct ProductPathModelRunPreparer: RustAgentModelRunPreparing {
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
        runID _: String,
        agentProfileID _: String,
        agentProfileRevisionID _: UInt64
    ) async throws {}

    func finishModelRun(runID _: String) async {}
}

private actor ProductPathModelExecutor: ModelGenerationExecuting {
    private(set) var requests: [HostModelRequest] = []

    func generate(
        _ request: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws {
        requests.append(request)
        if request.orderedToolResults.isEmpty {
            try await emit(.toolCallDelta(
                callID: "call-1",
                toolName: "shell_execute",
                argumentsFragment: #"{"command":"printf one"}"#
            ))
            try await emit(.toolCallDelta(
                callID: "call-2",
                toolName: "shell_execute",
                argumentsFragment: #"{"command":"printf two"}"#
            ))
        } else {
            try await emit(.textDelta("Both tools finished."))
        }
    }

    func cancel(runID _: String) async {}
}

private actor ProductPathToolDispatcher: OpenMinisToolDispatching {
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var completedCallIDs: [String] = []

    func execute(
        _ call: HostToolCall,
        context _: OpenMinisToolExecutionContext
    ) async -> HostToolResult {
        active += 1
        maximumActive = max(maximumActive, active)
        try? await Task.sleep(for: .milliseconds(20))
        active -= 1
        completedCallIDs.append(call.callID)
        return HostToolResult(
            callID: call.callID,
            toolName: call.toolName,
            result: .string("ok"),
            isError: false,
            dataClasses: [],
            highestSensitivity: "public"
        )
    }

    func cancel(processID _: Int32) async {}
}
