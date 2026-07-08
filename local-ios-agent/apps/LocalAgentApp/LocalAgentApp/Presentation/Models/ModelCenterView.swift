import SwiftUI

struct ModelCenterView: View {
    @Bindable var viewModel: ModelCenterViewModel
    @Bindable var shellViewModel: AppShellViewModel
    @Bindable var chatViewModel: AgentViewModel

    var body: some View {
        List {
            Section("Active Model") {
                if let activeModel = shellViewModel.activeModel ?? viewModel.activeModel {
                    ModelCenterActiveRow(activeModel: activeModel)
                } else {
                    ContentUnavailableView(
                        "No Active Model",
                        systemImage: "cpu",
                        description: Text("Choose a ready local or cloud model.")
                    )
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Local Engines") {
                rows(for: .local)
            }

            Section("Cloud Providers") {
                rows(for: .cloud)
            }

            Section("Runtime Defaults") {
                LabeledContent("Temperature") {
                    Text(chatViewModel.state.modelSettings.temperature.formatted(.number.precision(.fractionLength(2))))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $chatViewModel.state.modelSettings.temperature,
                    in: 0...2,
                    step: 0.05
                )

                LabeledContent("Top-p") {
                    Text(chatViewModel.state.modelSettings.topP.formatted(.number.precision(.fractionLength(2))))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $chatViewModel.state.modelSettings.topP,
                    in: 0.05...1,
                    step: 0.01
                )

                LabeledContent("Context Budget", value: "Runtime policy")
                Text("Sampling changes apply to the next run. Context budget is still controlled by the Rust runtime policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Models")
        .task {
            await viewModel.reload(shell: shellViewModel)
        }
    }

    @ViewBuilder
    private func rows(for section: ModelCenterSection) -> some View {
        let rows = viewModel.rows.filter { section.includes($0.route) }
        if rows.isEmpty {
            Text(section.emptyMessage)
                .foregroundStyle(.secondary)
        } else {
            ForEach(rows) { row in
                Button {
                    Task {
                        await viewModel.select(rowId: row.id, shell: shellViewModel)
                    }
                } label: {
                    ModelCenterRow(row: row)
                }
                .buttonStyle(.plain)
                .disabled(row.readiness != .ready)
            }
        }
    }
}

private enum ModelCenterSection {
    case local
    case cloud

    var emptyMessage: String {
        switch self {
        case .local:
            "Local engines will appear after they are configured."
        case .cloud:
            "Cloud providers will appear after they are configured."
        }
    }

    func includes(_ route: ModelRouteKind) -> Bool {
        switch (self, route) {
        case (.local, .localCpp), (.cloud, .cloud):
            true
        default:
            false
        }
    }
}

private struct ModelCenterActiveRow: View {
    var activeModel: ActiveModelSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(activeModel.displayName)
                .font(.headline)
            Text(activeModel.modelId)
                .font(.caption)
                .foregroundStyle(.secondary)
            ModelReadinessBadge(readiness: activeModel.readiness)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct ModelCenterRow: View {
    var row: ModelCenterRowState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(row.displayName)
                        .font(.headline)
                    if row.isActive {
                        Text("Active")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                }

                Text(routeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ModelReadinessBadge(readiness: row.readiness)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch row.route {
        case .localCpp:
            "cpu"
        case .cloud:
            "cloud"
        case .unset:
            "questionmark.circle"
        }
    }

    private var routeLabel: String {
        switch row.route {
        case .localCpp(let engineId):
            "Local engine \(engineId)"
        case .cloud(let providerId):
            "Cloud provider \(providerId)"
        case .unset:
            "Not configured"
        }
    }
}
