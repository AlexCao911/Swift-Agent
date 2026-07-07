import SwiftUI

struct AgentBuilderToolPickerView: View {
    var tools: [AgentBuilderToolCard]
    var selectedToolIds: [String]
    var onToggle: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(filteredTools) { tool in
                Button {
                    if tool.isAvailable {
                        onToggle(tool.id)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool.title)
                                .font(.headline)
                            Text(tool.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text("\(tool.riskLevel) · \(tool.approvalPolicy)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedToolIds.contains(tool.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .disabled(!tool.isAvailable)
            }
            .searchable(text: $query, prompt: "Search tools")
            .navigationTitle("Choose Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var filteredTools: [AgentBuilderToolCard] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return tools
        }
        return tools.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
