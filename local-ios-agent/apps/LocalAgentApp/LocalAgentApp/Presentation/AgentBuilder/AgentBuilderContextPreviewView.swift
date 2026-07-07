import SwiftUI

struct AgentBuilderContextPreviewView: View {
    var preview: BuilderContextPreviewResult?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        preview?.isPreviewOnly == false ? "Rust preview" : "Preview only",
                        systemImage: preview?.isPreviewOnly == false ? "timeline.selection" : "eye"
                    )
                        .font(.headline)
                    Text(preview?.isPreviewOnly == false
                        ? "This preview is assembled by the Rust context pipeline. Final model input is still resolved at run time."
                        : "Final model input is assembled by Rust execution at run time.")
                        .foregroundStyle(.secondary)
                    if let preview {
                        LabeledContent("Token estimate", value: "\(preview.tokenEstimate)")
                    }
                }

                if let preview {
                    if !preview.warnings.isEmpty {
                        Section("Warnings") {
                            ForEach(preview.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                            }
                        }
                    }

                    Section("Context Segments") {
                        ForEach(preview.segments) { segment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(segment.title)
                                        .font(.headline)
                                    Spacer()
                                    Text(segment.isEnabled ? "Enabled" : "Disabled")
                                        .font(.caption)
                                        .foregroundStyle(segment.isEnabled ? .green : .secondary)
                                }
                                Text(segment.sourceLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(segment.previewText)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Preview",
                        systemImage: "eye.slash",
                        description: Text("Generate a context preview from the Builder cards.")
                    )
                }
            }
            .navigationTitle("Context Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
