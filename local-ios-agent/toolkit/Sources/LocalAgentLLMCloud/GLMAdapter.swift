package struct GLMAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .glm
    package let adapterID = "glm.chat_completions"
    package let adapterVersion = "1"

    package init() {}

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try OpenAIChatCompletionsSession(context: context, semantics: .glm)
    }
}
