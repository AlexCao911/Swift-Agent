import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMCore
import LocalAgentLLMLocal
import Testing

@Suite("Local inference release smoke")
struct LocalInferenceReleaseSmokeTests {
    @Test("verified release installation completes through the direct Swift runtime")
    func releaseInstalledModelCompletesOneTurnOnDirectSwiftRuntime() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOCAL_AGENT_RUN_PHASE2_RELEASE_SMOKE"] == "1" else { return }

        let catalogPath = try requiredEnvironment(
            "LOCAL_AGENT_PHASE2_RELEASE_CATALOG_PATH",
            environment: environment
        )
        let installationPath = try requiredEnvironment(
            "LOCAL_AGENT_PHASE2_RELEASE_INSTALLATION_ROOT",
            environment: environment
        )
        let engineID = try requiredEnvironment(
            "LOCAL_AGENT_PHASE2_RELEASE_ENGINE_ID",
            environment: environment
        )
        let modelID = try requiredEnvironment(
            "LOCAL_AGENT_PHASE2_RELEASE_MODEL_ID",
            environment: environment
        )
        let installationRoot = URL(fileURLWithPath: installationPath, isDirectory: true)
            .standardizedFileURL
        let installationID = installationRoot.lastPathComponent
        let appSupportRoot = try appSupportRoot(for: installationRoot)
        let epoch = try HostProcessEpoch.generate()
        let subsystem = try await LocalLLMSubsystem.bootstrap(
            appSupportRoot: appSupportRoot,
            hostProcessEpoch: epoch,
            remoteCatalog: try Data(contentsOf: URL(fileURLWithPath: catalogPath))
        )
        let manifest = try #require(subsystem.acceptedCatalog.verified.models.values.first {
            $0.id.modelID == modelID && $0.engineID == engineID
        })

        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "release-smoke-target"),
            revision: 1,
            kind: .local(installationID: installationID),
            modelID: manifest.id.modelID,
            defaultParameters: GenerationConfiguration()
        )
        let configuration = AgentHostConfiguration(
            bindingID: "release-smoke-binding",
            revision: 1,
            agentProfileID: "release-smoke-profile",
            agentProfileRevision: 1,
            llmSlotID: "assistant",
            requirementsHash: "release-smoke-requirements",
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            parameterOverrides: GenerationConfiguration()
        )
        let bindingStore = try LLMStore(fileURL: appSupportRoot.appending(
            path: "LocalAgent/LLM/llm-state.sqlite"
        ))
        let saga = AgentHostBindingSaga(store: bindingStore)
        let operation = "release-smoke-\(UUID().uuidString.lowercased())"
        let receipt = try await saga.stageHostBinding(HostBindingStageRequest(
            operationToken: operation,
            tokenDigest: "release-smoke-digest-\(UUID().uuidString.lowercased())",
            llmSlotID: configuration.llmSlotID,
            requirementsHash: configuration.requirementsHash,
            configuration: configuration
        ))
        try await saga.activateHostBinding(operationToken: operation, binding: receipt.binding)

        let session = try await subsystem.runtime.prepareSession(
            hostConfiguration: configuration,
            target: target
        )
        let events = try await subsystem.runtime.startGeneration(
            sessionID: session.sessionID,
            input: AgentLLMInput(
                inputID: "release-smoke-turn",
                messages: [LLMInputMessage(
                    role: .user,
                    content: [.text("Reply with one short greeting.")]
                )]
            ),
            attachments: [],
            toolSchema: nil
        )
        var sawText = false
        var sawTerminal = false
        for try await event in events {
            switch event {
            case let .textDelta(text):
                sawText = sawText || !text.isEmpty
            case let .generationCompleted(completion):
                sawTerminal = completion.outcome == .finalResponse
            default:
                break
            }
        }
        #expect(sawText)
        #expect(sawTerminal)
        try await subsystem.runtime.closeSession(sessionID: session.sessionID)
        try await subsystem.runtime.unload()
    }
}

private func requiredEnvironment(
    _ name: String,
    environment: [String: String]
) throws -> String {
    guard let value = environment[name], !value.isEmpty else {
        throw LLMFailure(
            code: "release_smoke.configuration_missing",
            message: "required release smoke configuration is missing: \(name)",
            retryable: false
        )
    }
    return value
}

private func appSupportRoot(for installationRoot: URL) throws -> URL {
    var cursor = installationRoot
    let expected = [installationRoot.lastPathComponent, "installations", "models", "LLM", "LocalAgent"]
    for component in expected {
        guard cursor.lastPathComponent == component else {
            throw LLMFailure(
                code: "release_smoke.installation_root_invalid",
                message: "installation root must end in LocalAgent/LLM/models/installations/<installation-id>",
                retryable: false
            )
        }
        cursor.deleteLastPathComponent()
    }
    return cursor
}
