import SwiftUI

struct ToolCenterView: View {
    @Bindable var viewModel: ToolCenterViewModel

    var body: some View {
        List {
            if viewModel.filteredRows.isEmpty {
                ContentUnavailableView(
                    "No Tools",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("Registered native tools will appear here with permission and approval state.")
                )
            } else {
                ForEach(viewModel.filteredRows) { row in
                    ToolCenterRow(row: row)
                }
            }
        }
        .navigationTitle("Tools")
        .searchable(text: $viewModel.searchText, prompt: "Search tools")
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Tool Mode", selection: $viewModel.modeFilter) {
                ForEach(ToolCenterModeFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .task {
            await viewModel.reload()
        }
    }
}

private struct ToolCenterRow: View {
    var row: ToolCenterRowState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(row.riskLevel.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground), in: Capsule())
            }

            Text(row.name)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Label(row.interactionLabel, systemImage: modeIcon)
                ToolApprovalBadge(policy: row.approvalPolicy)
                PermissionBadge(readiness: row.readiness)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if case .denied(_, let repair) = row.readiness {
                Text(repair.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var modeIcon: String {
        switch row.mode {
        case .background:
            "bolt"
        case .userMediated:
            "hand.tap"
        case .systemActionAdapter:
            "sparkles"
        }
    }

}
