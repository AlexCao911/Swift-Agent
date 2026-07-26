import LocalAgentLLMContracts

package enum HostGenerationMode: Sendable {
    case start
    case resume
}

package struct HostGenerationTurn: Sendable {
    package let commandID: String
    package let generationTurnID: String
    package let payload: HostCommandPayload
    package let disclosure: GenerationDisclosure

    package init(
        commandID: String,
        generationTurnID: String,
        payload: HostCommandPayload,
        disclosure: GenerationDisclosure
    ) {
        self.commandID = commandID
        self.generationTurnID = generationTurnID
        self.payload = payload
        self.disclosure = disclosure
    }
}

package struct HostGenerationOperation: Sendable {
    package let opaqueOperationID: String
    package let events: LLMBackendEventStream

    package init(
        opaqueOperationID: String,
        events: LLMBackendEventStream
    ) {
        self.opaqueOperationID = opaqueOperationID
        self.events = events
    }
}

package struct AuthorizedHostGenerationLaunch: Sendable {
    package let run: @Sendable () async throws -> HostGenerationOperation

    package init(
        run: @escaping @Sendable () async throws -> HostGenerationOperation
    ) {
        self.run = run
    }
}

package protocol LLMHostSessionDriver: Sendable {
    func makeAuthorizedLaunch(
        for turn: HostGenerationTurn,
        mode: HostGenerationMode
    ) async throws -> AuthorizedHostGenerationLaunch

    func cancel() async throws
    func close() async throws
}
