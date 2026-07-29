import SwiftUI
import UniformTypeIdentifiers

struct PromptDocumentsSettingsView: View {
    @ObservedObject private var store = PromptDocumentStore.shared
    @State private var editing: PromptDocumentRecord?
    @State private var showsImporter = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if store.documents.isEmpty {
                ContentUnavailableView(
                    "No Prompt Documents",
                    systemImage: "doc.text",
                    description: Text(
                        "Add ordered Markdown instructions for the Rust Agent Core."
                    )
                )
            } else {
                ForEach(store.documents) { document in
                    Button {
                        editing = document
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(document.name)
                                    .foregroundStyle(.primary)
                                Text(document.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { document.isEnabled },
                                    set: {
                                        try? store.setEnabled(
                                            document.id,
                                            enabled: $0
                                        )
                                    }
                                )
                            )
                            .labelsHidden()
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        try? store.remove(store.documents[index].id)
                    }
                }
                .onMove { offsets, destination in
                    try? store.move(
                        fromOffsets: offsets,
                        toOffset: destination
                    )
                }
            }
        }
        .navigationTitle("Prompt Documents")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Document", systemImage: "plus") {
                        editing = PromptDocumentRecord(
                            id: "",
                            name: "Instructions",
                            source: "settings",
                            markdown: "",
                            isEnabled: true,
                            sortOrder: store.documents.count
                        )
                    }
                    Button("Import Markdown", systemImage: "doc.badge.plus") {
                        showsImporter = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editing) { record in
            PromptDocumentEditor(store: store, record: record)
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.plainText]
        ) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                _ = try store.importMarkdown(at: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct PromptDocumentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PromptDocumentStore
    let record: PromptDocumentRecord
    @State private var name: String
    @State private var markdown: String
    @State private var errorMessage: String?

    init(store: PromptDocumentStore, record: PromptDocumentRecord) {
        self.store = store
        self.record = record
        _name = State(initialValue: record.name)
        _markdown = State(initialValue: record.markdown)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextEditor(text: $markdown)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 320)
            }
            .navigationTitle(
                record.id.isEmpty ? "New Prompt" : "Edit Prompt"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            if record.id.isEmpty {
                                _ = try store.add(
                                    name: name,
                                    markdown: markdown
                                )
                            } else {
                                try store.update(
                                    record.id,
                                    name: name,
                                    markdown: markdown
                                )
                            }
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .alert(
                "Save Failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
