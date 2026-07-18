import Foundation
import Darwin
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore

@main
struct CloudProviderLiveSmoke {
    static func main() async {
        do {
            try await run()
            print("Cloud provider live smoke passed")
        } catch let failure as LLMFailure {
            writeError("Cloud provider live smoke failed: \(failure.code)")
            exit(1)
        } catch {
            writeError("Cloud provider live smoke failed without provider diagnostics")
            exit(1)
        }
    }

    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let profileID = try required(
            "LOCAL_AGENT_CLOUD_SMOKE_PROVIDER_PROFILE_ID",
            environment: environment
        )
        let revisionText = try required(
            "LOCAL_AGENT_CLOUD_SMOKE_PROVIDER_PROFILE_REVISION",
            environment: environment
        )
        let modelID = try required(
            "LOCAL_AGENT_CLOUD_SMOKE_MODEL_ID",
            environment: environment
        )
        let credentialRef = try required(
            "LOCAL_AGENT_CLOUD_SMOKE_CREDENTIAL_REF",
            environment: environment
        )
        let hostProcessEpochText = try required(
            "LOCAL_AGENT_CLOUD_SMOKE_HOST_PROCESS_EPOCH",
            environment: environment
        )
        guard let hostProcessEpoch = HostProcessEpoch(rawValue: hostProcessEpochText) else {
            throw smokeFailure("live_smoke.host_process_epoch_invalid")
        }
        guard let profileRevision = UInt64(revisionText), profileRevision > 0 else {
            throw smokeFailure("live_smoke.profile_revision_invalid")
        }
        let appSupportRoot = environment["LOCAL_AGENT_CLOUD_SMOKE_APP_SUPPORT_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
        let subsystem = try await CloudLLMSubsystem.bootstrap(
            appSupportRoot: appSupportRoot,
            hostProcessEpoch: hostProcessEpoch,
            remoteCatalog: nil,
            approvalPrompt: SyntheticSmokeApprovalPrompt(),
            localUnloader: SmokeLocalUnloader()
        )
        guard let profile = await subsystem.profiles.profile(
            profileID: profileID,
            revision: profileRevision
        ),
            profile.lifecycle == .active,
            profile.revision.credentialRef == credentialRef
        else {
            throw smokeFailure("live_smoke.profile_not_found")
        }
        let validation = try await subsystem.validation.validate(
            profileID: profileID,
            profileRevision: profileRevision,
            modelID: modelID,
            adapterVersion: "1"
        )
        guard validation.snapshot.support(for: "text_generation") == .supported,
              let catalog = try await subsystem.catalog.current(),
              let entry = catalog.entry(
                  presetID: profile.revision.presetID,
                  modelID: modelID
              )
        else {
            throw smokeFailure("live_smoke.model_not_runnable")
        }

        let operationID = UUID().uuidString.lowercased()
        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "live-smoke-\(operationID)"),
            revision: 1,
            kind: .cloud(
                providerProfileID: profileID,
                providerProfileRevision: profileRevision
            ),
            modelID: modelID,
            defaultParameters: GenerationConfiguration()
        )
        try await subsystem.profiles.publishTarget(target)
        let configuration = AgentHostConfiguration(
            bindingID: "live-smoke-binding-\(operationID)",
            revision: 1,
            agentProfileID: "live-smoke-synthetic-agent",
            agentProfileRevision: 1,
            llmSlotID: "live-smoke",
            requirementsHash: String(repeating: "a", count: 64),
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            parameterOverrides: GenerationConfiguration()
        )
        let saga = AgentHostBindingSaga(store: subsystem.bindingStore)
        let receipt = try await saga.stageHostBinding(HostBindingStageRequest(
            operationToken: operationID,
            tokenDigest: "live-smoke-token-\(operationID)",
            llmSlotID: configuration.llmSlotID,
            requirementsHash: configuration.requirementsHash,
            configuration: configuration
        ))
        try await saga.activateHostBinding(
            operationToken: operationID,
            binding: receipt.binding
        )
        let resolved = try CloudGenerationConfigurationResolver.resolve(entry: entry)
        let turn = try syntheticTurn(parameters: resolved.semantic, operationID: operationID)
        let prepared = try await subsystem.runtime.prepareSession(
            context: CloudSessionPreparationContext(
                preparationID: "live-smoke-preparation-\(operationID)",
                proposedRunID: "live-smoke-run-\(operationID)",
                initialTurn: turn,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: configuration,
            target: target
        )
        do {
            var sawText = false
            var sawFinal = false
            let stream = try await subsystem.runtime.startGeneration(
                sessionID: prepared.sessionID,
                turn: turn
            )
            for try await event in stream {
                switch event {
                case let .textDelta(text): sawText = sawText || !text.isEmpty
                case let .generationCompleted(completion):
                    sawFinal = completion.outcome == .finalResponse
                default: break
                }
            }
            guard sawText, sawFinal else {
                throw smokeFailure("live_smoke.terminal_invalid")
            }
            try await subsystem.runtime.closeSession(sessionID: prepared.sessionID)
        } catch {
            try? await subsystem.runtime.closeSession(sessionID: prepared.sessionID)
            throw error
        }
    }

    private static func syntheticTurn(
        parameters: GenerationConfiguration,
        operationID: String
    ) throws -> CloudGenerationTurnRequest {
        let input = AgentLLMInput(
            inputID: "live-smoke-input-\(operationID)",
            messages: [.init(
                role: .user,
                content: [.text("Reply with exactly OK.")]
            )]
        )
        let toolSchema = try CanonicalJSONValue.object(entries: [
            .init(name: "tools", value: .array([])),
        ])
        let sourceRevisions = try CanonicalJSONValue.object(entries: [])
        let contentDocument = try CanonicalJSONValue.object(entries: [
            .init(name: "canonical_tool_schema", value: toolSchema),
            .init(name: "input_id", value: .string(input.inputID)),
            .init(name: "messages", value: .array([
                try .object(entries: [
                    .init(name: "content", value: .array([
                        try .object(entries: [
                            .init(name: "text", value: .string("Reply with exactly OK.")),
                            .init(name: "type", value: .string("text")),
                        ]),
                    ])),
                    .init(name: "role", value: .string("user")),
                ]),
            ])),
            .init(name: "provider_required_semantic_history", value: .array([])),
            .init(name: "resolved_attachments", value: .array([])),
            .init(name: "schema_version", value: .string("1")),
            .init(name: "tool_results", value: .array([])),
        ])
        let sourceDocument = try CanonicalJSONValue.object(entries: [
            .init(name: "resolved_attachments", value: .array([])),
            .init(name: "schema_version", value: .string("1")),
            .init(name: "source_revision_document", value: sourceRevisions),
        ])
        let disclosure = GenerationDisclosure(
            schemaVersion: "1",
            generationTurnID: "live-smoke-turn-\(operationID)",
            contentDigest: try CanonicalDigestV1.digest(
                domain: "agent-input:v1",
                document: contentDocument
            ).hex,
            sourceRevisionDigest: try CanonicalDigestV1.digest(
                domain: "source-revisions:v1",
                document: sourceDocument
            ).hex,
            dataClasses: [.text],
            highestSensitivity: .routine,
            safeDisplaySummary: SafeDisplaySummary(
                sourceKinds: [.conversation],
                addedItemCounts: [.init(dataClass: .text, count: 1)],
                approximateAddedSize: .lessThanOneKiB,
                triggeringToolDisplayKeys: []
            )
        )
        return CloudGenerationTurnRequest(
            input: input,
            canonicalToolSchema: toolSchema,
            sourceRevisionDocument: sourceRevisions,
            toolResults: [],
            providerRequiredSemanticHistory: .array([]),
            disclosure: disclosure,
            resolvedParameters: parameters
        )
    }

    private static func required(
        _ name: String,
        environment: [String: String]
    ) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
            throw smokeFailure("live_smoke.environment_invalid")
        }
        return value
    }
}

private actor SyntheticSmokeApprovalPrompt: CloudLLMApprovalPrompting {
    func requestOriginApproval(
        _ origin: EgressOrigin,
        profileName: String
    ) async -> EgressDecision { .allow }

    func requestScopeApproval(
        origin: EgressOrigin,
        summary: EgressApprovalDisplaySummary
    ) async -> EgressDecision { .allow }

    func requestProviderStateApproval(
        profileName: String,
        origin: EgressOrigin,
        disclosure: ProviderRetentionDisclosure
    ) async -> EgressDecision { .deny }
}

private struct SmokeLocalUnloader: LocalRouteUnloading {
    func unloadForCloudRouteSwitch() async throws {}
}

private func smokeFailure(_ code: String) -> LLMFailure {
    LLMFailure(code: code, message: "live smoke failed", retryable: false)
}

private func writeError(_ text: String) {
    FileHandle.standardError.write(Data("\(text)\n".utf8))
}
