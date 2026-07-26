import Foundation
import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("LLM host composition")
struct LLMHostCompositionTests {
    @Test
    func bootstrapUsesOneEpochAndInstallsRecoveredLocalCloudHost() async throws {
        let epoch = try HostProcessEpoch.generate()
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try await AppBootstrapper.makeReadyContainer(
            hostProcessEpoch: epoch,
            environment: [:],
            store: .inMemory,
            localAppSupportRoot: root
        )

        #expect(container.hostProcessEpoch == epoch)
        #expect(container.localLLMSubsystem?.hostProcessEpoch == epoch)
        #expect(container.cloudLLMSubsystem?.hostProcessEpoch == epoch)
        #expect(container.llmHostRuntime?.hostProcessEpoch == epoch)

        container.suspendLLMHost()
        container.resumeLLMHost()
        container.shutdownLLMHost()
    }
}
