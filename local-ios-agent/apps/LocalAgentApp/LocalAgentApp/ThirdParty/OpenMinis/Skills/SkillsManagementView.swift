import SwiftUI
import UniformTypeIdentifiers

struct SkillsManagementView: View {
    @ObservedObject private var store = SkillStore.shared
    @State private var search = ""
    @State private var showsFileImporter = false
    @State private var showsURLImport = false
    @State private var errorMessage: String?

    private var filtered: [Skill] {
        let query = search.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        let ordered = store.skills.sorted {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            return $0.id < $1.id
        }
        guard !query.isEmpty else { return ordered }
        return ordered.filter {
            $0.name.lowercased().contains(query)
                || $0.description.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "No Skills",
                    systemImage: "puzzlepiece.extension",
                    description: Text(
                        "Import a SKILL.md, Skill directory, .skill, or .zip file."
                    )
                )
            } else {
                ForEach(filtered) { skill in
                    NavigationLink {
                        SkillDetailView(skillID: skill.id)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(skill.name)
                                if !skill.description.isEmpty {
                                    Text(skill.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { skill.isEnabled },
                                    set: {
                                        try? store.setEnabled(
                                            skill.id,
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
                        try? store.deleteSkill(filtered[index].id)
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
        .navigationTitle("Skills")
        .searchable(text: $search)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Import File or Directory", systemImage: "folder") {
                        showsFileImporter = true
                    }
                    Button("Import URL", systemImage: "link") {
                        showsURLImport = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [
                .folder,
                .plainText,
                .zip,
                UTType(filenameExtension: "skill") ?? .data,
            ]
        ) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                _ = try store.importFromFile(at: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsURLImport) {
            SkillURLImportSheet(store: store)
        }
        .alert(
            "Skill Import Failed",
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

private struct SkillURLImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SkillStore
    @State private var url = ""
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField(
                    "GitHub or direct SKILL.md URL",
                    text: $url,
                    axis: .vertical
                )
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Import Skill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isImporting ? "Importing…" : "Import") {
                        isImporting = true
                        Task {
                            do {
                                _ = try await store.importFromURL(url)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                                isImporting = false
                            }
                        }
                    }
                    .disabled(
                        isImporting
                            || url.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                }
            }
        }
    }
}

private struct SkillDetailView: View {
    let skillID: String
    @ObservedObject private var store = SkillStore.shared
    @State private var content = ""
    @State private var errorMessage: String?

    private var skill: Skill? {
        store.skills.first { $0.id == skillID }
    }

    var body: some View {
        List {
            Section("SKILL.md") {
                TextEditor(text: $content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 280)
                Button("Save") {
                    do {
                        try store.updateSkillContent(
                            skillID,
                            content: content
                        )
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            let files = store.listSkillFiles(skillID)
                .filter { $0 != "SKILL.md" }
            if !files.isEmpty {
                Section("Files loaded only on demand") {
                    ForEach(files, id: \.self) { path in
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle(skill?.name ?? "Skill")
        .onAppear {
            content = store.readSkillContent(skillID) ?? ""
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

struct SessionSkillsView: View {
    let conversationStreamID: String?
    @ObservedObject private var store = SkillStore.shared

    var body: some View {
        List(store.skills) { skill in
            Toggle(
                isOn: Binding(
                    get: {
                        store.isEnabled(
                            skill.id,
                            for: conversationStreamID
                        )
                    },
                    set: { enabled in
                        guard let conversationStreamID else { return }
                        store.setConversationOverride(
                            skillID: skill.id,
                            conversationStreamID: conversationStreamID,
                            enabled: enabled
                        )
                    }
                )
            ) {
                VStack(alignment: .leading) {
                    Text(skill.name)
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(conversationStreamID == nil)
        }
        .navigationTitle("Conversation Skills")
    }
}
