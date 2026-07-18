package struct MiniMaxAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .miniMax
    package let adapterID = "minimax.messages"
    package let adapterVersion = "1"

    package init() {}

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try AnthropicMessagesSession(context: context, semantics: .miniMax)
    }
}
