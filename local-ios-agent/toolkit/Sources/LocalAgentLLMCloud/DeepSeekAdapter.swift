package struct DeepSeekAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .deepSeek
    package let adapterID = "deepseek.chat_completions"
    package let adapterVersion = "1"

    package init() {}

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try OpenAIChatCompletionsSession(context: context, semantics: .deepSeek)
    }
}
