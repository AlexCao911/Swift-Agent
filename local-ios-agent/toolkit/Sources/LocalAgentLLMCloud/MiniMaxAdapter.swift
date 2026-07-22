package struct MiniMaxAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .miniMax
    package let adapterID = "minimax.messages"
    package let adapterVersion = "1"

    package init() {}

    package func makeDiscoveryRequest() throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.modelDiscovery(encoderID: "anthropic_messages")
    }

    package func makeAccountValidationRequest() throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.accountValidation(encoderID: "anthropic_messages")
    }

    package func makeModelValidationRequest(modelID: String) throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.miniMaxModelValidation(
            encoderID: "anthropic_messages",
            modelID: modelID
        )
    }

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try AnthropicMessagesSession(context: context, semantics: .miniMax)
    }
}
