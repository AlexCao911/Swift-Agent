import Foundation
import LocalAgentBridge

enum AppBootstrapper {
    static func makeContainer() throws -> AppContainer {
        let providers = simulatorProviders()
        let client = try RustRuntimeClient(configuration: RustRuntimeConfiguration(
            systemPrompt: "You are Local Agent.",
            runtimePolicy: "Use registered tools when helpful. Ask before risky work.",
            providerId: "mock",
            store: .sqlite(path: sqliteURL().path),
            providers: providers
        ))
        let toolDriver = MinimalHostToolDriver()
        return AppContainer(runtimeService: AgentRuntimeService(
            runtimeClient: client,
            toolDriver: toolDriver
        ))
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

    private static func simulatorProviders(
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
