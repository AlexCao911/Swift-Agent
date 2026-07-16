package struct XAIAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .xAI
    package let adapterID = "xai.responses"
    package let adapterVersion = "1"

    package init() {}

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try OpenAIResponsesSession(context: context, semantics: .xAI)
    }
}
