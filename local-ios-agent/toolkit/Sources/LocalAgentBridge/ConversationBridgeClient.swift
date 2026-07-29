public protocol ConversationBridgeClient: Sendable {
    func listSessions() async throws -> [ConversationSummaryDTO]
    func prepareUserTurn(_ request: PrepareUserTurnRequestDTO) async throws -> PreparedUserTurnDTO
    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO]
    func forkSession(sessionId: String, leafId: String) async throws -> String
    func archiveSession(sessionId: String) async throws
    func renameSession(sessionId: String, title: String) async throws
    func deleteSession(sessionId: String) async throws
    func commitAssistantResult(_ request: CommitAssistantResultRequestDTO) async throws -> ConversationCommitResultDTO
    func submitTranscriptCommand(
        _ command: TranscriptCommandDTO
    ) async throws -> TranscriptCommandResultDTO
    func observeTranscriptProjections(
        subscriptionID: String,
        conversationStreamID: String,
        afterSequence: UInt64
    ) -> AsyncThrowingStream<TranscriptProjectionEventDTO, Error>
    func cancelTranscriptProjectionSubscription(subscriptionID: String) async
}

public struct RustConversationBridgeClient: ConversationBridgeClient {
    private let gateway: any RustAgentOSBridgeGateway
    private let legacyClient: any ConversationRuntimeClient

    public init(
        gateway: any RustAgentOSBridgeGateway,
        legacyClient: any ConversationRuntimeClient
    ) {
        self.gateway = gateway
        self.legacyClient = legacyClient
    }

    public func listSessions() async throws -> [ConversationSummaryDTO] {
        try await legacyClient.conversationSummaries()
    }

    public func prepareUserTurn(_ request: PrepareUserTurnRequestDTO) async throws -> PreparedUserTurnDTO {
        try await gateway.request(.prepareUserTurn, request, as: PreparedUserTurnDTO.self)
    }

    public func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO] {
        try await legacyClient.activeBranch(sessionId: sessionId, leafId: leafId)
    }

    public func forkSession(sessionId: String, leafId: String) async throws -> String {
        try await legacyClient.forkSession(sessionId: sessionId, leafId: leafId)
    }

    public func archiveSession(sessionId: String) async throws {
        try await legacyClient.archiveSession(sessionId: sessionId)
    }

    public func renameSession(sessionId: String, title: String) async throws {
        try await legacyClient.renameSession(sessionId: sessionId, title: title)
    }

    public func deleteSession(sessionId: String) async throws {
        try await legacyClient.deleteSession(sessionId: sessionId)
    }

    public func commitAssistantResult(_ request: CommitAssistantResultRequestDTO) async throws -> ConversationCommitResultDTO {
        try await gateway.request(.commitAssistantResult, request, as: ConversationCommitResultDTO.self)
    }

    public func submitTranscriptCommand(
        _ command: TranscriptCommandDTO
    ) async throws -> TranscriptCommandResultDTO {
        try await gateway.request(
            .transcriptCommand,
            command,
            as: TranscriptCommandResultDTO.self
        )
    }

    public func observeTranscriptProjections(
        subscriptionID: String,
        conversationStreamID: String,
        afterSequence: UInt64
    ) -> AsyncThrowingStream<TranscriptProjectionEventDTO, Error> {
        gateway.observeTranscriptProjections(
            ObserveTranscriptProjectionsRequestDTO(
                subscriptionID: subscriptionID,
                conversationStreamID: conversationStreamID,
                afterSequence: afterSequence
            )
        )
    }

    public func cancelTranscriptProjectionSubscription(
        subscriptionID: String
    ) async {
        await gateway.cancelTranscriptProjectionSubscription(
            subscriptionID: subscriptionID
        )
    }
}
