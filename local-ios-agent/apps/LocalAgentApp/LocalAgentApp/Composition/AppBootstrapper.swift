import Foundation
import LocalAgentBridge

enum AppBootstrapper {
    static func makeContainer(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: RustRuntimeStoreConfiguration? = nil
    ) throws -> AppContainer {
        let providers = simulatorProviders(environment: environment)
        let runtimeStore: RustRuntimeStoreConfiguration
        if let store {
            runtimeStore = store
        } else {
            runtimeStore = .sqlite(path: try sqliteURL().path)
        }
        let client = try RustRuntimeClient(configuration: RustRuntimeConfiguration(
            systemPrompt: AgentPromptDefaults.systemPrompt,
            runtimePolicy: AgentPromptDefaults.runtimePolicy,
            providerId: runtimeProviderId(environment: environment, providers: providers),
            store: runtimeStore,
            providers: providers
        ))
        let toolDriver = MinimalHostToolDriver()
        let coordinator = conversationExecutionCoordinator(
            environment: environment,
            client: client
        )
        return AppContainer(runtimeService: AgentRuntimeService(
            runtimeClient: client,
            toolDriver: toolDriver,
            coordinator: coordinator
        ))
    }

    private static func conversationExecutionCoordinator(
        environment: [String: String],
        client: RustRuntimeClient
    ) -> ChatInteractionCoordinator? {
        guard environment["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR"] == "1" else {
            return nil
        }

        let conversationBridge = RustConversationBridgeClient(gateway: client, legacyClient: client)
        let executionBridge = RustExecutionBridgeClient(gateway: client, legacyClient: client)
        let conversationDomain = ConversationDomainAdapter(bridge: conversationBridge)
        let executionDomain = ExecutionDomainAdapter(
            profiles: AgentProfileService(bridge: executionBridge),
            composition: AgentCompositionService(bridge: executionBridge),
            lifecycle: RunLifecycleService(bridge: executionBridge),
            events: RunEventStreamService(bridge: executionBridge),
            tools: ToolApprovalService(bridge: executionBridge),
            debug: RunDebugService(bridge: executionBridge),
            inference: InferenceSettingsService(bridge: executionBridge)
        )
        let coordinator = ChatInteractionCoordinator(
            conversation: conversationDomain,
            execution: executionDomain
        )
        return coordinator
    }

    static func sqliteURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("LocalAgent", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("agent.sqlite")
    }

    static func runtimeProviderId(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        providers: [RustRuntimeProviderConfiguration]? = nil
    ) -> String {
        if let providerId = environment["LOCAL_AGENT_DEFAULT_PROVIDER_ID"], !providerId.isEmpty {
            return providerId
        }

        let configuredProviders = providers ?? simulatorProviders(environment: environment)
        if configuredProviders.contains(where: { provider in
            if case .localLLM = provider {
                return true
            }
            return false
        }) {
            return "local_llm"
        }

        return "mock"
    }

    static func simulatorProviders(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [RustRuntimeProviderConfiguration] {
        guard let modelConfigJson = environment["LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON"],
              !modelConfigJson.isEmpty
        else {
            return []
        }

        return [
            .localLLM(
                model: "local.gguf.simulator",
                modelConfigJson: modelConfigJson,
                maxContextTokens: 2048
            ),
        ]
    }
}
