import LocalAgentLLMContracts

package protocol CloudProviderAdapter: Sendable {
    var adapterID: String { get }
    var adapterVersion: String { get }
    var presetID: ProviderPresetID { get }

    func makeDiscoveryRequest() throws -> CloudWireRequest
    func makeAccountValidationRequest() throws -> CloudWireRequest
    func makeModelValidationRequest(modelID: String) throws -> CloudWireRequest
    func makeModelValidationRequest(
        modelID: String,
        providerProjectID: String?
    ) throws -> CloudWireRequest
    func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession
}

package protocol CloudProviderSession: AnyObject, Sendable {
    func encodeStart(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest
    func encodeResume(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest
    func decode(_ events: AsyncThrowingStream<SSEEvent, Error>) -> LLMBackendEventStream
    func cancel() async
    func close() async
}

extension CloudProviderAdapter {
    package func makeModelValidationRequest(
        modelID: String,
        providerProjectID _: String?
    ) throws -> CloudWireRequest {
        try makeModelValidationRequest(modelID: modelID)
    }
}
