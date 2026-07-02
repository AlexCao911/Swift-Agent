import LocalAgentBridge

protocol ConversationDomain: Sendable {
    func listSessions() async throws -> [ConversationSummaryDTO]
    func prepareUserTurn(_ request: PrepareUserTurnRequestDTO) async throws -> PreparedUserTurnDTO
    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO]
    func forkSession(sessionId: String, leafId: String) async throws -> String
    func archiveSession(sessionId: String) async throws
    func renameSession(sessionId: String, title: String) async throws
    func deleteSession(sessionId: String) async throws
    func commitAssistantResult(_ request: CommitAssistantResultRequestDTO) async throws -> ConversationCommitResultDTO
}
