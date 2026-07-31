import LocalAgentLLMContracts
import LocalAgentLLMCore
import SwiftUI

struct AgentLLMConfigurationView: View {
    @Bindable var viewModel: AgentBuilderViewModel
    @State private var numericInputs: [String: String] = [:]
    @State private var invalidParameters: Set<String> = []

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
        switch definition.valueType {
        case .decimal where bounded(definition):
            VStack(alignment: .leading) {
                LabeledContent(label(for: definition), value: decimalValue(for: definition).formatted())
                Slider(value: decimalBinding(definition), in: definition.minimum!...definition.maximum!)
            }
        case .integer where bounded(definition):
            Stepper(
                "\(label(for: definition)): \(integerValue(for: definition))",
                value: integerBinding(definition),
                in: Int64(definition.minimum!)...Int64(definition.maximum!)
            )
        case .decimal:
            numericField(definition, value: decimalText(for: definition)) { .decimal($0) }
        case .integer:
            numericField(definition, value: integerText(for: definition)) { .integer($0) }
        case .text where !definition.choices.isEmpty:
            Picker(label(for: definition), selection: textBinding(definition)) {
                ForEach(definition.choices.sorted(), id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
        case .text:
            TextField(label(for: definition), text: textBinding(definition))
        case .boolean:
            Toggle(label(for: definition), isOn: boolBinding(definition))
        case .textList:
            TextField(label(for: definition), text: textListBinding(definition), axis: .vertical)
                .lineLimit(2...4)
        }
    }

    @ViewBuilder
    private func numericField<T>(
        _ definition: LLMParameterDefinition,
        value: String,
        makeValue: @escaping (T) -> LLMParameterValue
    ) -> some View where T: LosslessStringConvertible {
        let id = definition.id.rawValue
        TextField(label(for: definition), text: Binding(
            get: { numericInputs[id] ?? value },
            set: { input in
                numericInputs[id] = input
                guard let number = T(input), viewModel.setParameter(definition.id, makeValue(number)) else {
                    invalidParameters.insert(id)
                    return
                }
                invalidParameters.remove(id)
            }
        ))
        .keyboardType(.numbersAndPunctuation)
        .foregroundStyle(invalidParameters.contains(id) ? .red : .primary)
    }

    private func bounded(_ definition: LLMParameterDefinition) -> Bool {
        guard let minimum = definition.minimum, let maximum = definition.maximum else { return false }
        return minimum.isFinite && maximum.isFinite && minimum <= maximum
    }

    private func label(for definition: LLMParameterDefinition) -> String {
        switch definition.id {
        case .samplingTemperature: "Temperature"
        case .samplingTopP: "Top P"
        case .samplingTopK: "Top K"
        case .samplingMinP: "Min P"
        case .samplingRepetitionPenalty: "Repetition Penalty"
        case .generationMaxOutputTokens: "Max Output Tokens"
        case .generationSeed: "Seed"
        case .generationStopSequences: "Stop Sequences"
        case .reasoningEffort: "Reasoning Effort"
        case .reasoningTokenBudget: "Reasoning Token Budget"
        case .outputVerbosity: "Output Verbosity"
        default: definition.id.rawValue.replacingOccurrences(of: ".", with: " ").capitalized
        }
    }

    private func textBinding(_ definition: LLMParameterDefinition) -> Binding<String> {
        Binding(
            get: {
                if case let .text(value) = viewModel.llmSelection?
                    .parameterOverrides.value(for: definition.id) {
                    return value
                }
                if case let .text(value) = defaultValue(for: definition) { return value }
                return definition.choices.sorted().first ?? ""
            },
            set: { _ = viewModel.setParameter(definition.id, .text($0)) }
        )
    }

    private func boolBinding(_ definition: LLMParameterDefinition) -> Binding<Bool> {
        Binding(
            get: {
                if case let .boolean(value) = viewModel.llmSelection?
                    .parameterOverrides.value(for: definition.id) {
                    return value
                }
                if case let .boolean(value) = defaultValue(for: definition) { return value }
                return false
            },
            set: { _ = viewModel.setParameter(definition.id, .boolean($0)) }
        )
    }

    private func decimalBinding(_ definition: LLMParameterDefinition) -> Binding<Double> {
        Binding(get: { decimalValue(for: definition) }, set: { _ = viewModel.setParameter(definition.id, .decimal($0)) })
    }

    private func integerBinding(_ definition: LLMParameterDefinition) -> Binding<Int64> {
        Binding(get: { integerValue(for: definition) }, set: { _ = viewModel.setParameter(definition.id, .integer($0)) })
    }

    private func textListBinding(_ definition: LLMParameterDefinition) -> Binding<String> {
        Binding(
            get: { textListValue(for: definition).joined(separator: ", ") },
            set: { input in
                let values = input.split(whereSeparator: { $0 == "," || $0.isNewline }).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                _ = viewModel.setParameter(definition.id, .textList(values))
            }
        )
    }

    private func defaultValue(for definition: LLMParameterDefinition) -> LLMParameterValue? {
        selectedOption?.target.defaultParameters.value(for: definition.id)
    }

    private func decimalValue(for definition: LLMParameterDefinition) -> Double {
        if case let .decimal(value) = viewModel.llmSelection?.parameterOverrides.value(for: definition.id) ?? defaultValue(for: definition) { return value }
        return definition.minimum ?? 0
    }

    private func integerValue(for definition: LLMParameterDefinition) -> Int64 {
        if case let .integer(value) = viewModel.llmSelection?.parameterOverrides.value(for: definition.id) ?? defaultValue(for: definition) { return value }
        return Int64(definition.minimum ?? 0)
    }

    private func decimalText(for definition: LLMParameterDefinition) -> String {
        if case let .decimal(value) = viewModel.llmSelection?.parameterOverrides.value(for: definition.id) ?? defaultValue(for: definition) { return String(value) }
        return ""
    }

    private func integerText(for definition: LLMParameterDefinition) -> String {
        if case let .integer(value) = viewModel.llmSelection?.parameterOverrides.value(for: definition.id) ?? defaultValue(for: definition) { return String(value) }
        return ""
    }

    private func textListValue(for definition: LLMParameterDefinition) -> [String] {
        if case let .textList(value) = viewModel.llmSelection?.parameterOverrides.value(for: definition.id) ?? defaultValue(for: definition) { return value }
        return []
    }
}
