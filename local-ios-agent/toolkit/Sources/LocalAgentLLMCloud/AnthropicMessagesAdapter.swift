package struct AnthropicMessagesAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .anthropic
    package let adapterID = "anthropic.messages"
    package let adapterVersion = "1"

    package init() {}

    package func makeDiscoveryRequest() throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.modelDiscovery(
            encoderID: "anthropic_messages",
            headers: ["anthropic-version": "2023-06-01"]
        )
    }

    package func makeAccountValidationRequest() throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.accountValidation(
            encoderID: "anthropic_messages",
            headers: ["anthropic-version": "2023-06-01"]
        )
    }

    package func makeModelValidationRequest(modelID: String) throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.anthropicModelValidation(
            encoderID: "anthropic_messages",
            modelID: modelID
        )
    }

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try AnthropicMessagesSession(context: context, semantics: .anthropic)
    }
}
