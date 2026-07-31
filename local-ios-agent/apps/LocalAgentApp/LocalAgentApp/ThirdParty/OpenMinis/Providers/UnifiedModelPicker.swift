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

// Direct presentation port of OpenMinis UnifiedModelPicker. The provider
// store is replaced by ModelCenter's local/cloud option projection, while the
// searchable, collapsible provider sections and active-row treatment remain.
struct UnifiedModelPicker: View {
    let options: [UnifiedModelOption]
    let selectedOptionID: String?
    let onSelect: (UnifiedModelOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var collapsedProviderIDs: Set<String> = []
    @State private var collapseSeeded = false

    init(
        options: [UnifiedModelOption],
        selectedOptionID: String? = nil,
        onSelect: @escaping (UnifiedModelOption) -> Void
    ) {
        self.options = options
        self.selectedOptionID = selectedOptionID
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredProviderGroups) { provider in
                    providerSection(provider)
                }

                if filteredProviderGroups.isEmpty {
                    emptySection
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search models"
            )
            .navigationTitle("Choose Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { seedCollapse() }
        }
    }

    private var providerGroups: [UnifiedModelProviderGroup] {
        var result: [UnifiedModelProviderGroup] = []
        let local = options.filter { $0.section == .onDevice }
        if !local.isEmpty {
            result.append(UnifiedModelProviderGroup(
                id: "on-device",
                title: "On Device",
                systemImage: "iphone",
                tint: .orange,
                options: local
            ))
        }

        let cloud = Dictionary(
            grouping: options.filter { $0.section == .cloud },
            by: \.subtitle
        )
        for provider in cloud.keys.sorted(
            by: {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        ) {
            result.append(UnifiedModelProviderGroup(
                id: "cloud:\(provider)",
                title: provider,
                systemImage: "cloud.fill",
                tint: .blue,
                options: cloud[provider, default: []]
            ))
        }
        return result
    }

    private var filteredProviderGroups: [UnifiedModelProviderGroup] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return providerGroups }
        return providerGroups.compactMap { provider in
            let matches = provider.options.filter {
                fuzzyMatch($0.title, query: query)
                    || fuzzyMatch($0.subtitle, query: query)
            }
            guard !matches.isEmpty else { return nil }
            return UnifiedModelProviderGroup(
                id: provider.id,
                title: provider.title,
                systemImage: provider.systemImage,
                tint: provider.tint,
                options: matches
            )
        }
    }

    private func fuzzyMatch(_ value: String, query: String) -> Bool {
        let query = query.lowercased()
        let value = value.lowercased()
        if value.contains(query) { return true }
        var index = value.startIndex
        for character in query {
            guard let match = value[index...].firstIndex(of: character) else {
                return false
            }
            index = value.index(after: match)
        }
        return true
    }

    @ViewBuilder
    private func providerSection(
        _ provider: UnifiedModelProviderGroup
    ) -> some View {
        let isCollapsed = searchText.isEmpty
            && collapsedProviderIDs.contains(provider.id)
        let providerOptions: [UnifiedModelOption] = {
            if isCollapsed,
               let selected = provider.options.first(where: {
                   $0.id == selectedOptionID
               }) {
                return [selected]
            }
            return isCollapsed
                ? Array(provider.options.prefix(1))
                : provider.options
        }()

        Section {
            ForEach(providerOptions) { option in
                modelRow(option, provider: provider)
            }

            if isCollapsed && provider.options.count > 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = collapsedProviderIDs.remove(provider.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                        Text("Show \(provider.options.count) models")
                            .font(.caption)
                    }
                    .foregroundStyle(.tint)
                }
            }
        } header: {
            HStack {
                Label(provider.title, systemImage: provider.systemImage)
                    .foregroundStyle(provider.tint)
                Spacer()
                if searchText.isEmpty && provider.options.count > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if collapsedProviderIDs.contains(provider.id) {
                                _ = collapsedProviderIDs.remove(provider.id)
                            } else {
                                _ = collapsedProviderIDs.insert(provider.id)
                            }
                        }
                    } label: {
                        Image(
                            systemName: collapsedProviderIDs.contains(provider.id)
                                ? "chevron.down"
                                : "chevron.up"
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Color(UIColor.tertiarySystemFill),
                            in: Circle()
                        )
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                }
            }
        }
    }

    private func modelRow(
        _ option: UnifiedModelOption,
        provider: UnifiedModelProviderGroup
    ) -> some View {
        let isSelected = option.id == selectedOptionID
        return HStack(spacing: 10) {
            Image(
                systemName: isSelected
                    ? "checkmark.circle.fill"
                    : "circle"
            )
            .font(.system(size: 20))
            .foregroundStyle(
                isSelected
                    ? Color.accentColor
                    : Color(UIColor.tertiaryLabel)
            )

            Image(systemName: provider.systemImage)
                .font(.system(size: 11))
                .foregroundStyle(provider.tint)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(option.title)
                    .font(.subheadline)
                    .foregroundStyle(Color(UIColor.label))
                Text(
                    option.section == .onDevice
                        ? "Runs privately on this device"
                        : option.subtitle
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if isSelected {
                Text("Active")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(option)
            dismiss()
        }
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: 8) {
                Image(
                    systemName: searchText.isEmpty
                        ? "cpu"
                        : "magnifyingglass"
                )
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
                Text(searchText.isEmpty ? "No models available" : "No results")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(
                    searchText.isEmpty
                        ? "Configure a provider or download a local model."
                        : "Try a different search term."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    private func seedCollapse() {
        guard !collapseSeeded else { return }
        collapseSeeded = true
        collapsedProviderIDs = Set(
            providerGroups
                .filter { $0.options.count > 1 }
                .map(\.id)
        )
    }
}

private struct UnifiedModelProviderGroup: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let options: [UnifiedModelOption]
}
