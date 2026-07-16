import LocalAgentLLMContracts

package protocol CloudProviderAdapter: Sendable {
    var adapterID: String { get }
    var adapterVersion: String { get }
    var presetID: ProviderPresetID { get }

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
