import LocalAgentLLMCloud
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentApp

@Suite("Cloud approval broker")
struct AppCloudApprovalBrokerTests {
    @Test
    func serializesPromptsAndDeniesDismissal() async {
        let broker = AppCloudApprovalBroker()
        let origin = EgressOrigin(
            scheme: "https",
            host: "api.example.com",
            port: 443
        )

        async let first = broker.requestOriginApproval(
            origin,
            profileName: "OpenAI"
        )
        await waitForRequestCount(1, broker: broker)
        async let second = broker.requestScopeApproval(
            origin: origin,
            summary: EgressApprovalDisplaySummary(
                disclosureDigest: "disclosure",
                priorScopeGrantDigest: nil,
                sourceSummary: SafeDisplaySummary(
                    sourceKinds: [.conversation],
                    addedItemCounts: [.init(dataClass: .text, count: 1)],
                    approximateAddedSize: .lessThanOneKiB,
                    triggeringToolDisplayKeys: []
                ),
                newlyAddedDataClasses: [.text],
                approvalSummaryDigest: "summary"
            )
        )
        await waitForRequestCount(2, broker: broker)

        #expect(await broker.pendingCount == 1)
        await broker.dismissCurrent()
        #expect(await first == .deny)
        #expect(await broker.pendingCount == 1)
        await broker.respond(.allow)
        #expect(await second == .allow)
        #expect(await broker.pendingCount == 0)
    }
}

private func waitForRequestCount(
    _ expected: Int,
    broker: AppCloudApprovalBroker
) async {
    for _ in 0..<100 where await broker.totalRequestCount < expected {
        await Task.yield()
    }
    #expect(await broker.totalRequestCount == expected)
}
