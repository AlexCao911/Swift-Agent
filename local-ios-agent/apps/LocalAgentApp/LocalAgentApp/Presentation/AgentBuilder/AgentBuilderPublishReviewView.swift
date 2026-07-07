import LocalAgentBridge
import SwiftUI

struct AgentBuilderPublishReviewView: View {
    var lifecycle: AgentDraftLifecycleState
    var readiness: PermissionReadinessUIModel
    var draft: AgentBuilderDraft?
    var publishedSelection: PublishedAgentSelection?
    var onValidate: () -> Void
    var onPublish: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Included in this publish") {
                    Label("Template profile", systemImage: "doc.badge.gearshape")
                    Label("Exact profile revision id after publish", systemImage: "number")
                    if let publishedSelection {
                        LabeledContent("Published revision", value: "\(publishedSelection.profileRevisionId)")
                    }
                }

                Section("Preview only / not included in this template-backed publish") {
                    ForEach(previewOnlyCards) { card in
                        Label(card.kind.title, systemImage: "eye")
                    }
                }

                Section("Readiness") {
                    if readiness.issues.isEmpty {
                        Label("No issues found", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(readiness.issues, id: \.code) { issue in
                            Label(issue.message, systemImage: "exclamationmark.triangle")
                        }
                    }
                }
            }
            .navigationTitle("Publish Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Validate", action: onValidate)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish", action: onPublish)
                        .disabled(lifecycle != .readyToPublish)
                }
            }
        }
    }

    private var previewOnlyCards: [AgentBuilderCardDraft] {
        draft?.cards.filter { !$0.isPublishAffecting && $0.isEnabled } ?? []
    }
}
