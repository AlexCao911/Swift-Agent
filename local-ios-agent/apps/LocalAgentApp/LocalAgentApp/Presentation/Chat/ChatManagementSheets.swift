import SwiftUI

struct PromptLibrarySheet: View {
    @Binding var library: PromptLibraryViewState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ForEach($library.sections) { $section in
                    Section(section.name.isEmpty ? "Prompt" : section.name) {
                        TextField("Name", text: $section.name)
                            .textInputAutocapitalization(.words)

                        TextEditor(text: $section.content)
                            .frame(minHeight: 110)
                            .accessibilityLabel("\(section.name) content")
                    }
                }

                Button {
                    library.sections.append(
                        PromptSectionViewState(
                            id: UUID().uuidString,
                            name: "New Prompt",
                            content: ""
                        )
                    )
                } label: {
                    Label("Add Prompt Section", systemImage: "plus")
                }
            }
            .navigationTitle("Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
