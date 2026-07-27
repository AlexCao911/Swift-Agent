import LocalAgentLLMContracts
import LocalAgentLLMLocal
import SwiftUI

struct ModelCenterView: View {
    @Bindable var viewModel: ModelCenterViewModel
    @State private var editor: ProviderEditorPresentation?
    @State private var manualModelIDs: [String: String] = [:]

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            diskSection
            localSection
            cloudSection
            parameterSection
            targetSection
        }
        .navigationTitle("Models")
        .toolbar {
            Button {
                editor = ProviderEditorPresentation(provider: nil)
            } label: {
                Label("Add Provider", systemImage: "plus")
            }
        }
        .task { await viewModel.reload() }
        .task { await viewModel.observeUpdates() }
        .sheet(item: $editor) { presentation in
            if let editorViewModel = viewModel.makeProviderEditor() {
                ProviderProfileEditorView(
                    viewModel: editorViewModel,
                    existingProfile: presentation.provider
                ) {
                    editor = nil
                    Task { await viewModel.reload() }
                }
            }
        }
    }

    @ViewBuilder
    private var diskSection: some View {
        if let disk = viewModel.snapshot.disk {
            Section("Device Storage") {
                LabeledContent(
                    "Available",
                    value: byteCount(disk.availableImportantUsageBytes)
                )
                LabeledContent("Models", value: byteCount(disk.installedBytes))
                LabeledContent("Reserved", value: byteCount(disk.reservedBytes))
            }
        }
    }

    private var localSection: some View {
        Section("Official Local Models") {
            if viewModel.snapshot.localModels.isEmpty {
                Text("No compatible official models are available.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.snapshot.localModels) { model in
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.displayName).font(.headline)
                    Text("\(model.modelRevision.modelID) · \(byteCount(model.requiredBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let installation = model.installation {
                        Text(installation.state.rawValue.capitalized)
                            .font(.caption)
                        if installation.expectedBytes > 0,
                           installation.receivedBytes < installation.expectedBytes {
                            ProgressView(
                                value: Double(installation.receivedBytes),
                                total: Double(installation.expectedBytes)
                            )
                        }
                        localActions(model, installation: installation)
                    } else {
                        Button("Download") {
                            perform { try await viewModel.enqueueLocalModel(model.modelRevision) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func localActions(
        _ model: LocalModelCenterState,
        installation: LocalModelProductState
    ) -> some View {
        HStack {
            switch installation.state {
            case .downloading, .queued, .verifying:
                Button("Pause") {
                    perform {
                        try await viewModel.pauseLocalModel(
                            installationID: installation.installationID
                        )
                    }
                }
                Button("Cancel", role: .destructive) {
                    perform {
                        try await viewModel.cancelLocalModel(
                            installationID: installation.installationID
                        )
                    }
                }
            case .paused, .failed:
                Button("Resume") {
                    perform {
                        try await viewModel.resumeLocalModel(
                            installationID: installation.installationID
                        )
                    }
                }
                Button("Delete", role: .destructive) {
                    perform {
                        try await viewModel.deleteLocalModel(
                            installationID: installation.installationID
                        )
                    }
                }
            case .installed:
                Button("Create Target") {
                    perform { try await viewModel.createTarget(modelID: model.id) }
                }
                Button("Delete", role: .destructive) {
                    perform {
                        try await viewModel.deleteLocalModel(
                            installationID: installation.installationID
                        )
                    }
                }
            case .deleting:
                ProgressView()
            }
        }
        .buttonStyle(.bordered)
    }

    private var cloudSection: some View {
        Section("Cloud Providers") {
            if viewModel.snapshot.cloudProviders.isEmpty {
                Text("Add a Provider Profile to use a cloud model.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.snapshot.cloudProviders) { provider in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(provider.displayName).font(.headline)
                        Spacer()
                        Text(provider.presetID.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(provider.displayOrigin)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(provider.hasStoredCredential ? "Credential stored" : "Credential missing")
                        .font(.caption)
                    HStack {
                        Button("Edit") {
                            editor = ProviderEditorPresentation(provider: provider)
                        }
                        Button("Archive", role: .destructive) {
                            perform { try await viewModel.archive(provider) }
                        }
                    }
                    .buttonStyle(.bordered)
                    HStack {
                        TextField(
                            "Manual model ID",
                            text: manualModelBinding(for: provider)
                        )
                        .textInputAutocapitalization(.never)
                        Button("Validate") {
                            perform {
                                try await viewModel.validateManual(
                                    manualModelIDs[provider.id] ?? "",
                                    for: provider
                                )
                            }
                        }
                    }
                    ForEach(cloudModels(for: provider)) { model in
                        Divider()
                        Text(model.modelID).font(.subheadline.weight(.semibold))
                        capabilityText(model)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Validate") {
                                perform { try await viewModel.validate(model) }
                            }
                            Button("Create Target") {
                                perform {
                                    try await viewModel.createTarget(
                                        modelID: viewModel.cloudModelID(model)
                                    )
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var parameterSection: some View {
        if let selected = viewModel.selectedModelID,
           let schema = viewModel.parameterSchema(for: selected) {
            Section("Target Defaults") {
                if let notice = viewModel.parameterNotice {
                    Text(notice).foregroundStyle(.secondary)
                }
                ForEach(
                    schema.definitions.values
                        .filter { $0.support == .supported }
                        .sorted { $0.id.rawValue < $1.id.rawValue },
                    id: \.id.rawValue
                ) { definition in
                    ParameterControl(definition: definition, viewModel: viewModel)
                }
            }
        }
    }

    private var targetSection: some View {
        Section("Reusable Targets") {
            if viewModel.snapshot.targets.isEmpty {
                Text("No target revisions published yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.snapshot.targets, id: \.reference.targetID.rawValue) { target in
                LabeledContent(
                    target.modelID,
                    value: "\(target.targetID.rawValue.prefix(8)) · r\(target.revision)"
                )
            }
        }
    }

    private func cloudModels(
        for provider: ModelCenterCloudProviderState
    ) -> [ModelCenterCloudModelState] {
        viewModel.snapshot.cloudModels.filter {
            $0.profileID == provider.profileID
                && $0.profileRevision == provider.revision
        }
    }

    private func capabilityText(_ model: ModelCenterCloudModelState) -> Text {
        let supported = model.capabilities.capabilities
            .filter { $0.value.support == .supported }
            .keys
            .sorted()
            .joined(separator: ", ")
        return Text(supported.isEmpty ? "Capabilities unverified" : supported)
    }

    private func manualModelBinding(
        for provider: ModelCenterCloudProviderState
    ) -> Binding<String> {
        Binding(
            get: { manualModelIDs[provider.id] ?? "" },
            set: { manualModelIDs[provider.id] = $0 }
        )
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
                await viewModel.reload()
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ProviderEditorPresentation: Identifiable {
    let id = UUID()
    let provider: ModelCenterCloudProviderState?
}

private struct ParameterControl: View {
    let definition: LLMParameterDefinition
    @Bindable var viewModel: ModelCenterViewModel

    var body: some View {
        switch definition.valueType {
        case .decimal:
            VStack(alignment: .leading) {
                LabeledContent(label, value: decimalValue.formatted(.number.precision(.fractionLength(2))))
                Slider(
                    value: Binding(
                        get: { decimalValue },
                        set: { viewModel.setParameter(definition.id, value: .decimal($0)) }
                    ),
                    in: (definition.minimum ?? 0)...(definition.maximum ?? 2)
                )
            }
        case .integer:
            Stepper(
                "\(label): \(integerValue)",
                value: Binding(
                    get: { integerValue },
                    set: { viewModel.setParameter(definition.id, value: .integer($0)) }
                ),
                in: Int64(definition.minimum ?? 0)...Int64(definition.maximum ?? 4_096)
            )
        case .text where !definition.choices.isEmpty:
            Picker(label, selection: textBinding) {
                ForEach(definition.choices.sorted(), id: \.self) { Text($0).tag($0) }
            }
        case .text:
            TextField(label, text: textBinding)
        case .boolean:
            Toggle(label, isOn: Binding(
                get: { booleanValue },
                set: { viewModel.setParameter(definition.id, value: .boolean($0)) }
            ))
        case .textList:
            TextField(label, text: Binding(
                get: { textListValue.joined(separator: ", ") },
                set: {
                    viewModel.setParameter(
                        definition.id,
                        value: .textList($0.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        })
                    )
                }
            ))
        }
    }

    private var label: String {
        definition.id.rawValue.replacingOccurrences(of: ".", with: " ").capitalized
    }

    private var decimalValue: Double {
        if case .decimal(let value) = viewModel.parameterValue(definition.id) {
            return value
        }
        return definition.minimum ?? 0
    }

    private var integerValue: Int64 {
        if case .integer(let value) = viewModel.parameterValue(definition.id) {
            return value
        }
        return Int64(definition.minimum ?? 0)
    }

    private var booleanValue: Bool {
        if case .boolean(let value) = viewModel.parameterValue(definition.id) {
            return value
        }
        return false
    }

    private var textListValue: [String] {
        if case .textList(let value) = viewModel.parameterValue(definition.id) {
            return value
        }
        return []
    }

    private var textBinding: Binding<String> {
        Binding(
            get: {
                if case .text(let value) = viewModel.parameterValue(definition.id) {
                    return value
                }
                return definition.choices.sorted().first ?? ""
            },
            set: { viewModel.setParameter(definition.id, value: .text($0)) }
        )
    }
}

private func byteCount(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}
