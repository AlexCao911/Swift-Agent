import LocalAgentLLMCloud
import SwiftUI

// Direct product-layer port of OpenMinis ProviderInstancesView. LocalAgent's
// single HTTP/security stack remains behind ModelCenterViewModel.
struct OpenMinisProviderInstancesView: View {
    @Bindable var viewModel: ModelCenterViewModel
    @State private var editor: ProviderEditorPresentation?

    var body: some View {
        List {
            ForEach(providerSections, id: \.id) { section in
                Section(section.title) {
                    ForEach(section.providers) { provider in
                        Button {
                            editor = ProviderEditorPresentation(
                                provider: provider
                            )
                        } label: {
                            OpenMinisProviderInstanceRow(
                                provider: provider,
                                modelCount: viewModel.snapshot.cloudModels.filter {
                                    $0.profileID == provider.profileID
                                        && $0.profileRevision == provider.revision
                                }.count
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                editor = ProviderEditorPresentation(
                                    provider: provider
                                )
                            } label: {
                                Label("Edit Provider", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                perform {
                                    try await viewModel.archive(provider)
                                }
                            } label: {
                                Label("Archive Provider", systemImage: "archivebox")
                            }
                        }
                    }
                }
            }

            if viewModel.snapshot.cloudProviders.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "key.slash")
                            .font(.system(size: 32))
                            .foregroundStyle(.quaternary)
                        Text("No providers configured")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Add a provider to get started.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = ProviderEditorPresentation(provider: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Provider")
            }
        }
        .task { await viewModel.reload() }
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

    private var providerSections: [OpenMinisProviderSection] {
        let grouped = Dictionary(
            grouping: viewModel.snapshot.cloudProviders,
            by: \.presetID
        )
        return grouped.keys.sorted {
            $0.rawValue.localizedCaseInsensitiveCompare($1.rawValue)
                == .orderedAscending
        }.map { preset in
            OpenMinisProviderSection(
                id: preset.rawValue,
                title: ProviderPreset.shipped.first {
                    $0.id == preset
                }?.displayName ?? preset.rawValue,
                providers: grouped[preset, default: []]
            )
        }
    }

    private func perform(
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
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

private struct OpenMinisProviderSection: Identifiable {
    let id: String
    let title: String
    let providers: [CloudProviderProductState]
}

private struct OpenMinisProviderInstanceRow: View {
    let provider: CloudProviderProductState
    let modelCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(
                    provider.hasStoredCredential
                        ? Color.green
                        : Color(UIColor.quaternaryLabel)
                )
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(
                        provider.credentialMode == .oauth
                            ? "OAuth"
                            : "API Key"
                    )
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(
                        provider.hasStoredCredential
                            ? "Credential stored"
                            : "Not configured"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if modelCount > 0 {
                    Text("\(modelCount) models")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
