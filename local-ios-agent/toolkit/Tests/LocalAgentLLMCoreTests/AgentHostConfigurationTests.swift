import Foundation
import Testing
import LocalAgentLLMContracts
@testable import LocalAgentLLMCore

@Suite("Agent host configuration")
struct AgentHostConfigurationTests {
    @Test
    func immutableRevisionsRoundTripWithOnePinnedTargetRevision() throws {
        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target.local.gemma"),
            revision: 3,
            kind: .local(installationID: "installation.gemma.1"),
            modelID: "gemma-3-4b-it",
            defaultParameters: GenerationConfiguration()
                .setting(.samplingTemperature, to: .decimal(0.6))
        )
        let binding = AgentHostConfiguration(
            bindingID: "binding.agent.writer",
            revision: 7,
            agentProfileID: "profile.writer",
            agentProfileRevision: 11,
            llmSlotID: "slot.model.primary",
            requirementsHash: "requirements-digest",
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            parameterOverrides: GenerationConfiguration()
                .setting(.samplingTopP, to: .decimal(0.9))
        )

        let targetCopy = try roundTrip(target)
        let bindingCopy = try roundTrip(binding)

        #expect(targetCopy == target)
        #expect(bindingCopy == binding)
        #expect(bindingCopy.selectedTarget == LLMTargetReference(targetID: target.targetID, revision: 3))

        let bindingObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any]
        )
        #expect(bindingObject["llmTargetID"] as? String == "target.local.gemma")
        let bindingDigest = try agentHostConfigurationDigest(binding)
        #expect(bindingDigest == "93490d53da293dc4afa5512669e00abfae62594ca859e18d1e67897810880689")
    }

    @Test
    func targetKindUsesVersionedIdentityPayloadAndRejectsUnknownVersions() throws {
        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target.cloud.primary"),
            revision: 9,
            kind: .cloud(providerProfileID: "provider.openai", providerProfileRevision: 4),
            modelID: "gpt-example",
            defaultParameters: GenerationConfiguration()
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any]
        )
        let kind = try #require(object["kind"] as? [String: Any])
        let payload = try #require(kind["payload"] as? [String: Any])
        #expect(kind["kind"] as? String == "cloud")
        #expect(payload["schema_version"] as? String == "1")
        #expect(payload["provider_profile_id"] as? String == "provider.openai")
        #expect(payload["provider_profile_revision"] as? String == "4")

        let unsupported = Data("""
        {"kind":{"kind":"local","payload":{"schema_version":"2","installation_id":"i"}},"targetID":"t","revision":1,"modelID":"m","defaultParameters":{"parameters":{}}}
        """.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LLMTargetRevision.self, from: unsupported)
        }
    }
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}
