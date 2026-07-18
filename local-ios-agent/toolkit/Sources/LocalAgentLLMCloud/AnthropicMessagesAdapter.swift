package struct AnthropicMessagesAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .anthropic
    package let adapterID = "anthropic.messages"
    package let adapterVersion = "1"

    package init() {}

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try AnthropicMessagesSession(context: context, semantics: .anthropic)
    }
}
