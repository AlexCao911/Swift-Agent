import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("OpenMinis provider compatibility")
struct OpenMinisProviderCompatibilityTests {
    @Test
    func antigravityUsesItsCloudCodeEnvelopeAndGeminiStreamSemantics() async throws {
        let fixture = try await makeAuthorizedTransportFixture(
            modelID: "gemini-3-flash",
            systemText: "system sentinel"
        )
        defer { fixture.cleanup() }
        let context = CloudProviderSessionContext(
            targetID: fixture.sessionContext.targetID,
            targetRevision: fixture.sessionContext.targetRevision,
            providerProfileID: fixture.sessionContext.providerProfileID,
            providerProfileRevision: fixture.sessionContext.providerProfileRevision,
            modelID: fixture.sessionContext.modelID,
            retentionMode: fixture.sessionContext.retentionMode,
            retentionApprovalRevision:
                fixture.sessionContext.retentionApprovalRevision,
            retentionApprovalDigest:
                fixture.sessionContext.retentionApprovalDigest,
            hostProcessEpoch: fixture.sessionContext.hostProcessEpoch,
            providerProjectID: "project-sentinel"
        )
        let session = try AntigravityCloudCodeAdapter().makeSession(context)
        let wire = try session.encodeStart(fixture.authorizedTurn)
        let body = try wireJSONObject(wire)
        let inner = try #require(body["request"] as? [String: Any])

        #expect(wire.path == "/v1internal:streamGenerateContent")
        #expect(wire.headers["authorization"] == nil)
        #expect(wire.headers["x-client-name"] == "antigravity")
        #expect(body["model"] as? String == "gemini-3-flash")
        #expect(body["project"] as? String == "project-sentinel")
        #expect(body["userAgent"] as? String == "antigravity")
        #expect(body["requestType"] as? String == "agent")
        #expect((body["requestId"] as? String)?.hasPrefix("agent-") == true)
        #expect((inner["sessionId"] as? String)?.isEmpty == false)

        let response = """
        {"response":{"candidates":[{"content":{"parts":[{"text":"Done"},{"functionCall":{"name":"shell","args":{"command":"pwd"}},"thoughtSignature":"private-signature"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":3}}}
        """
        let events = try await collect(session.decode(AsyncThrowingStream {
            $0.yield(SSEEvent(
                event: nil,
                id: nil,
                retryMilliseconds: nil,
                data: Data(response.utf8)
            ))
            $0.finish()
        }))
        let calls: [NormalizedToolCall] = events.compactMap { event in
            guard case let .toolCallCompleted(call) = event else { return nil }
            return call
        }
        let call = try #require(calls.first)

        #expect(events.contains(.textDelta("Done")))
        #expect(call.name == "shell")
        #expect(call.argumentsJSON == #"{"command":"pwd"}"#)
        #expect(events.contains(.usageUpdated(.init(
            inputTokens: 9,
            outputTokens: 3
        ))))
        #expect(events.last == .generationCompleted(.init(
            outcome: .toolCallsReady,
            orderedCallIDs: [call.callID],
            finishReason: .toolCalls
        )))
    }
}
