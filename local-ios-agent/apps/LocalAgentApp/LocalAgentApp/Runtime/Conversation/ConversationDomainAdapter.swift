import LocalAgentBridge

struct ConversationDomainAdapter: ConversationDomain {
    private let bridge: any ConversationBridgeClient

    init(bridge: any ConversationBridgeClient) {
        self.bridge = bridge
    }

    func listSessions() async throws -> [ConversationSummaryDTO] {
        try await bridge.listSessions()
    }

    func prepareUserTurn(_ request: PrepareUserTurnRequestDTO) async throws -> PreparedUserTurnDTO {
        try await bridge.prepareUserTurn(request)
    }

    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO] {
        try await bridge.activeBranch(sessionId: sessionId, leafId: leafId)
    }

    func forkSession(sessionId: String, leafId: String) async throws -> String {
        try await bridge.forkSession(sessionId: sessionId, leafId: leafId)
    }

    func archiveSession(sessionId: String) async throws {
        try await bridge.archiveSession(sessionId: sessionId)
    }

    func renameSession(sessionId: String, title: String) async throws {
        try await bridge.renameSession(sessionId: sessionId, title: title)
    }

    func deleteSession(sessionId: String) async throws {
        try await bridge.deleteSession(sessionId: sessionId)
    }

    func commitAssistantResult(_ request: CommitAssistantResultRequestDTO) async throws -> ConversationCommitResultDTO {
        try await bridge.commitAssistantResult(request)
    }
}
