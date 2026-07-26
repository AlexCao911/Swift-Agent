import LocalAgentBridge
import Testing
@testable import LocalAgentLLMHost

@Suite("LLM host product path")
struct LLMHostProductPathTests {
    @Test
    func legacyV1UsesOnlyLegacyStart() async throws {
        let routes = RouteClientFake(schema: .legacyV1)
        let legacy = RunStarterFake(result: RunHandleDTO(runId: "legacy"))
        let host = RunStarterFake(result: RunHandleDTO(runId: "host"))
        let router = LLMProductRunRouter(routes: routes, legacy: legacy, host: host)

        let result = try await router.start(request())

        #expect(result.runId == "legacy")
        #expect(await legacy.count() == 1)
        #expect(await host.count() == 0)
    }

    @Test
    func hostSlotV2NeverInvokesLegacyStart() async throws {
        let routes = RouteClientFake(schema: .hostSlotV2)
        let legacy = RunStarterFake(result: RunHandleDTO(runId: "legacy"))
        let host = RunStarterFake(result: RunHandleDTO(runId: "host"))
        let router = LLMProductRunRouter(
            routes: routes,
            legacy: legacy,
            host: host
        )

        let result = try await router.start(request())

        #expect(result.runId == "host")
        #expect(await legacy.count() == 0)
        #expect(await host.count() == 1)
    }

    @Test
    func staleRouteFailsClosedWithoutFallback() async throws {
        let routes = RouteClientFake(schema: .hostSlotV2, revisionOffset: 1)
        let legacy = RunStarterFake(result: RunHandleDTO(runId: "legacy"))
        let host = RunStarterFake(result: RunHandleDTO(runId: "host"))
        let router = LLMProductRunRouter(
            routes: routes,
            legacy: legacy,
            host: host
        )

        await #expect(throws: LLMHostFailure.self) {
            try await router.start(request())
        }
        #expect(await legacy.count() == 0)
        #expect(await host.count() == 0)
    }

    private func request() -> StartExecutionRequestDTO {
        StartExecutionRequestDTO(
            agentProfileId: "profile-v2",
            profileRevisionId: 7,
            userIntent: "hello",
            conversationRunFrameRef: ConversationRunFrameRefDTO(
                frameId: "frame-1",
                sessionId: "session-1",
                branchHeadId: "turn-1",
                userTurnId: "turn-1"
            )
        )
    }
}

private actor RouteClientFake: ProfileExecutionRouteClient {
    let schema: LLMBindingSchemaDTO
    let revisionOffset: UInt64

    init(schema: LLMBindingSchemaDTO, revisionOffset: UInt64 = 0) {
        self.schema = schema
        self.revisionOffset = revisionOffset
    }

    func profileExecutionRoute(
        profileID: String,
        profileRevision: UInt64
    ) async throws -> ProfileExecutionRouteDTO {
        try ProfileExecutionRouteDTO(
            profileID: profileID,
            profileRevision: profileRevision + revisionOffset,
            llmBindingSchema: schema
        )
    }
}

private actor RunStarterFake: LLMProductRunStarting {
    let result: RunHandleDTO
    private var calls = 0

    init(result: RunHandleDTO) {
        self.result = result
    }

    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        calls += 1
        return result
    }

    func count() -> Int { calls }
}
