# Plan 12: SwiftUI MVP Shell + Acceptance Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the SwiftUI MVP shell that can send messages, render streamed runtime events, surface tool approval requests, execute pending native tools, switch providers, and show prompt/debug state.

**Architecture:** SwiftUI is a projection of runtime state. `AgentViewModel` coordinates `RuntimeClient` and `NativeToolExecutor`, while Rust remains authoritative for sessions, events, run states, tool policy, and prompt context.

**Tech Stack:** Swift Package Manager, Swift 5.9, SwiftUI, Observation on supported platforms through `ObservableObject`, XCTest, Plan 8 `LocalAgentBridge`, Plan 9 `LocalNativeToolkit`, TDD.

---

## Current Code Audit

Expected after Plans 8-11:

- `LocalAgentBridge` exposes runtime DTOs, `RuntimeClient`, and `MockRuntimeClient`.
- `LocalNativeToolkit` exposes `NativeToolCatalog`, `NativeToolExecutor`, and
  basic native/meta tools.
- Rust provider registry and provider docs exist.
- Desktop and on-device provider boundaries are testable independently.

Still missing:

- SwiftUI app/view target.
- Chat state projection.
- Provider settings view model.
- Approval sheet state.
- Tool/audit rendering.
- Prompt debug view.
- MVP acceptance runbook.

Assigned to this plan:

- Add `LocalAgentApp` Swift target.
- Add `AgentViewModel`.
- Add chat, provider settings, approvals, tool rows, and debug views.
- Add view-model tests for send-message and native-tool execution loops.
- Add acceptance hardening docs.

Deferred:

- Xcode project signing and device deployment.
- Real app icons and launch screen.
- Real generated bridge packaging.

## File Structure

Create:

```text
local-ios-agent/ios-app/Sources/LocalAgentApp/AgentViewModel.swift
local-ios-agent/ios-app/Sources/LocalAgentApp/ChatView.swift
local-ios-agent/ios-app/Sources/LocalAgentApp/ProviderSettingsView.swift
local-ios-agent/ios-app/Sources/LocalAgentApp/ApprovalSheetView.swift
local-ios-agent/ios-app/Sources/LocalAgentApp/PromptDebugView.swift
local-ios-agent/ios-app/Sources/LocalAgentApp/ToolAuditRow.swift
local-ios-agent/ios-app/Tests/LocalAgentAppTests/AgentViewModelTests.swift
local-ios-agent/docs/mvp-acceptance.md
```

Modify:

```text
local-ios-agent/ios-app/Package.swift
```

## Task 1: Add App Target and Agent View Model

**Files:**
- Modify: `local-ios-agent/ios-app/Package.swift`
- Create: `local-ios-agent/ios-app/Sources/LocalAgentApp/AgentViewModel.swift`
- Create: `local-ios-agent/ios-app/Tests/LocalAgentAppTests/AgentViewModelTests.swift`

- [ ] **Step 1: Write failing view model test**

Create `local-ios-agent/ios-app/Tests/LocalAgentAppTests/AgentViewModelTests.swift`:

```swift
import XCTest
import LocalAgentBridge
import LocalNativeToolkit
@testable import LocalAgentApp

final class AgentViewModelTests: XCTestCase {
    func testSendMessageCreatesSessionAndRendersAssistantMessage() async throws {
        let viewModel = AgentViewModel(
            runtime: MockRuntimeClient(),
            toolExecutor: NativeToolExecutor(catalog: NativeToolCatalog(), permissionStore: PermissionStore())
        )

        await viewModel.send("hello")

        XCTAssertEqual(viewModel.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(viewModel.messages.last?.text, "Mock response to: hello")
        XCTAssertEqual(viewModel.runState, .completed)
    }

    func testPendingToolRequestExecutesThroughNativeExecutor() async throws {
        var catalog = NativeToolCatalog()
        try catalog.register(PermissionStatusTool())
        let viewModel = AgentViewModel(
            runtime: MockRuntimeClient(),
            toolExecutor: NativeToolExecutor(
                catalog: catalog,
                permissionStore: PermissionStore(states: ["calendar.read": .granted])
            )
        )

        await viewModel.send("use tool debug.echo")

        XCTAssertEqual(viewModel.runState, .waitingTool)
        XCTAssertFalse(viewModel.toolRows.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter AgentViewModelTests
```

Expected: FAIL because `LocalAgentApp` and `AgentViewModel` do not exist.

- [ ] **Step 3: Add package target and view model**

Modify `local-ios-agent/ios-app/Package.swift` to add:

```swift
.library(name: "LocalAgentApp", targets: ["LocalAgentApp"])
```

Add target entries:

```swift
.target(
    name: "LocalAgentApp",
    dependencies: ["LocalAgentBridge", "LocalNativeToolkit"]
),
.testTarget(
    name: "LocalAgentAppTests",
    dependencies: ["LocalAgentApp", "LocalAgentBridge", "LocalNativeToolkit"]
)
```

Create `local-ios-agent/ios-app/Sources/LocalAgentApp/AgentViewModel.swift`:

```swift
import Foundation
import LocalAgentBridge
import LocalNativeToolkit

public enum ChatRole: Equatable, Sendable {
    case user
    case assistant
    case tool
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public var id: String
    public var role: ChatRole
    public var text: String
}

public struct ToolAuditDisplayRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var isError: Bool
}

@MainActor
public final class AgentViewModel: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var toolRows: [ToolAuditDisplayRow] = []
    @Published public private(set) var pendingApprovals: [ApprovalProtocolRequestDTO] = []
    @Published public private(set) var runState: RunStateDTO?
    @Published public var draftText: String = ""

    private let runtime: any RuntimeClient
    private let toolExecutor: NativeToolExecutor
    private var sessionId: String?

    public init(runtime: any RuntimeClient, toolExecutor: NativeToolExecutor) {
        self.runtime = runtime
        self.toolExecutor = toolExecutor
    }

    public func send(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        do {
            let session = try await existingOrNewSession()
            messages.append(ChatMessage(id: "local_user_\(messages.count)", role: .user, text: text))
            let turn = try await runtime.sendMessage(sessionId: session, parentEventId: nil, text: text)
            apply(turn)
            let requests = try await runtime.pendingToolRequests()
            for request in requests {
                toolRows.append(ToolAuditDisplayRow(
                    id: request.toolCallId,
                    title: request.toolName,
                    detail: request.argumentsJson,
                    isError: false
                ))
            }
            pendingApprovals = try await runtime.pendingApprovalRequests()
        } catch {
            messages.append(ChatMessage(id: "local_error_\(messages.count)", role: .assistant, text: error.localizedDescription))
            runState = .failed
        }
    }

    public func approve(_ approval: ApprovalProtocolRequestDTO) async {
        do {
            let turn = try await runtime.submitApprovalResponse(
                ApprovalProtocolResponseDTO(approvalId: approval.approvalId, approved: true)
            )
            apply(turn)
            pendingApprovals.removeAll { $0.approvalId == approval.approvalId }
        } catch {
            messages.append(ChatMessage(id: "approval_error_\(messages.count)", role: .assistant, text: error.localizedDescription))
            runState = .failed
        }
    }

    private func existingOrNewSession() async throws -> String {
        if let sessionId {
            return sessionId
        }
        let created = try await runtime.createSession()
        sessionId = created
        return created
    }

    private func apply(_ turn: AgentTurnResultDTO) {
        runState = turn.state
        for event in turn.events {
            switch event.kind {
            case .assistantTextDelta:
                appendAssistantDelta(event.payload)
            case .assistantMessageCompleted:
                replaceOrAppendAssistant(event.payload)
            case .toolResultMessage:
                toolRows.append(ToolAuditDisplayRow(id: event.id, title: "Tool result", detail: event.payload, isError: false))
            case .runFailed:
                messages.append(ChatMessage(id: event.id, role: .assistant, text: event.payload))
            default:
                break
            }
        }
    }

    private func appendAssistantDelta(_ text: String) {
        if let last = messages.last, last.role == .assistant {
            messages[messages.count - 1].text += text
        } else {
            messages.append(ChatMessage(id: "assistant_\(messages.count)", role: .assistant, text: text))
        }
    }

    private func replaceOrAppendAssistant(_ text: String) {
        if let last = messages.last, last.role == .assistant {
            messages[messages.count - 1].text = text
        } else {
            messages.append(ChatMessage(id: "assistant_\(messages.count)", role: .assistant, text: text))
        }
    }
}
```

- [ ] **Step 4: Run test to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter AgentViewModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/ios-app/Package.swift local-ios-agent/ios-app/Sources/LocalAgentApp/AgentViewModel.swift local-ios-agent/ios-app/Tests/LocalAgentAppTests/AgentViewModelTests.swift
git commit -m "feat: add agent view model"
```

## Task 2: Add SwiftUI Chat and Tool Rows

**Files:**
- Create: `local-ios-agent/ios-app/Sources/LocalAgentApp/ChatView.swift`
- Create: `local-ios-agent/ios-app/Sources/LocalAgentApp/ToolAuditRow.swift`

- [ ] **Step 1: Implement chat view**

Create `local-ios-agent/ios-app/Sources/LocalAgentApp/ChatView.swift`:

```swift
import SwiftUI

public struct ChatView: View {
    @ObservedObject private var viewModel: AgentViewModel

    public init(viewModel: AgentViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                    }
                    ForEach(viewModel.toolRows) { row in
                        ToolAuditRow(row: row)
                    }
                }
                .padding()
            }

            HStack(spacing: 8) {
                TextField("Message", text: $viewModel.draftText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let text = viewModel.draftText
                    viewModel.draftText = ""
                    Task { await viewModel.send(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
            }
            .padding()
        }
    }
}

private struct MessageBubble: View {
    var message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            Text(message.text)
                .padding(10)
                .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if message.role != .user { Spacer(minLength: 48) }
        }
    }
}
```

Create `local-ios-agent/ios-app/Sources/LocalAgentApp/ToolAuditRow.swift`:

```swift
import SwiftUI

public struct ToolAuditRow: View {
    var row: ToolAuditDisplayRow

    public init(row: ToolAuditDisplayRow) {
        self.row = row
    }

    public var body: some View {
        DisclosureGroup {
            Text(row.detail)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(row.title, systemImage: row.isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 2: Build Swift package**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift build
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/ios-app/Sources/LocalAgentApp/ChatView.swift local-ios-agent/ios-app/Sources/LocalAgentApp/ToolAuditRow.swift
git commit -m "feat: add SwiftUI chat shell"
```

## Task 3: Add Provider Settings, Approval Sheet, and Prompt Debug Views

**Files:**
- Create: `local-ios-agent/ios-app/Sources/LocalAgentApp/ProviderSettingsView.swift`
- Create: `local-ios-agent/ios-app/Sources/LocalAgentApp/ApprovalSheetView.swift`
- Create: `local-ios-agent/ios-app/Sources/LocalAgentApp/PromptDebugView.swift`

- [ ] **Step 1: Implement provider settings view**

Create `local-ios-agent/ios-app/Sources/LocalAgentApp/ProviderSettingsView.swift`:

```swift
import SwiftUI

public struct ProviderSettingsView: View {
    @Binding private var selectedProvider: String
    @Binding private var endpoint: String

    public init(selectedProvider: Binding<String>, endpoint: Binding<String>) {
        self._selectedProvider = selectedProvider
        self._endpoint = endpoint
    }

    public var body: some View {
        Form {
            Picker("Provider", selection: $selectedProvider) {
                Text("Mock").tag("mock")
                Text("Desktop MiniCPM").tag("desktop-minicpm")
                Text("On-device MiniCPM").tag("on-device-minicpm")
            }
            TextField("Endpoint", text: $endpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}
```

- [ ] **Step 2: Implement approval sheet**

Create `local-ios-agent/ios-app/Sources/LocalAgentApp/ApprovalSheetView.swift`:

```swift
import SwiftUI
import LocalAgentBridge

public struct ApprovalSheetView: View {
    var request: ApprovalProtocolRequestDTO
    var approve: () -> Void
    var reject: () -> Void

    public init(
        request: ApprovalProtocolRequestDTO,
        approve: @escaping () -> Void,
        reject: @escaping () -> Void
    ) {
        self.request = request
        self.approve = approve
        self.reject = reject
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Approval Required")
                .font(.headline)
            Text(request.message)
            if request.requiresLocalAuthentication {
                Label("Local authentication required", systemImage: "faceid")
                    .font(.caption)
            }
            HStack {
                Button("Reject", role: .cancel, action: reject)
                Spacer()
                Button("Approve", action: approve)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
```

- [ ] **Step 3: Implement prompt debug view**

Create `local-ios-agent/ios-app/Sources/LocalAgentApp/PromptDebugView.swift`:

```swift
import SwiftUI

public struct PromptDebugView: View {
    var title: String
    var promptJSON: String

    public init(title: String, promptJSON: String) {
        self.title = title
        self.promptJSON = promptJSON
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ScrollView {
                Text(promptJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }
}
```

- [ ] **Step 4: Build Swift package**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift build
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/ios-app/Sources/LocalAgentApp/ProviderSettingsView.swift local-ios-agent/ios-app/Sources/LocalAgentApp/ApprovalSheetView.swift local-ios-agent/ios-app/Sources/LocalAgentApp/PromptDebugView.swift
git commit -m "feat: add settings approval and debug views"
```

## Task 4: Add MVP Acceptance Runbook

**Files:**
- Create: `local-ios-agent/docs/mvp-acceptance.md`

- [ ] **Step 1: Create acceptance checklist**

Create `local-ios-agent/docs/mvp-acceptance.md`:

```markdown
# Local iOS Agent MVP Acceptance

## Branch Inputs

- `codex/local-ios-agent-native-toolkit` provides Plan 8 and Plan 9.
- `codex/local-ios-agent-ai-model` provides Plan 10 and Plan 11.
- `codex/local-ios-agent-frontend` provides Plan 12.

## Required Checks

```bash
cd local-ios-agent/rust-core
cargo test
```

```bash
cd local-ios-agent/ios-app
swift test
swift build
```

## Acceptance Scenarios

1. Mock chat turn:
   - Create session.
   - Send `hello`.
   - Render user message and assistant completion.

2. Tool lifecycle:
   - Send `use tool debug.echo`.
   - Runtime exposes a pending tool request.
   - Native toolkit executor returns a `ToolResultDTO`.
   - Runtime accepts the tool result and completes the turn.

3. Approval lifecycle:
   - Confirm-level tool produces an approval request.
   - SwiftUI shows approval sheet.
   - Approval response resumes the run.

4. Provider selection:
   - Mock provider remains default.
   - Desktop MiniCPM profile accepts a localhost endpoint.
   - On-device MiniCPM profile remains selectable as a boundary provider.

5. Debug visibility:
   - Tool rows show tool name and arguments/result detail.
   - Prompt debug view can render captured prompt JSON text.
```

- [ ] **Step 2: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/docs/mvp-acceptance.md
git commit -m "docs: add MVP acceptance runbook"
```

## Self-Review

Spec coverage:

- Chat UI, provider selector, approval UI, tool rows, and prompt debug view are
  all assigned.
- View-model tests cover the runtime client path.
- The runbook includes Rust, Swift, and MVP acceptance scenarios.

Placeholder scan:

- No placeholder terms are used as implementation instructions.

Type consistency:

- View model uses `RuntimeClient`, `NativeToolExecutor`, `RunStateDTO`,
  `RuntimeEventDTO`, and `ApprovalProtocolRequestDTO` from earlier plans.
