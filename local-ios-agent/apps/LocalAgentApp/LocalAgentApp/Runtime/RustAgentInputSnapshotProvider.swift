import LocalAgentBridge

@MainActor
struct RustAgentInputSnapshotProvider {
    private let promptDocuments: PromptDocumentStore
    private let skills: SkillStore
    private let toolDefinitions:
        @MainActor () async throws -> OpenMinisToolDefinitionSnapshotProvider

    init(
        promptDocuments: PromptDocumentStore,
        skills: SkillStore,
        toolDefinitions: @escaping
            @MainActor () async throws
                -> OpenMinisToolDefinitionSnapshotProvider
    ) {
        self.promptDocuments = promptDocuments
        self.skills = skills
        self.toolDefinitions = toolDefinitions
    }

    init(
        promptDocuments: PromptDocumentStore = .shared,
        skills: SkillStore = .shared,
        nativeToolkit: any NativeToolkitClientProtocol
    ) {
        self.init(
            promptDocuments: promptDocuments,
            skills: skills
        ) {
            let native = await nativeToolkit.registrationSnapshot()
            return try OpenMinisToolDefinitionSnapshotProvider.productDefaults(
                nativeSchemas: native.schemas
            )
        }
    }

    func snapshot(
        conversationStreamID: String?,
        modelContextWindow: ModelContextWindowDTO
    ) async throws -> RunStartSnapshotDTO {
        let definitions = try await toolDefinitions()
        return try RunStartSnapshotDTO.make(
            orderedPromptDocuments: promptDocuments.enabledSnapshots(),
            skillDescriptors: try skills.rustDescriptors(
                for: conversationStreamID
            ),
            orderedToolDefinitions: definitions.orderedDefinitions.map {
                ToolDefinitionSnapshotDTO(
                    name: $0.name,
                    description: $0.description,
                    inputSchema: $0.inputSchema
                )
            },
            modelContextWindow: modelContextWindow
        )
    }
}
