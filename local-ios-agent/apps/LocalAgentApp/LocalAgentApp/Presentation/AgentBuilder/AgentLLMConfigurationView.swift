import LocalAgentLLMContracts
import LocalAgentLLMCore
import SwiftUI

struct AgentLLMConfigurationView: View {
    @Bindable var viewModel: AgentBuilderViewModel

    var body: some View {
        GroupBox("LLM") {
            if viewModel.llmTargets.isEmpty {
                ContentUnavailableView(
                    "No LLM Target",
                    systemImage: "cpu",
                    description: Text("Create a local or cloud target in Model Center first.")
                )
            } else {
                Picker("Target", selection: targetBinding) {
                    ForEach(viewModel.llmTargets, id: \.target.targetID.rawValue) { option in
                        Text(option.target.modelID)
                            .tag(option.target.reference)
                    }
                }
                .pickerStyle(.menu)

                if let selected = selectedOption {
                    ForEach(
                        selected.parameterSchema.definitions.values
                            .filter { $0.support == .supported }
                            .sorted { $0.id.rawValue < $1.id.rawValue },
                        id: \.id.rawValue
                    ) { definition in
                        parameterControl(definition)
                    }
                }
            }
        }
    }

    private var selectedOption: AgentLLMTargetOption? {
        guard let reference = viewModel.llmSelection?.target else { return nil }
        return viewModel.llmTargets.first { $0.target.reference == reference }
    }

    private var targetBinding: Binding<LLMTargetReference> {
        Binding(
            get: {
                viewModel.llmSelection?.target
                    ?? viewModel.llmTargets[0].target.reference
            },
            set: viewModel.selectTarget
        )
    }

    @ViewBuilder
    private func parameterControl(_ definition: LLMParameterDefinition) -> some View {
        if !definition.choices.isEmpty {
            Picker(definition.id.rawValue, selection: textBinding(definition)) {
                ForEach(definition.choices.sorted(), id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
        } else if definition.valueType == .boolean {
            Toggle(definition.id.rawValue, isOn: boolBinding(definition))
        } else {
            Text(definition.id.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func textBinding(_ definition: LLMParameterDefinition) -> Binding<String> {
        Binding(
            get: {
                if case let .text(value) = viewModel.llmSelection?
                    .parameterOverrides.value(for: definition.id) {
                    return value
                }
                return definition.choices.sorted().first ?? ""
            },
            set: { viewModel.setParameter(definition.id, .text($0)) }
        )
    }

    private func boolBinding(_ definition: LLMParameterDefinition) -> Binding<Bool> {
        Binding(
            get: {
                if case let .boolean(value) = viewModel.llmSelection?
                    .parameterOverrides.value(for: definition.id) {
                    return value
                }
                return false
            },
            set: { viewModel.setParameter(definition.id, .boolean($0)) }
        )
    }
}
