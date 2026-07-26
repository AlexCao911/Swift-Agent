import Foundation
import LocalAgentBridge
import Testing
@testable import LocalAgentLLMHost

@Suite("LLM host recovery")
struct LLMHostRecoveryTests {
    @Test
    func committedEffectReplaysStoredSafeResultWithoutExecution() async throws {
        let fixture = try EffectFixture()
        let request = fixture.request
        var ledger: HostToolEffectLedger? = try HostToolEffectLedger(
            fileURL: fixture.databaseURL
        )
        let token = try await ledger!.prepare(
            request,
            generationTurnID: "turn-1"
        )
        try await ledger!.commit(token, result: fixture.result)
        ledger = nil

        let reopened = try HostToolEffectLedger(fileURL: fixture.databaseURL)
        let replay = try await reopened.prepare(
            request,
            generationTurnID: "turn-1"
        )
        #expect(replay.replayResult == fixture.result)
        #expect(replay.shouldExecute == false)
    }

    @Test
    func crashAfterPreparedBecomesOutcomeUnknownAndNeverAutoRepeats() async throws {
        let fixture = try EffectFixture()
        var ledger: HostToolEffectLedger? = try HostToolEffectLedger(
            fileURL: fixture.databaseURL
        )
        _ = try await ledger!.prepare(
            fixture.request,
            generationTurnID: "turn-1"
        )
        ledger = nil

        let reopened = try HostToolEffectLedger(fileURL: fixture.databaseURL)
        await #expect(throws: HostToolEffectError.self) {
            _ = try await reopened.prepare(
                fixture.request,
                generationTurnID: "turn-1"
            )
        }
    }
}

private struct EffectFixture {
    let directory: URL
    let databaseURL: URL
    let request = ToolExecutionRequestDTO(
        runId: "run-1",
        sessionId: "session-1",
        toolCallEntryId: "entry-1",
        toolCallId: "call-1",
        toolName: "contacts.search",
        argumentsJson: "{}"
    )
    let result = ToolResultDTO(
        displayText: "one match",
        modelText: "one match",
        structuredJson: #"{"matches":1}"#,
        auditText: "contacts searched",
        sensitivity: .private,
        retention: .runOnly,
        isError: false
    )

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        databaseURL = directory.appendingPathComponent("effects.sqlite")
    }
}
