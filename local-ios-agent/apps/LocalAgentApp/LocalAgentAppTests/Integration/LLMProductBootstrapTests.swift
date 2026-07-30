import LocalAgentLLMContracts
import LocalAgentLLMCloud
import LocalAgentLLMCore
import LocalAgentLLMLocal
import Testing
@testable import LocalAgentApp

@Suite("LLM product bootstrap")
struct LLMProductBootstrapTests {
    @Test("hydration installs only an exact available target")
    func hydratesExactActiveBinding() async throws {
        let target = fixtureTarget()
        let binding = fixtureBinding(target: target)
        let registry = AppLLMHostSelectionRegistry()

        let issues = await registry.hydrate(
            bindings: [binding],
            targets: [target],
            available: [
                AgentLLMTargetOption(
                    target: target,
                    parameterSchema: LLMParameterSchema(definitions: [])
                ),
            ]
        )

        #expect(issues.isEmpty)
        #expect(await registry.count == 1)
        #expect(await registry.selection(
            profileID: binding.configuration.agentProfileID,
            revision: binding.configuration.agentProfileRevision
        ) != nil)
    }

    @Test("hydration preserves the ordered fallback bindings for one model slot")
    func hydratesOrderedFallbackBindings() async throws {
        let primaryTarget = fixtureTarget()
        let fallbackTarget = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target.fallback"),
            revision: 1,
            kind: .local(installationID: "installation.fallback"),
            modelID: "model.fallback",
            defaultParameters: GenerationConfiguration()
        )
        let primary = fixtureBinding(target: primaryTarget)
        let fallback = fixtureBinding(
            target: fallbackTarget,
            bindingID: "binding.fallback"
        )
        let registry = AppLLMHostSelectionRegistry()

        let issues = await registry.hydrate(
            bindings: [fallback, primary],
            targets: [fallbackTarget, primaryTarget],
            available: [primaryTarget, fallbackTarget].map {
                AgentLLMTargetOption(
                    target: $0,
                    parameterSchema: LLMParameterSchema(definitions: [])
                )
            }
        )

        #expect(issues.isEmpty)
        let group = await registry.selectionGroup(
            profileID: primary.configuration.agentProfileID,
            revision: primary.configuration.agentProfileRevision
        )
        #expect(group?.map(\.binding.bindingID) == [
            "binding.bootstrap",
            "binding.fallback",
        ])
    }

    @Test("hydration never substitutes a missing target")
    func missingTargetStaysUnconfigured() async throws {
        let target = fixtureTarget()
        let registry = AppLLMHostSelectionRegistry()

        let issues = await registry.hydrate(
            bindings: [fixtureBinding(target: target)],
            targets: [],
            available: []
        )

        #expect(await registry.count == 0)
        #expect(issues == ["execution.host_binding_not_configured"])
    }

    @Test("hydration rejects a target unavailable to its current subsystem")
    func unavailableTargetStaysUnconfigured() async throws {
        let target = fixtureTarget()
        let registry = AppLLMHostSelectionRegistry()

        let issues = await registry.hydrate(
            bindings: [fixtureBinding(target: target)],
            targets: [target],
            available: []
        )

        #expect(await registry.count == 0)
        #expect(issues == ["execution.host_binding_not_configured"])
    }

    @Test("hydration isolates unsupported parameters")
    func unsupportedParametersStayUnconfigured() async throws {
        let target = fixtureTarget()
        let invalid = ActiveAgentHostBinding(
            configuration: AgentHostConfiguration(
                bindingID: "binding.bootstrap",
                revision: 2,
                agentProfileID: "profile.bootstrap",
                agentProfileRevision: 7,
                llmSlotID: "slot.model.primary",
                requirementsHash: "requirements.bootstrap",
                llmTargetID: target.targetID,
                llmTargetRevision: target.revision,
                parameterOverrides: GenerationConfiguration().setting(
                    .samplingTemperature,
                    to: .decimal(0.5)
                )
            ),
            binding: HostBindingTuple(
                bindingID: "binding.bootstrap",
                bindingRevision: 2,
                bindingHash: "binding-hash.bootstrap"
            )
        )
        let registry = AppLLMHostSelectionRegistry()

        let issues = await registry.hydrate(
            bindings: [invalid],
            targets: [target],
            available: [
                AgentLLMTargetOption(
                    target: target,
                    parameterSchema: LLMParameterSchema(definitions: [])
                ),
            ]
        )

        #expect(await registry.count == 0)
        #expect(issues == ["execution.host_binding_not_configured"])
    }

    @Test("availability requires an installed local model or current cloud validation")
    func targetAvailabilityFailsClosed() {
        let localTarget = fixtureTarget()
        let cloudTarget = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target.cloud"),
            revision: 1,
            kind: .cloud(providerProfileID: "provider", providerProfileRevision: 2),
            modelID: "cloud-model",
            defaultParameters: GenerationConfiguration()
        )
        let localRevision = LocalModelRevisionID(
            modelID: localTarget.modelID,
            revision: 1
        )
        let state = ModelCenterSnapshot(
            localModels: [
                LocalModelCenterState(
                    modelRevision: localRevision,
                    displayName: "Local",
                    requiredBytes: 1,
                    parameterSchema: LLMParameterSchema(definitions: []),
                    parameterDefaults: GenerationConfiguration(),
                    installation: LocalModelProductState(
                        installationID: "installation.bootstrap",
                        modelRevision: localRevision,
                        state: .paused,
                        receivedBytes: 1,
                        expectedBytes: 1,
                        installedBytes: 0,
                        requiredBytes: 1,
                        repairAction: .resume
                    )
                ),
            ],
            cloudProviders: [],
            cloudModels: [
                CloudModelProductState(
                    profileID: "provider",
                    profileRevision: 2,
                    modelID: cloudTarget.modelID,
                    modelRevision: nil,
                    capabilities: CapabilitySnapshot(capabilities: [:]),
                    parameterSchema: LLMParameterSchema(definitions: []),
                    validation: .stale
                ),
            ],
            targets: [localTarget, cloudTarget],
            disk: nil
        )

        #expect(AppModelCenterClient.availableTargetOptions(in: state).isEmpty)
    }
}

private func fixtureTarget() -> LLMTargetRevision {
    LLMTargetRevision(
        targetID: LLMTargetID(rawValue: "target.bootstrap"),
        revision: 3,
        kind: .local(installationID: "installation.bootstrap"),
        modelID: "model.bootstrap",
        defaultParameters: GenerationConfiguration()
    )
}

private func fixtureBinding(
    target: LLMTargetRevision,
    bindingID: String = "binding.bootstrap"
) -> ActiveAgentHostBinding {
    ActiveAgentHostBinding(
        configuration: AgentHostConfiguration(
            bindingID: bindingID,
            revision: 2,
            agentProfileID: "profile.bootstrap",
            agentProfileRevision: 7,
            llmSlotID: "slot.model.primary",
            requirementsHash: "requirements.bootstrap",
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            parameterOverrides: GenerationConfiguration()
        ),
        binding: HostBindingTuple(
            bindingID: bindingID,
            bindingRevision: 2,
            bindingHash: "binding-hash.bootstrap"
        )
    )
}
