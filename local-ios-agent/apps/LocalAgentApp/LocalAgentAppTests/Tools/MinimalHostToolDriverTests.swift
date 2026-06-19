import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Minimal host tool driver")
struct MinimalHostToolDriverTests {
    @Test("debug.echo returns a public run-only tool result once")
    func debugEchoReturnsToolResultOnce() async throws {
        let driver = MinimalHostToolDriver()
        let request = toolRequest(argumentsJson: #"{"text":"hello"}"#)

        let first = try await driver.execute(request, continuationIndex: 0)
        let second = try await driver.execute(request, continuationIndex: 1)

        #expect(first?.displayText == "Echo: hello")
        #expect(first?.modelText == "debug.echo: hello")
        #expect(first?.sensitivity == .public)
        #expect(first?.retention == .runOnly)
        #expect(first?.isError == false)
        #expect(second == nil)
    }

    @Test("continuation index is capped")
    func continuationIndexIsCapped() async throws {
        let driver = MinimalHostToolDriver(maxContinuations: 4)

        do {
            _ = try await driver.execute(toolRequest(), continuationIndex: 4)
            Issue.record("Expected continuation limit to throw")
        } catch let error as MinimalHostToolDriverError {
            #expect(error == .continuationLimitExceeded)
        }
    }

    private func toolRequest(argumentsJson: String = #"{"text":"hello"}"#) -> ToolExecutionRequestDTO {
        ToolExecutionRequestDTO(
            runId: "run_1",
            sessionId: "session_1",
            toolCallEntryId: "entry_tool",
            toolCallId: "call_1",
            toolName: "debug.echo",
            argumentsJson: argumentsJson
        )
    }
}
