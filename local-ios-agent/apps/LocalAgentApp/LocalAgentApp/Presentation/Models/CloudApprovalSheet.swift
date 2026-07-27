import LocalAgentLLMCloud
import SwiftUI

struct CloudApprovalSheet: View {
    let request: AppCloudApprovalRequest
    let onDecision: (EgressDecision) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Destination") {
                    LabeledContent("Origin", value: origin)
                }
                Section("Request") {
                    Text(title)
                    ForEach(details, id: \.self) { detail in
                        Text(detail)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Cloud access")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Deny", role: .cancel) {
                        onDecision(.deny)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Allow") {
                        onDecision(.allow)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.bar)
            }
        }
        .interactiveDismissDisabled(false)
    }

    private var origin: String {
        let value: EgressOrigin
        switch request.content {
        case .origin(let origin, _), .scope(let origin, _):
            value = origin
        case .providerState(_, let origin, _):
            value = origin
        }
        return "\(value.scheme)://\(value.host):\(value.port)"
    }

    private var title: String {
        switch request.content {
        case .origin(_, let profileName):
            "\(profileName) wants to connect to this origin."
        case .scope:
            "New information will be sent to this provider."
        case .providerState(let profileName, _, _):
            "\(profileName) can retain provider-side conversation state."
        }
    }

    private var details: [String] {
        switch request.content {
        case .origin:
            return []
        case .scope(_, let summary):
            let sources = summary.sourceSummary.sourceKinds
                .map(\.rawValue)
                .sorted()
                .joined(separator: ", ")
            let classes = summary.newlyAddedDataClasses
                .map(\.rawValue)
                .sorted()
                .joined(separator: ", ")
            return [
                "Sources: \(sources.isEmpty ? "none" : sources)",
                "Data: \(classes.isEmpty ? "none" : classes)",
                "Approximate size: \(summary.sourceSummary.approximateAddedSize.rawValue)",
            ]
        case .providerState(_, _, let disclosure):
            return [
                "Behavior: \(disclosure.behavior.rawValue)",
                "Retention window: \(disclosure.windowClass.rawValue)",
            ]
        }
    }
}
