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
                            .tag(targetKey(option.target.reference))
                    }
                }
                .pickerStyle(.menu)

                fallbackConfiguration

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

    @ViewBuilder
    private var fallbackConfiguration: some View {
        if let selection = viewModel.llmSelection {
            ForEach(
                Array(selection.fallbackCandidates.enumerated()),
                id: \.element.target.targetID.rawValue
            ) { index, candidate in
                HStack {
                    Text("\(index + 1). \(targetName(candidate.target))")
                    Spacer()
                    Button {
                        viewModel.moveFallbackTarget(
                            candidate.target,
                            direction: -1
                        )
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(index == 0)
                    Button {
                        viewModel.moveFallbackTarget(
                            candidate.target,
                            direction: 1
                        )
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .disabled(index == selection.fallbackCandidates.count - 1)
                    Button(role: .destructive) {
                        viewModel.removeFallbackTarget(candidate.target)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                }
                .buttonStyle(.borderless)
            }

            let availableFallbacks = viewModel.llmTargets.filter { option in
                option.target.reference != selection.target
                    && !selection.fallbackCandidates.contains(where: {
                        $0.target == option.target.reference
                    })
            }
            if !availableFallbacks.isEmpty {
                Menu {
                    ForEach(
                        availableFallbacks,
                        id: \.target.targetID.rawValue
                    ) { option in
                        Button(option.target.modelID) {
                            viewModel.addFallbackTarget(
                                option.target.reference
                            )
                        }
                    }
                } label: {
                    Label("Add Fallback", systemImage: "plus.circle")
                }
            }
        }
    }

    private var selectedOption: AgentLLMTargetOption? {
        guard let reference = viewModel.llmSelection?.target else { return nil }
        return viewModel.llmTargets.first { $0.target.reference == reference }
    }

    private var targetBinding: Binding<String> {
        Binding(
            get: {
                targetKey(
                    viewModel.llmSelection?.target
                        ?? viewModel.llmTargets[0].target.reference
                )
            },
            set: { key in
                guard let target = viewModel.llmTargets.first(where: {
                    targetKey($0.target.reference) == key
                }) else {
                    return
                }
                viewModel.selectTarget(target.target.reference)
            }
        )
    }

    private func targetKey(_ reference: LLMTargetReference) -> String {
        "\(reference.targetID.rawValue)#\(reference.revision)"
    }

    private func targetName(_ reference: LLMTargetReference) -> String {
        viewModel.llmTargets.first {
            $0.target.reference == reference
        }?.target.modelID ?? reference.targetID.rawValue
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
