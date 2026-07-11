import Foundation
import Testing
import LocalAgentLLMContracts
@testable import LocalAgentLLMCore

@Suite("Agent host configuration")
struct AgentHostConfigurationTests {
    @Test
    func immutableRevisionsRoundTripWithOnePinnedTargetRevision() throws {
        let target = LLMTargetRevision(
            targetID: "target.local.gemma",
            revision: 3,
            kind: .local,
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
    }
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}
