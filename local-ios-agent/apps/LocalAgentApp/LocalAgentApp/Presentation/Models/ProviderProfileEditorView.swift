import Foundation
import LocalAgentLLMCloud
import Observation
import SwiftUI

@MainActor
@Observable
final class ProviderProfileEditorViewModel {
    var presetID: ProviderPresetID = .openAI
    var displayName = "OpenAI"
    var baseURL = "https://api.openai.com/v1"
    var apiKey = ""
    var credentialMode: ProviderCredentialMode = .apiKey
    var retentionMode: ProviderRetentionMode = .statelessRequired
    var providerProjectID = ""
    private(set) var hasStoredCredential = false
    private(set) var errorMessage: String?
    private(set) var didSave = false

    private let client: any ModelCenterClient
    private var profileID: String?
    private var replacingRevision: UInt64?

    init(client: any ModelCenterClient) {
        self.client = client
    }

    func load(profileID: String, revision: UInt64) async {
        do {
            let snapshot = try await client.snapshot()
            guard let profile = snapshot.cloudProviders.first(where: {
                $0.profileID == profileID && $0.revision == revision
            }) else {
                errorMessage = "Provider Profile revision is unavailable."
                return
            }
            self.profileID = profile.profileID
            replacingRevision = profile.revision
            presetID = profile.presetID
            displayName = profile.displayName
            baseURL = profile.baseURL.absoluteString
            hasStoredCredential = profile.hasStoredCredential
            retentionMode = profile.retentionMode
            credentialMode = profile.credentialMode
            providerProjectID = profile.providerProjectID ?? ""
            apiKey = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectPreset(_ id: ProviderPresetID) {
        guard let preset = ProviderPreset.shipped.first(where: { $0.id == id }) else {
            return
        }
        presetID = id
        displayName = preset.displayName
        baseURL = preset.defaultBaseURL.absoluteString
        if !availableCredentialModes.contains(credentialMode) {
            credentialMode = availableCredentialModes.first ?? .apiKey
        }
        if id != .antigravity {
            providerProjectID = ""
        }
    }

    var availableCredentialModes: [ProviderCredentialMode] {
        guard let rawType = OpenMinisProviderConfigurationAdapter
            .rawProviderType(for: presetID)
        else {
            return [.apiKey]
        }
        let modes = ProviderProductCompatibility.mapping(
            rawProviderType: rawType
        ).credentialModes
        return [.apiKey, .oauth].filter(modes.contains)
    }

    func save() async {
        guard let url = URL(string: baseURL),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else {
            errorMessage = "Base URL must be an exact HTTPS URL."
            return
        }
        let secret = apiKey.isEmpty ? nil : SecretBytes(utf8: apiKey)
        defer { apiKey = "" }
        do {
            try await client.publishProviderProfile(ProviderProfileProductDraft(
                profileID: profileID,
                replacingRevision: replacingRevision,
                presetID: presetID,
                displayName: displayName,
                baseURL: url,
                retentionMode: retentionMode,
                credentialMode: credentialMode,
                providerProjectID: presetID == .antigravity
                    ? providerProjectID
                    : nil,
                initialSecret: secret
            ))
            didSave = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ProviderProfileEditorView: View {
    @Bindable var viewModel: ProviderProfileEditorViewModel
    let existingProfile: CloudProviderProductState?
    let onSaved: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: presetBinding) {
                    ForEach(ProviderPreset.shipped, id: \.id) { preset in
                        Text(preset.displayName).tag(preset.id)
                    }
                }
                TextField("Display name", text: $viewModel.displayName)
                TextField("HTTPS Base URL", text: $viewModel.baseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                if viewModel.presetID == .antigravity {
                    TextField(
                        "Cloud Code project ID",
                        text: $viewModel.providerProjectID
                    )
                    .textInputAutocapitalization(.never)
                }
                Picker("Credential", selection: $viewModel.credentialMode) {
                    ForEach(viewModel.availableCredentialModes, id: \.rawValue) {
                        Text($0 == .oauth ? "OAuth Token" : "API Key").tag($0)
                    }
                }
                SecureField(credentialPlaceholder, text: $viewModel.apiKey)
                Picker("Retention", selection: $viewModel.retentionMode) {
                    Text("Stateless required")
                        .tag(ProviderRetentionMode.statelessRequired)
                    Text("Provider state approved")
                        .tag(ProviderRetentionMode.providerStateApproved)
                }
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(existingProfile == nil ? "Add Provider" : "Edit Provider")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.save()
                            if viewModel.didSave { onSaved() }
                        }
                    }
                }
            }
            .task {
                if let existingProfile {
                    await viewModel.load(
                        profileID: existingProfile.profileID,
                        revision: existingProfile.revision
                    )
                }
            }
        }
    }

    private var presetBinding: Binding<ProviderPresetID> {
        Binding(
            get: { viewModel.presetID },
            set: { viewModel.selectPreset($0) }
        )
    }

    private var credentialPlaceholder: String {
        let kind = viewModel.credentialMode == .oauth
            ? "OAuth token"
            : "API key"
        return viewModel.hasStoredCredential
            ? "Replace stored \(kind) (optional)"
            : kind
    }
}
