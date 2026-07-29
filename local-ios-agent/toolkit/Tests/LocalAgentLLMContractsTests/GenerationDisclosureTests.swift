import Foundation
import Testing
@testable import LocalAgentLLMContracts

@Suite("Generation disclosure contracts")
struct GenerationDisclosureTests {
    @Test
    func disclosureDigestBindsTurnContentSourcesAndSafeSummary() throws {
        let disclosure = fixtureDisclosure()

        let digest = try disclosure.computedDigest()
        let expected = try fixtureDigest("generation-disclosure-cloud-v1.json")

        #expect(digest.hex == expected)
    }

    @Test
    func unorderedSetsProduceOneStableDigestAndNoRawValues() throws {
        let first = fixtureDisclosure(
            dataClasses: [.text, .contacts],
            sourceKinds: [.conversation, .toolResult],
            triggeringToolDisplayKeys: ["contacts.search", "calendar.search"]
        )
        let second = fixtureDisclosure(
            dataClasses: [.contacts, .text],
            sourceKinds: [.toolResult, .conversation],
            triggeringToolDisplayKeys: ["calendar.search", "contacts.search"]
        )

        #expect(try first.computedDigest() == second.computedDigest())

        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(!encoded.contains("Alice Example"))
        #expect(!encoded.contains("/private/contacts.sqlite"))
        #expect(!encoded.contains("raw tool output"))
    }

    @Test
    func normalizedToolResultRoundTripsWithoutWeakeningLabels() throws {
        let result = NormalizedToolResult(
            callID: "call-contacts",
            toolName: "contacts.search",
            result: try CanonicalJSONValue.object(entries: [
                .init(name: "count", value: .number(2)),
            ]),
            isError: false,
            dataClasses: [.contacts, .toolResult],
            highestSensitivity: .sensitive
        )

        let decoded = try JSONDecoder().decode(
            NormalizedToolResult.self,
            from: JSONEncoder().encode(result)
        )

        #expect(decoded == result)
        #expect(decoded.dataClasses == Set([.contacts, .toolResult]))
        #expect(decoded.highestSensitivity == .sensitive)
    }

    @Test
    func missingToolResultLabelsNormalizeToUnknown() {
        let result = NormalizedToolResult(
            callID: "call-unlabelled",
            toolName: "fixture.unlabelled",
            result: .null,
            isError: false,
            dataClasses: [],
            highestSensitivity: .routine
        )

        #expect(result.dataClasses == [.unknownData])
        #expect(result.highestSensitivity == .unknown)
    }

    @Test
    func malformedBindingDigestsAndDuplicateCountsFailClosed() {
        var malformed = fixtureDisclosure()
        malformed = GenerationDisclosure(
            schemaVersion: malformed.schemaVersion,
            generationTurnID: malformed.generationTurnID,
            contentDigest: String(repeating: "A", count: 64),
            sourceRevisionDigest: malformed.sourceRevisionDigest,
            dataClasses: malformed.dataClasses,
            highestSensitivity: malformed.highestSensitivity,
            safeDisplaySummary: malformed.safeDisplaySummary
        )
        #expect(throws: GenerationDisclosureError.self) {
            try malformed.computedDigest()
        }

        let duplicateCounts = GenerationDisclosure(
            schemaVersion: "1",
            generationTurnID: "turn-2",
            contentDigest: String(repeating: "a", count: 64),
            sourceRevisionDigest: String(repeating: "b", count: 64),
            dataClasses: [.text, .contacts],
            highestSensitivity: .sensitive,
            safeDisplaySummary: SafeDisplaySummary(
                sourceKinds: [.conversation],
                addedItemCounts: [
                    .init(dataClass: .contacts, count: 1),
                    .init(dataClass: .contacts, count: 2),
                ],
                approximateAddedSize: .lessThanOneKiB,
                triggeringToolDisplayKeys: []
            )
        )
        #expect(throws: GenerationDisclosureError.self) {
            try duplicateCounts.computedDigest()
        }

        let unlabelled = GenerationDisclosure(
            schemaVersion: "1",
            generationTurnID: "turn-2",
            contentDigest: String(repeating: "a", count: 64),
            sourceRevisionDigest: String(repeating: "b", count: 64),
            dataClasses: [],
            highestSensitivity: .routine,
            safeDisplaySummary: .init(
                sourceKinds: [.conversation],
                addedItemCounts: [],
                approximateAddedSize: .lessThanOneKiB,
                triggeringToolDisplayKeys: []
            )
        )
        #expect(throws: GenerationDisclosureError.self) {
            try unlabelled.computedDigest()
        }
    }

    @Test
    func sensitivityOrderIsConservative() {
        #expect(DataSensitivity.routine < .private)
        #expect(DataSensitivity.private < .sensitive)
        #expect(DataSensitivity.sensitive < .highlySensitive)
        #expect(DataSensitivity.highlySensitive < .unknown)
    }

    @Test
    func agentConfigurationSourceMatchesRustDisclosureContract() throws {
        let encoded = Data(#""agent_configuration""#.utf8)

        #expect(
            try JSONDecoder().decode(EgressSourceKind.self, from: encoded)
                == .agentConfiguration
        )
    }

    @Test
    func backendContractExposesOnlyReasoningSummaryDelta() {
        let event = LLMBackendEvent.reasoningSummaryDelta("short user-visible summary")

        #expect(event == .reasoningSummaryDelta("short user-visible summary"))
    }
}

private func fixtureDisclosure(
    dataClasses: Set<EgressDataClass> = [.text, .contacts],
    sourceKinds: Set<EgressSourceKind> = [.conversation, .toolResult],
    triggeringToolDisplayKeys: Set<String> = ["contacts.search"]
) -> GenerationDisclosure {
    GenerationDisclosure(
        schemaVersion: "1",
        generationTurnID: "turn-2",
        contentDigest: String(repeating: "a", count: 64),
        sourceRevisionDigest: String(repeating: "b", count: 64),
        dataClasses: dataClasses,
        highestSensitivity: .sensitive,
        safeDisplaySummary: SafeDisplaySummary(
            sourceKinds: sourceKinds,
            addedItemCounts: [
                EgressDataClassCount(dataClass: .contacts, count: 2),
            ],
            approximateAddedSize: .lessThanOneKiB,
            triggeringToolDisplayKeys: triggeringToolDisplayKeys
        )
    )
}

private func fixtureDigest(_ name: String) throws -> String {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("contracts/canonical-digest-v1/fixtures/\(name)")
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
    )
    return try #require(object["expected_sha256"] as? String)
}
