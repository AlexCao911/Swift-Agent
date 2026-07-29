import LocalAgentLLMLocal
import SwiftUI

enum ProductModelSelection: Equatable, Sendable {
    case cloud(providerConfigurationID: String, modelID: String)
    case local(engineID: String, modelID: String)
}

enum UnifiedModelSection: Equatable, Sendable {
    case onDevice
    case cloud
}

struct UnifiedModelOption: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let section: UnifiedModelSection
    let selection: ProductModelSelection
    let modelCenterID: String
}

enum UnifiedModelPickerProjection {
    static func options(in snapshot: ModelCenterSnapshot) -> [UnifiedModelOption] {
        let local = snapshot.localModels.compactMap { model -> UnifiedModelOption? in
            guard let installation = model.installation,
                  installation.state == .installed,
                  installation.catalogStatus == .current
            else {
                return nil
            }
            return UnifiedModelOption(
                id: "local:\(installation.installationID)",
                title: model.displayName,
                subtitle: "On Device",
                section: .onDevice,
                selection: .local(
                    engineID: installation.installationID,
                    modelID: model.modelRevision.modelID
                ),
                modelCenterID: model.id
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let cloud = snapshot.cloudModels.compactMap { model -> UnifiedModelOption? in
            guard let provider = snapshot.cloudProviders.first(where: {
                $0.profileID == model.profileID
                    && $0.revision == model.profileRevision
            }) else {
                return nil
            }
            return UnifiedModelOption(
                id: "cloud:\(model.id)",
                title: model.modelID,
                subtitle: provider.displayName,
                section: .cloud,
                selection: .cloud(
                    providerConfigurationID: model.profileID,
                    modelID: model.modelID
                ),
                modelCenterID:
                    "cloud:\(model.profileID):\(model.profileRevision):\(model.modelID)"
            )
        }.sorted {
            if $0.subtitle == $1.subtitle {
                return $0.title.localizedCaseInsensitiveCompare($1.title)
                    == .orderedAscending
            }
            return $0.subtitle.localizedCaseInsensitiveCompare($1.subtitle)
                == .orderedAscending
        }

        return local + cloud
    }
}

struct UnifiedModelPicker: View {
    let options: [UnifiedModelOption]
    let onSelect: (UnifiedModelOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                optionSection(.onDevice, title: "On Device")
                optionSection(.cloud, title: "Cloud")
            }
            .navigationTitle("Select Model")
            .searchable(text: $search)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func optionSection(
        _ section: UnifiedModelSection,
        title: String
    ) -> some View {
        let rows = filteredOptions.filter { $0.section == section }
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { option in
                    Button {
                        onSelect(option)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .foregroundStyle(.primary)
                            Text(option.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var filteredOptions: [UnifiedModelOption] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return options }
        return options.filter {
            $0.title.localizedCaseInsensitiveContains(term)
                || $0.subtitle.localizedCaseInsensitiveContains(term)
        }
    }
}
