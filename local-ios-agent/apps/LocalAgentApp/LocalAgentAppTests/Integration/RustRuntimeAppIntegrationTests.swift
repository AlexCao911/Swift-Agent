import Foundation
import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Rust runtime App integration")
struct RustRuntimeAppIntegrationTests {
    @Test("app composition retains one canonical host process epoch")
    func appCompositionRetainsHostProcessEpoch() throws {
        let epoch = try HostProcessEpoch.generate()
        let container = try AppBootstrapper.makeContainer(
            hostProcessEpoch: epoch,
            environment: [:],
            store: .inMemory
        )
        let degraded = try AppBootstrapper.makeDegradedContainer(
            error: RuntimeBridgeError(kind: "test", message: "test"),
            hostProcessEpoch: epoch
        )
        let lastResort = AppBootstrapper.makeLastResortContainer(
            error: RuntimeBridgeError(kind: "test", message: "test"),
            hostProcessEpoch: epoch
        )

        #expect(container.hostProcessEpoch == epoch)
        #expect(degraded.hostProcessEpoch == epoch)
        #expect(lastResort.hostProcessEpoch == epoch)
    }

    @Test("ready composition passes the exact Rust epoch into the local subsystem")
    func readyCompositionSharesHostProcessEpoch() async throws {
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
    }

    @Test("Xcode run path builds and links the package-owned native runtime")
    func xcodeRunPathBuildsAndLinksSimulatorLlamaRuntime() throws {
        let schemeFile = try repositoryRoot()
            .appendingPathComponent("local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/xcshareddata/xcschemes/LocalAgentApp.xcscheme")
            .readUTF8()
        let packageManifest = try repositoryRoot()
            .appendingPathComponent("local-ios-agent/toolkit/Package.swift")
            .readUTF8()
        let xcodeBuildScript = try repositoryRoot()
            .appendingPathComponent("local-ios-agent/scripts/build-local-inference-xcode.sh")
            .readUTF8()

        #expect(schemeFile.contains("Build Rust local inference runtime"))
        #expect(schemeFile.contains("build-local-inference-xcode.sh"))
        #expect(xcodeBuildScript.contains("link-llama-cpp-local-inference"))
        #expect(xcodeBuildScript.contains("build-local-agent-inference-xcframework.sh"))
        #expect(xcodeBuildScript.contains("LOCAL_AGENT_INFERENCE_XCFRAMEWORK"))
        #expect(!xcodeBuildScript.contains("LLAMA_CPP_HEADERS"))
        #expect(!xcodeBuildScript.contains("LLAMA_CPP_XCFRAMEWORK"))
        #expect(packageManifest.contains("name: \"LocalAgentInferenceNative\""))
        #expect(packageManifest.contains("path: \"Artifacts/LocalAgentInferenceNative.xcframework\""))
        #expect(!packageManifest.contains("minicpmv-town/third_party/llama.cpp"))
    }

    @Test("App bootstrapper defaults to local LLM when simulator config is present")
    func appBootstrapperDefaultsToLocalLLMWhenSimulatorConfigIsPresent() throws {
        let modelURL = try writeTemporaryModelFile(extension: "gguf")
        defer { try? FileManager.default.removeItem(at: modelURL) }
        let environment = [
            "LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON": #"{"backend":"llama_cpp","model_path":"\#(modelURL.path)"}"#,
        ]
        let providers = AppBootstrapper.simulatorProviders(environment: environment)

        #expect(AppBootstrapper.runtimeProviderId(environment: environment, providers: providers) == "local_llm.llama_cpp")
        #expect(providers.count == 1)
        if case .namedLocalLLM(let providerId, let displayName, let model, let modelConfigJson, let maxContextTokens) = providers[0] {
            #expect(providerId == "local_llm.llama_cpp")
            #expect(displayName == "llama.cpp")
            #expect(model == "local.gguf.simulator")
            #expect(modelConfigJson.contains("llama_cpp"))
            #expect(maxContextTokens == 2048)
        } else {
            Issue.record("Expected named llama.cpp provider")
        }
    }

    @Test("App bootstrapper exposes configured local engine choices")
    func appBootstrapperExposesConfiguredLocalEngineChoices() throws {
        let llamaURL = try writeTemporaryModelFile(extension: "gguf")
        let litertURL = try writeTemporaryModelFile(extension: "task")
        defer {
            try? FileManager.default.removeItem(at: llamaURL)
            try? FileManager.default.removeItem(at: litertURL)
        }
        let environment = [
            "LOCAL_AGENT_LLAMA_CPP_MODEL_CONFIG_JSON": #"{"backend":"llama_cpp","model_path":"\#(llamaURL.path)"}"#,
            "LOCAL_AGENT_LITERT_MODEL_CONFIG_JSON": #"{"backend":"litert","model_path":"\#(litertURL.path)","model_format":"litert_lm"}"#,
            "LOCAL_AGENT_DEFAULT_PROVIDER_ID": "local_llm",
        ]
        let providers = AppBootstrapper.simulatorProviders(environment: environment)

        #expect(providers.map(\.bootstrapProviderId) == ["local_llm.llama_cpp", "local_llm.litert"])
        #expect(AppBootstrapper.runtimeProviderId(environment: environment, providers: providers) == "local_llm.llama_cpp")
    }

    @Test("App bootstrapper default container exposes visible native tools")
    @MainActor
    func appBootstrapperDefaultContainerExposesVisibleNativeTools() async throws {
        let container = try AppBootstrapper.makeContainer(
            hostProcessEpoch: try testHostProcessEpoch(),
            environment: [:]
        )
        let viewModel = container.makeToolCenterViewModel()

        await viewModel.reload()

        let toolNames = viewModel.rows.map(\.name)
        #expect(toolNames.contains("native.list_tools"))
        #expect(toolNames.contains("native.permission_status"))
        #expect(toolNames.contains("web.fetch_url_text"))
        #expect(toolNames.contains("files.pick_document"))
        #expect(toolNames.contains("photos.pick_images"))
    }

    @Test("App bootstrapper always installs exact-revision execution routing")
    func appBootstrapperAlwaysInstallsExactRevisionExecutionRouting() async throws {
        let container = try AppBootstrapper.makeContainer(
            hostProcessEpoch: try testHostProcessEpoch(),
            environment: [:],
            store: .inMemory
        )

        let usesCoordinator = await container.runtimeService.usesConversationExecutionCoordinatorForTesting()
        #expect(usesCoordinator)
    }

    @Test("legacy coordinator feature flag no longer changes production routing")
    func legacyCoordinatorFeatureFlagNoLongerChangesProductionRouting() async throws {
        let container = try AppBootstrapper.makeContainer(
            hostProcessEpoch: try testHostProcessEpoch(),
            environment: ["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR": "1"],
            store: .inMemory
        )

        let usesCoordinator = await container.runtimeService.usesConversationExecutionCoordinatorForTesting()
        #expect(usesCoordinator)
    }

    @Test("App container exposes Rust backed agent builder")
    @MainActor
    func appContainerExposesRustBackedAgentBuilder() async throws {
        let container = try AppBootstrapper.makeContainer(
            hostProcessEpoch: try testHostProcessEpoch(),
            environment: ["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR": "1"],
            store: .inMemory
        )
        let viewModel = container.makeAgentBuilderViewModel(
            profileId: "profile.builder.integration",
            templateId: "template_1"
        )

        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()

        #expect(viewModel.publishedProfileRevisionId == 1)
        #expect(viewModel.lifecycle == .published(profileRevisionId: 1))
    }

    @Test("container builder view model loads tool cards")
    @MainActor
    func containerBuilderViewModelLoadsToolCards() async throws {
        let container = try AppBootstrapper.makeContainer(
            hostProcessEpoch: try testHostProcessEpoch(),
            environment: ["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR": "1"],
            store: .inMemory
        )
        let viewModel = container.makeAgentBuilderViewModel()

        await viewModel.load()

        #expect(viewModel.draft != nil)
        #expect(!viewModel.toolCards.isEmpty)
    }

    @Test("container exposes user mediated picker tools")
    @MainActor
    func containerExposesUserMediatedPickerTools() async throws {
        let container = try AppBootstrapper.makeContainer(
            hostProcessEpoch: try testHostProcessEpoch(),
            environment: ["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR": "1"],
            store: .inMemory
        )
        let viewModel = container.makeAgentBuilderViewModel()

        await viewModel.load()
        let builderToolIds = viewModel.toolCards.map(\.id)
        #expect(builderToolIds.contains("files.pick_document"))
        #expect(builderToolIds.contains("photos.pick_images"))

        let snapshot = await container.nativeToolkitClient.registrationSnapshot()
        #expect(snapshot.toolNames.contains("files.pick_document"))
        #expect(snapshot.toolNames.contains("photos.pick_images"))

        try await assertPendingInteractionTool(
            container.nativeToolkitClient,
            toolName: "files.pick_document",
            toolCallId: "call_file_picker",
            interactionKind: "file_picker"
        )
        try await assertPendingInteractionTool(
            container.nativeToolkitClient,
            toolName: "photos.pick_images",
            toolCallId: "call_photo_picker",
            interactionKind: "photos_picker"
        )
    }

    private func testHostProcessEpoch() throws -> HostProcessEpoch {
        try HostProcessEpoch.generate()
    }
}

private func writeTemporaryModelFile(extension pathExtension: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalAgentTestModel-\(UUID().uuidString)")
        .appendingPathExtension(pathExtension)
    try Data("test model placeholder".utf8).write(to: url)
    return url
}

private func repositoryRoot(
    file: StaticString = #filePath
) throws -> URL {
    var url = URL(fileURLWithPath: "\(file)")
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("local-ios-agent").path) {
            return url
        }
        url.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

private extension URL {
    func readUTF8() throws -> String {
        try String(contentsOf: self, encoding: .utf8)
    }
}

private func decodedJSONObject(_ json: String) throws -> [String: Any] {
    let data = try #require(json.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func assertPendingInteractionTool(
    _ client: NativeToolkitClientProtocol,
    toolName: String,
    toolCallId: String,
    interactionKind: String
) async throws {
    let result = await client.execute(ToolExecutionRequestDTO(
        runId: "run_1",
        sessionId: "session_1",
        toolCallEntryId: "entry_1",
        toolCallId: toolCallId,
        toolName: toolName,
        argumentsJson: "{}"
    ))

    #expect(result.isError == false)
    let envelope = try decodedJSONObject(result.structuredJson)
    let resultPayload = try #require(envelope["result"] as? [String: Any])
    #expect(envelope["tool_call_id"] as? String == toolCallId)
    #expect(resultPayload["kind"] as? String == "pending_user_interaction")
    #expect(resultPayload["interaction_kind"] as? String == interactionKind)
}
