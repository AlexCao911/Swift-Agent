import Foundation
import LocalAgentBridge

enum AppBootstrapper {
    static func makeContainer() throws -> AppContainer {
        let client = try RustRuntimeClient(configuration: RustRuntimeConfiguration(
            systemPrompt: "You are Local Agent.",
            runtimePolicy: "Use registered tools when helpful. Ask before risky work.",
            providerId: "mock",
            store: .sqlite(path: sqliteURL().path)
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
}
