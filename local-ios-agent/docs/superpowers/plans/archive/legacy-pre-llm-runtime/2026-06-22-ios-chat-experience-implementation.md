# iOS Chat Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Claude-like Local Agent iOS chat surface with structured reasoning blocks, stable long streaming output, conversation management, branch/fork workflows, and photo/link attachments.

**Architecture:** Keep SwiftUI in MVVM and keep Rust as the source of runtime truth. SwiftUI renders structured view state, `AgentViewModel` handles user intents, service types mediate runtime/attachment work, and `LocalAgentBridge` exposes only the runtime APIs that the UI needs. Model inference remains behind Rust provider and C ABI boundaries.

**Tech Stack:** SwiftUI, Swift Observation, Swift Testing, LocalAgentBridge Swift package, Rust core runtime, SQLite event store, PhotosUI, UniformTypeIdentifiers.

---

## Scope Check

The approved spec covers five related subsystems. This plan keeps them in one implementation sequence because each phase produces a working, testable chat app and later phases build directly on types introduced earlier:

1. Structured message parts and reasoning parsing.
2. Stream buffering and terminal states.
3. Runtime conversation APIs.
4. SwiftUI conversation and branch actions.
5. Photo and link attachments.

Do not start with attachments or branch UI before Tasks 1-3 are complete. Those features need the structured message model and stable runtime service boundaries.

## File Structure

Create and modify these files:

- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/MessageContent.swift`  
  Owns `MessagePartViewState`, `TextPartViewState`, `ReasoningPartViewState`, `AttachmentViewState`, `UserDraftViewState`, and message helper APIs.

- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/ReasoningTagParser.swift`  
  Pure Swift incremental parser for `<think>` blocks.

- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift`  
  Replaces text-only messages with structured parts while keeping compatibility initializers.

- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/RuntimeEventReducer.swift`  
  Converts runtime events into structured message parts.

- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/RuntimeStreamBuffer.swift`  
  Coalesces streaming events before UI state mutation.

- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`  
  Uses `RuntimeStreamBuffer`, supports parent event ids, terminal states, and new chat intents.

- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ConversationService.swift`  
  Swift-facing conversation operations backed by `RuntimeClient`.

- Modify `local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeDTOs.swift`  
  Adds conversation summary and branch DTOs.

- Modify `local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeClient.swift`  
  Adds conversation listing and branch loading protocols.

- Modify `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`  
  Calls new FFI bridge functions for summaries and branch loading.

- Modify `local-ios-agent/toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`  
  Declares new C bridge functions.

- Modify `local-ios-agent/rust-core/src/core/runtime.rs`  
  Adds conversation summary and branch event accessors.

- Modify `local-ios-agent/rust-core/src/ffi_bridge.rs`  
  Exposes summary and branch JSON methods.

- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift`  
  Splits message rendering, composer controls, conversation navigation, and message actions.

- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/MessageContentView.swift`  
  Renders text, reasoning, tool, error, and attachment parts.

- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationListView.swift`  
  Displays conversations and new chat entry point.

- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AttachmentService.swift`  
  Imports photos and validates link attachments.

- Create tests:
  - `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/State/ReasoningTagParserTests.swift`
  - `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/RuntimeStreamBufferTests.swift`
  - Extend `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/State/RuntimeEventReducerTests.swift`
  - Extend `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift`
  - Extend `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift`
  - Extend `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RuntimeDTOTests.swift`
  - Extend Rust tests in `local-ios-agent/rust-core/src/core/runtime.rs` and `local-ios-agent/rust-core/src/ffi_bridge.rs`

## Test Commands

Use these commands throughout:

```bash
swift test --package-path local-ios-agent/toolkit
```

Expected: all LocalAgentBridge and LocalNativeToolkit tests pass.

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
```

Expected: all Rust runtime tests pass.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  test
```

Expected: LocalAgentApp and LocalAgentAppTests build and test on a booted simulator.

---

### Task 1: Structured Message Parts and Reasoning Parser

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/MessageContent.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/ReasoningTagParser.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/State/ReasoningTagParserTests.swift`

- [ ] **Step 1: Write failing parser tests**

Create `ReasoningTagParserTests.swift`:

```swift
import Testing
@testable import LocalAgentApp

@Suite("Reasoning tag parser")
struct ReasoningTagParserTests {
    @Test("complete reasoning block is separated from answer text")
    func completeReasoningBlock() {
        var parser = ReasoningTagParser()

        parser.append("<think>I should inspect this.</think>The answer.")
        let parts = parser.finish()

        #expect(parts == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "I should inspect this.", isCollapsed: true, isStreaming: false)),
            .text(TextPartViewState(id: "text_1", text: "The answer.")),
        ])
    }

    @Test("split tags across chunks do not leak raw tags")
    func splitTagsAcrossChunks() {
        var parser = ReasoningTagParser()

        parser.append("<thi")
        parser.append("nk>hidden")
        parser.append("</thi")
        parser.append("nk>visible")
        let parts = parser.finish()

        #expect(parts == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "hidden", isCollapsed: true, isStreaming: false)),
            .text(TextPartViewState(id: "text_1", text: "visible")),
        ])
    }

    @Test("unclosed reasoning remains streaming and hides raw tag")
    func unclosedReasoningBlock() {
        var parser = ReasoningTagParser()

        parser.append("<think>still thinking")
        let parts = parser.snapshot(isFinal: false)

        #expect(parts == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "still thinking", isCollapsed: false, isStreaming: true)),
        ])
    }

    @Test("normal text without reasoning stays as text")
    func normalTextOnly() {
        var parser = ReasoningTagParser()

        parser.append("plain answer")
        let parts = parser.finish()

        #expect(parts == [
            .text(TextPartViewState(id: "text_0", text: "plain answer")),
        ])
    }
}
```

- [ ] **Step 2: Run parser test to verify failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:LocalAgentAppTests/ReasoningTagParserTests \
  test
```

Expected: FAIL because `ReasoningTagParser`, `MessagePartViewState`, `ReasoningPartViewState`, and `TextPartViewState` do not exist.

- [ ] **Step 3: Add message content types**

Create `MessageContent.swift` with these public-in-module types:

```swift
import Foundation

enum MessagePartViewState: Equatable, Identifiable, Sendable {
    case text(TextPartViewState)
    case reasoning(ReasoningPartViewState)
    case tool(ToolPartViewState)
    case error(ErrorPartViewState)

    var id: String {
        switch self {
        case .text(let part): return part.id
        case .reasoning(let part): return part.id
        case .tool(let part): return part.id
        case .error(let part): return part.id
        }
    }

    var plainText: String {
        switch self {
        case .text(let part): return part.text
        case .reasoning(let part): return part.text
        case .tool(let part): return part.displayText
        case .error(let part): return part.message
        }
    }
}

struct TextPartViewState: Equatable, Identifiable, Sendable {
    let id: String
    var text: String
}

struct ReasoningPartViewState: Equatable, Identifiable, Sendable {
    let id: String
    var text: String
    var isCollapsed: Bool
    var isStreaming: Bool
}

struct ToolPartViewState: Equatable, Identifiable, Sendable {
    let id: String
    var displayText: String
}

struct ErrorPartViewState: Equatable, Identifiable, Sendable {
    let id: String
    var message: String
}

enum MessageStreamingState: Equatable, Sendable {
    case idle
    case streaming
    case cancelled
    case failed(String)
    case reachedLimit

    var isStreaming: Bool {
        if case .streaming = self {
            return true
        }
        return false
    }
}

enum AttachmentKindViewState: String, Equatable, Sendable {
    case image
    case link
}

struct AttachmentViewState: Equatable, Identifiable, Sendable {
    let id: String
    var kind: AttachmentKindViewState
    var displayName: String
    var localPath: String?
    var urlString: String?
    var mimeType: String?
    var byteCount: Int?
}

struct AttachmentDraftViewState: Equatable, Identifiable, Sendable {
    let id: String
    var kind: AttachmentKindViewState
    var displayName: String
    var localPath: String?
    var urlString: String?
    var mimeType: String?
    var byteCount: Int?
}

struct UserDraftViewState: Equatable, Sendable {
    var text: String
    var attachments: [AttachmentDraftViewState]
    var targetParentEventId: String?

    init(
        text: String = "",
        attachments: [AttachmentDraftViewState] = [],
        targetParentEventId: String? = nil
    ) {
        self.text = text
        self.attachments = attachments
        self.targetParentEventId = targetParentEventId
    }
}
```

- [ ] **Step 4: Add incremental reasoning parser**

Create `ReasoningTagParser.swift`:

```swift
import Foundation

struct ReasoningTagParser: Equatable, Sendable {
    private enum Mode: Equatable, Sendable {
        case answer
        case reasoning
    }

    private var mode: Mode = .answer
    private var pending = ""
    private var answerBuffer = ""
    private var reasoningBuffer = ""

    mutating func append(_ chunk: String) {
        pending += chunk
        parsePending(final: false)
    }

    func snapshot(isFinal: Bool) -> [MessagePartViewState] {
        var copy = self
        copy.parsePending(final: isFinal)
        return copy.parts(isFinal: isFinal)
    }

    mutating func finish() -> [MessagePartViewState] {
        parsePending(final: true)
        return parts(isFinal: true)
    }

    private mutating func parsePending(final: Bool) {
        while !pending.isEmpty {
            switch mode {
            case .answer:
                if consume("<think>") {
                    flushPendingPrefixBeforePotentialTag("<think>", into: &answerBuffer, final: final)
                    if consume("<think>") {
                        mode = .reasoning
                    } else if !final {
                        return
                    }
                } else {
                    moveSafePrefix(into: &answerBuffer, final: final)
                    if !final && isPotentialPrefixOfTag(pending, tag: "<think>") {
                        return
                    }
                }
            case .reasoning:
                if consume("</think>") {
                    flushPendingPrefixBeforePotentialTag("</think>", into: &reasoningBuffer, final: final)
                    if consume("</think>") {
                        mode = .answer
                    } else if !final {
                        return
                    }
                } else {
                    moveSafePrefix(into: &reasoningBuffer, final: final)
                    if !final && isPotentialPrefixOfTag(pending, tag: "</think>") {
                        return
                    }
                }
            }
        }
    }

    private mutating func consume(_ tag: String) -> Bool {
        pending.hasPrefix(tag)
    }

    private mutating func flushPendingPrefixBeforePotentialTag(
        _ tag: String,
        into buffer: inout String,
        final: Bool
    ) {
        if let range = pending.range(of: tag) {
            buffer += String(pending[..<range.lowerBound])
            pending.removeSubrange(..<range.lowerBound)
        } else {
            moveSafePrefix(into: &buffer, final: final)
        }
    }

    private mutating func moveSafePrefix(into buffer: inout String, final: Bool) {
        if final {
            buffer += pending
            pending.removeAll()
            return
        }

        let maxTagLength = "</think>".count
        guard pending.count > maxTagLength else {
            return
        }

        let safeCount = pending.count - maxTagLength
        let split = pending.index(pending.startIndex, offsetBy: safeCount)
        buffer += pending[..<split]
        pending.removeSubrange(..<split)
    }

    private func isPotentialPrefixOfTag(_ value: String, tag: String) -> Bool {
        !value.isEmpty && tag.hasPrefix(value)
    }

    private func parts(isFinal: Bool) -> [MessagePartViewState] {
        var result: [MessagePartViewState] = []
        if !reasoningBuffer.isEmpty {
            result.append(.reasoning(ReasoningPartViewState(
                id: "reasoning_0",
                text: reasoningBuffer.trimmingCharacters(in: .whitespacesAndNewlines),
                isCollapsed: isFinal,
                isStreaming: !isFinal && mode == .reasoning
            )))
        }
        if !answerBuffer.isEmpty {
            result.append(.text(TextPartViewState(
                id: "text_\(result.count)",
                text: answerBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            )))
        }
        return result
    }
}
```

After adding this, run the parser tests. If any split-tag test fails, fix only `ReasoningTagParser` before changing reducers.

- [ ] **Step 5: Update message state with compatibility initializer**

Modify `AgentViewState.swift` so `AgentMessageViewState` becomes:

```swift
struct AgentMessageViewState: Equatable, Identifiable, Sendable {
    let id: String
    var sessionId: String?
    var parentId: String?
    let role: AgentMessageRole
    var parts: [MessagePartViewState]
    var attachments: [AttachmentViewState]
    var streaming: MessageStreamingState

    init(
        id: String,
        sessionId: String? = nil,
        parentId: String? = nil,
        role: AgentMessageRole,
        parts: [MessagePartViewState],
        attachments: [AttachmentViewState] = [],
        streaming: MessageStreamingState = .idle
    ) {
        self.id = id
        self.sessionId = sessionId
        self.parentId = parentId
        self.role = role
        self.parts = parts
        self.attachments = attachments
        self.streaming = streaming
    }

    init(id: String, role: AgentMessageRole, text: String, isStreaming: Bool) {
        self.init(
            id: id,
            role: role,
            parts: text.isEmpty ? [] : [.text(TextPartViewState(id: "\(id)_text_0", text: text))],
            streaming: isStreaming ? .streaming : .idle
        )
    }

    var text: String {
        parts.map(\.plainText).joined()
    }

    var isStreaming: Bool {
        get { streaming.isStreaming }
        set { streaming = newValue ? .streaming : .idle }
    }
}
```

- [ ] **Step 6: Run app tests for parser and state compatibility**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:LocalAgentAppTests/ReasoningTagParserTests \
  -only-testing:LocalAgentAppTests/RuntimeEventReducerTests \
  test
```

Expected: parser tests pass and existing reducer tests either pass or reveal the specific assertions to update in Task 2.

- [ ] **Step 7: Commit Task 1**

```bash
git add \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/MessageContent.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/ReasoningTagParser.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/State/ReasoningTagParserTests.swift
git commit -m "feat: add structured chat message parts"
```

---

### Task 2: Reducer Projects Reasoning Parts

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/RuntimeEventReducer.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/State/RuntimeEventReducerTests.swift`

- [ ] **Step 1: Add failing reducer tests for reasoning**

Extend `RuntimeEventReducerTests` with:

```swift
@Test("assistant reasoning tags are projected as reasoning parts")
func assistantReasoningProjectsAsParts() {
    var state = AgentViewState()

    RuntimeEventReducer.apply(
        event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
        to: &state
    )
    RuntimeEventReducer.apply(
        event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"<think>hidden"}"#),
        to: &state
    )
    RuntimeEventReducer.apply(
        event(id: "delta_2", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"</think>visible"}"#),
        to: &state
    )
    RuntimeEventReducer.apply(
        event(id: "completed", kind: .assistantMessageCompleted, payload: #"{"message_id":"assistant_1","text":"<think>hidden</think>visible"}"#),
        to: &state
    )

    #expect(state.messages.count == 1)
    #expect(state.messages[0].parts == [
        .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "hidden", isCollapsed: true, isStreaming: false)),
        .text(TextPartViewState(id: "text_1", text: "visible")),
    ])
    #expect(state.messages[0].text == "hiddenvisible")
    #expect(!state.messages[0].isStreaming)
}
```

- [ ] **Step 2: Run reducer test to verify failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:LocalAgentAppTests/RuntimeEventReducerTests \
  test
```

Expected: FAIL because `RuntimeEventReducer` still appends raw text.

- [ ] **Step 3: Add assistant text parsing helper**

In `RuntimeEventReducer.swift`, add a private helper:

```swift
private static func parsedAssistantParts(from text: String, isFinal: Bool) -> [MessagePartViewState] {
    var parser = ReasoningTagParser()
    parser.append(text)
    return isFinal ? parser.finish() : parser.snapshot(isFinal: false)
}
```

- [ ] **Step 4: Update delta and completion reducers**

Change assistant delta handling to rebuild structured parts from accumulated text. Keep a raw accumulated text source by using `message.text` until a dedicated stream buffer lands in Task 3:

```swift
private static func appendAssistantDelta(_ event: RuntimeEventDTO, to state: inout AgentViewState) {
    let text = payloadString("text", from: event.payload) ?? event.payload
    let messageId = assistantMessageId(for: event, in: state)
    if let index = state.messages.firstIndex(where: { $0.id == messageId }) {
        let combined = state.messages[index].text + text
        state.messages[index].parts = parsedAssistantParts(from: combined, isFinal: false)
        state.messages[index].streaming = .streaming
    } else {
        state.messages.append(AgentMessageViewState(
            id: messageId,
            sessionId: event.sessionId,
            parentId: event.parentId,
            role: .assistant,
            parts: parsedAssistantParts(from: text, isFinal: false),
            streaming: .streaming
        ))
    }
}

private static func completeAssistantMessage(_ event: RuntimeEventDTO, in state: inout AgentViewState) {
    let messageId = assistantMessageId(for: event, in: state)
    let completedText = payloadString("text", from: event.payload) ?? event.payload

    if let index = state.messages.firstIndex(where: { $0.id == messageId }) {
        state.messages[index].parts = parsedAssistantParts(from: completedText, isFinal: true)
        state.messages[index].streaming = .idle
    } else {
        state.messages.append(AgentMessageViewState(
            id: messageId,
            sessionId: event.sessionId,
            parentId: event.parentId,
            role: .assistant,
            parts: parsedAssistantParts(from: completedText, isFinal: true),
            streaming: .idle
        ))
    }
}
```

- [ ] **Step 5: Preserve metadata for user and tool messages**

Update user and tool append methods to set `sessionId` and `parentId`:

```swift
state.messages.append(AgentMessageViewState(
    id: event.id,
    sessionId: event.sessionId,
    parentId: event.parentId,
    role: .user,
    parts: [.text(TextPartViewState(id: "\(event.id)_text_0", text: event.payload))],
    streaming: .idle
))
```

Use the same pattern for tool messages with `.tool(ToolPartViewState(id: event.id, displayText: displayText))`.

- [ ] **Step 6: Run reducer tests**

Run the reducer-only command from Step 2.

Expected: all reducer tests pass. Existing assertions that compare `AgentMessageViewState(id:role:text:isStreaming:)` should still pass because Task 1 kept compatibility initialization and computed text.

- [ ] **Step 7: Commit Task 2**

```bash
git add \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/RuntimeEventReducer.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/State/RuntimeEventReducerTests.swift
git commit -m "feat: render assistant reasoning parts"
```

---

### Task 3: Stream Buffer and Terminal States

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/RuntimeStreamBuffer.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/RuntimeStreamBufferTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift`

- [ ] **Step 1: Write failing stream buffer tests**

Create `RuntimeStreamBufferTests.swift`:

```swift
import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Runtime stream buffer")
struct RuntimeStreamBufferTests {
    @Test("text deltas are coalesced by message id")
    func coalescesDeltasByMessageId() {
        var buffer = RuntimeStreamBuffer()

        #expect(buffer.append(delta("a", messageId: "assistant_1", text: "Hel")).isEmpty)
        #expect(buffer.append(delta("b", messageId: "assistant_1", text: "lo")).isEmpty)

        let flushed = buffer.flush()
        #expect(flushed.count == 1)
        #expect(flushed[0].payload == #"{"message_id":"assistant_1","text":"Hello"}"#)
    }

    @Test("terminal event flushes buffered delta before terminal")
    func terminalEventFlushesBufferedDelta() {
        var buffer = RuntimeStreamBuffer()

        _ = buffer.append(delta("a", messageId: "assistant_1", text: "partial"))
        let events = buffer.append(event(id: "failed", kind: .runFailed, payload: #"{"message":"failed"}"#))

        #expect(events.map(\.kind) == [.assistantTextDelta, .runFailed])
    }

    private func delta(_ id: String, messageId: String, text: String) -> RuntimeEventDTO {
        event(id: id, kind: .assistantTextDelta, payload: #"{"message_id":"\#(messageId)","text":"\#(text)"}"#)
    }

    private func event(id: String, kind: RuntimeEventKindDTO, payload: String) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 1,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}
```

- [ ] **Step 2: Run buffer tests to verify failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:LocalAgentAppTests/RuntimeStreamBufferTests \
  test
```

Expected: FAIL because `RuntimeStreamBuffer` does not exist.

- [ ] **Step 3: Implement stream buffer**

Create `RuntimeStreamBuffer.swift`:

```swift
import Foundation
import LocalAgentBridge

struct RuntimeStreamBuffer: Sendable {
    private var bufferedTextByMessageId: [String: String] = [:]
    private var representativeEventByMessageId: [String: RuntimeEventDTO] = [:]

    mutating func append(_ event: RuntimeEventDTO) -> [RuntimeEventDTO] {
        if event.kind == .assistantTextDelta,
           let messageId = Self.payloadString("message_id", from: event.payload),
           let text = Self.payloadString("text", from: event.payload) {
            bufferedTextByMessageId[messageId, default: ""] += text
            representativeEventByMessageId[messageId] = event
            if bufferedTextByMessageId[messageId, default: ""].count >= 512 {
                return flush(messageId: messageId)
            }
            return []
        }

        if Self.isTerminalOrStructural(event.kind) {
            var events = flush()
            events.append(event)
            return events
        }

        return [event]
    }

    mutating func flush() -> [RuntimeEventDTO] {
        let messageIds = bufferedTextByMessageId.keys.sorted()
        return messageIds.flatMap { flush(messageId: $0) }
    }

    private mutating func flush(messageId: String) -> [RuntimeEventDTO] {
        guard let text = bufferedTextByMessageId.removeValue(forKey: messageId),
              var event = representativeEventByMessageId.removeValue(forKey: messageId)
        else {
            return []
        }
        event.payload = #"{"message_id":"\#(messageId)","text":"\#(Self.escaped(text))"}"#
        return [event]
    }

    private static func isTerminalOrStructural(_ kind: RuntimeEventKindDTO) -> Bool {
        switch kind {
        case .assistantMessageCompleted, .runFailed, .runCancelled, .toolCallRequested, .toolResultMessage:
            return true
        default:
            return false
        }
    }

    private static func payloadString(_ key: String, from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object[key] as? String
    }

    private static func escaped(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }
}
```

- [ ] **Step 4: Add terminal state labels to app state**

In `AgentViewState.swift`, add:

```swift
enum RunTerminalReason: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
    case reachedLimit
}
```

Add to `AgentViewState`:

```swift
var lastTerminalReason: RunTerminalReason?
```

Initialize it in `AgentViewState.init`.

- [ ] **Step 5: Consume buffered events in service**

In `AgentRuntimeService.consume`, buffer incoming events and flush at terminal boundaries:

```swift
private func consume(
    _ stream: AgentTurnStreamDTO,
    state: inout AgentViewState,
    streamedEventIds: inout Set<String>,
    onEvent: @Sendable (RuntimeEventDTO) async -> Void
) async throws -> AgentTurnResultDTO {
    var buffer = RuntimeStreamBuffer()
    for try await event in stream.events {
        let events = buffer.append(event)
        for bufferedEvent in events {
            if let runId = bufferedEvent.runId {
                activeRun = .running(runId)
                state.phase = .running(runId: runId)
            }
            RuntimeEventReducer.apply(bufferedEvent, to: &state)
            streamedEventIds.insert(bufferedEvent.id)
            await onEvent(bufferedEvent)
        }
    }

    for bufferedEvent in buffer.flush() {
        RuntimeEventReducer.apply(bufferedEvent, to: &state)
        streamedEventIds.insert(bufferedEvent.id)
        await onEvent(bufferedEvent)
    }

    return try await stream.result.value
}
```

- [ ] **Step 6: Preserve partial output on failure**

In `RuntimeEventReducer.apply`, when handling `.runFailed`, set streaming messages to `.failed(message)` instead of clearing content:

```swift
private static func markStreamingMessagesFailed(in state: inout AgentViewState, message: String) {
    for index in state.messages.indices where state.messages[index].isStreaming {
        state.messages[index].streaming = .failed(message)
    }
}
```

Call this from `.runFailed`. For `.runCancelled`, set `.cancelled`.

- [ ] **Step 7: Run service and reducer tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:LocalAgentAppTests/RuntimeStreamBufferTests \
  -only-testing:LocalAgentAppTests/AgentRuntimeServiceTests \
  -only-testing:LocalAgentAppTests/RuntimeEventReducerTests \
  test
```

Expected: buffer, reducer, and service tests pass.

- [ ] **Step 8: Commit Task 3**

```bash
git add \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/RuntimeStreamBuffer.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/RuntimeEventReducer.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/RuntimeStreamBufferTests.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/State/RuntimeEventReducerTests.swift
git commit -m "feat: stabilize streamed chat output"
```

---

### Task 4: Runtime Conversation Summaries and Branch Loading

**Files:**
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `local-ios-agent/toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeDTOs.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeClient.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Test: `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RuntimeDTOTests.swift`

- [ ] **Step 1: Add DTO tests**

Extend `RuntimeDTOTests.swift`:

```swift
@Test("conversation summary decodes snake case fields")
func conversationSummaryDecodes() throws {
    let json = """
    {
      "session_id": "session_1",
      "title": "Hello",
      "active_leaf_id": "entry_2",
      "last_event_id": "entry_2",
      "last_updated_sequence": 4
    }
    """.data(using: .utf8)!

    let summary = try JSONDecoder().decode(ConversationSummaryDTO.self, from: json)

    #expect(summary.sessionId == "session_1")
    #expect(summary.title == "Hello")
    #expect(summary.activeLeafId == "entry_2")
    #expect(summary.lastEventId == "entry_2")
    #expect(summary.lastUpdatedSequence == 4)
}
```

- [ ] **Step 2: Run toolkit test to verify failure**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter RuntimeDTOTests
```

Expected: FAIL because `ConversationSummaryDTO` does not exist.

- [ ] **Step 3: Add Swift DTOs and protocols**

In `RuntimeDTOs.swift`, add:

```swift
public struct ConversationSummaryDTO: Codable, Equatable, Sendable {
    public var sessionId: String
    public var title: String
    public var activeLeafId: String?
    public var lastEventId: String?
    public var lastUpdatedSequence: UInt64

    public init(
        sessionId: String,
        title: String,
        activeLeafId: String?,
        lastEventId: String?,
        lastUpdatedSequence: UInt64
    ) {
        self.sessionId = sessionId
        self.title = title
        self.activeLeafId = activeLeafId
        self.lastEventId = lastEventId
        self.lastUpdatedSequence = lastUpdatedSequence
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case title
        case activeLeafId = "active_leaf_id"
        case lastEventId = "last_event_id"
        case lastUpdatedSequence = "last_updated_sequence"
    }
}
```

In `RuntimeClient.swift`, add:

```swift
public protocol ConversationRuntimeClient: Sendable {
    func conversationSummaries() async throws -> [ConversationSummaryDTO]
    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO]
}
```

- [ ] **Step 4: Add C bridge declarations**

In `CLocalAgentRuntime.h`, add:

```c
char *local_agent_runtime_bridge_conversation_summaries(
    LocalAgentRuntimeBridge *runtime
);

char *local_agent_runtime_bridge_active_branch(
    LocalAgentRuntimeBridge *runtime,
    const char *session_id,
    const char *leaf_id
);
```

- [ ] **Step 5: Add Rust runtime summary methods**

In `runtime.rs`, add a summary struct and methods near `session_ids`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationSummary {
    pub session_id: SessionId,
    pub title: String,
    pub active_leaf_id: Option<EntryId>,
    pub last_event_id: Option<EntryId>,
    pub last_updated_sequence: u64,
}
```

Add method:

```rust
pub fn conversation_summaries(&self) -> Result<Vec<ConversationSummary>, AgentError> {
    let mut summaries = Vec::new();
    for session_id in self.session_ids() {
        let active_leaf_id = self.store.active_leaf(&session_id)?;
        let last_event = self.store.last_event(&session_id)?;
        let title = match &active_leaf_id {
            Some(leaf_id) => self
                .store
                .active_branch(&session_id, leaf_id)?
                .into_iter()
                .find(|event| event.kind == EventKind::UserMessage)
                .map(|event| first_line_title(&event.payload))
                .unwrap_or_else(|| "New chat".to_string()),
            None => "New chat".to_string(),
        };
        summaries.push(ConversationSummary {
            session_id,
            title,
            active_leaf_id,
            last_event_id: last_event.as_ref().map(|event| event.id.clone()),
            last_updated_sequence: last_event.map(|event| event.sequence).unwrap_or(0),
        });
    }
    summaries.sort_by(|left, right| right.last_updated_sequence.cmp(&left.last_updated_sequence));
    Ok(summaries)
}

pub fn active_branch_events(
    &self,
    session_id: &SessionId,
    leaf_id: Option<EntryId>,
) -> Result<Vec<RuntimeEvent>, AgentError> {
    let leaf_id = match leaf_id {
        Some(leaf_id) => leaf_id,
        None => self
            .store
            .active_leaf(session_id)?
            .ok_or_else(|| AgentError::Storage(format!("session has no active leaf: {}", session_id.0)))?,
    };
    self.store.active_branch(session_id, &leaf_id)
}
```

Add helper:

```rust
fn first_line_title(payload: &str) -> String {
    let title = payload.lines().next().unwrap_or("New chat").trim();
    if title.is_empty() {
        "New chat".to_string()
    } else {
        title.chars().take(48).collect()
    }
}
```

- [ ] **Step 6: Add Rust FFI JSON methods**

In `ffi_bridge.rs`, add JSON struct:

```rust
#[derive(Serialize)]
struct ConversationSummaryJson {
    session_id: String,
    title: String,
    active_leaf_id: Option<String>,
    last_event_id: Option<String>,
    last_updated_sequence: u64,
}
```

Add bridge methods:

```rust
pub fn conversation_summaries_json(&self) -> Result<String, AgentError> {
    let summaries = match self {
        Self::InMemory(runtime) => runtime.lock()?.conversation_summaries()?,
        Self::Sqlite(runtime) => runtime.lock()?.conversation_summaries()?,
    };
    let summaries: Vec<_> = summaries
        .into_iter()
        .map(|summary| ConversationSummaryJson {
            session_id: summary.session_id.0,
            title: summary.title,
            active_leaf_id: summary.active_leaf_id.map(|id| id.0),
            last_event_id: summary.last_event_id.map(|id| id.0),
            last_updated_sequence: summary.last_updated_sequence,
        })
        .collect();
    to_json(&summaries)
}

pub fn active_branch_json(&self, session_id: &str, leaf_id: Option<&str>) -> Result<String, AgentError> {
    let session_id = SessionId(session_id.to_string());
    let leaf_id = leaf_id.filter(|value| !value.is_empty()).map(|value| EntryId(value.to_string()));
    let events = match self {
        Self::InMemory(runtime) => runtime.lock()?.active_branch_events(&session_id, leaf_id)?,
        Self::Sqlite(runtime) => runtime.lock()?.active_branch_events(&session_id, leaf_id)?,
    };
    let events: Vec<_> = events.iter().map(RuntimeEventJson::from_event).collect();
    to_json(&events)
}
```

Add extern functions:

```rust
#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_conversation_summaries(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_result(|| bridge_ref(runtime)?.conversation_summaries_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_active_branch(
    runtime: *mut RuntimeJsonBridge,
    session_id: *const c_char,
    leaf_id: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let session_id = c_str(session_id, "session_id")?;
        let leaf_id = optional_c_str(leaf_id, "leaf_id")?;
        bridge_ref(runtime)?.active_branch_json(&session_id, leaf_id.as_deref())
    })
}
```

If `optional_c_str` does not exist, add it next to the existing C string helpers.

- [ ] **Step 7: Wire Swift RustRuntimeClient**

Extend `RustRuntimeCFunctionTable` with function pointers for the two new C symbols. Add methods to `RustRuntimeClient`:

```swift
public func conversationSummaries() async throws -> [ConversationSummaryDTO] {
    try decode(functions.conversationSummaries(handle), as: [ConversationSummaryDTO].self)
}

public func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO] {
    try sessionId.withCString { sessionPointer in
        if let leafId {
            return try leafId.withCString { leafPointer in
                try decode(functions.activeBranch(handle, sessionPointer, leafPointer), as: [RuntimeEventDTO].self)
            }
        }
        return try decode(functions.activeBranch(handle, sessionPointer, nil), as: [RuntimeEventDTO].self)
    }
}
```

Make `RustRuntimeClient` conform to `ConversationRuntimeClient`.

- [ ] **Step 8: Run Rust and toolkit tests**

Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
swift test --package-path local-ios-agent/toolkit
```

Expected: Rust and Swift package tests pass.

- [ ] **Step 9: Commit Task 4**

```bash
git add \
  local-ios-agent/rust-core/src/core/runtime.rs \
  local-ios-agent/rust-core/src/ffi_bridge.rs \
  local-ios-agent/toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h \
  local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeDTOs.swift \
  local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeClient.swift \
  local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift \
  local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RuntimeDTOTests.swift
git commit -m "feat: expose conversation branches"
```

---

### Task 5: Conversation Service and ViewModel Intents

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ConversationService.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift`

- [ ] **Step 1: Add conversation state types**

In `AgentViewState.swift`, add:

```swift
struct ConversationSummaryViewState: Equatable, Identifiable, Sendable {
    var id: String { sessionId }
    let sessionId: String
    var title: String
    var activeLeafId: String?
    var lastEventId: String?
    var lastUpdatedSequence: UInt64
}

struct ConversationListViewState: Equatable, Sendable {
    var conversations: [ConversationSummaryViewState] = []
    var isPresented: Bool = false
    var errorMessage: String?
}
```

Add to `AgentViewState`:

```swift
var draft: UserDraftViewState
var conversations: ConversationListViewState
```

Keep a compatibility computed property if existing tests still set `draft` as `String`:

```swift
var draftText: String {
    get { draft.text }
    set { draft.text = newValue }
}
```

Then update tests and views to use `state.draft.text`.

- [ ] **Step 2: Add failing ViewModel tests**

Extend `AgentViewModelTests`:

```swift
@Test("new chat delegates to service and clears messages")
func newChatDelegatesToService() async {
    let service = ViewModelServiceStub(
        preparedState: AgentViewState(phase: .ready, currentSessionId: "session_1"),
        newChatState: AgentViewState(phase: .ready, messages: [], currentSessionId: "session_2")
    )
    let viewModel = AgentViewModel(
        service: service,
        initialState: AgentViewState(
            phase: .ready,
            messages: [AgentMessageViewState(id: "user_1", role: .user, text: "old", isStreaming: false)],
            currentSessionId: "session_1"
        )
    )

    await viewModel.newChat()

    #expect(await service.didCreateNewChat)
    #expect(viewModel.state.currentSessionId == "session_2")
    #expect(viewModel.state.messages.isEmpty)
}

@Test("fork from message stores target parent event id")
func forkFromMessageStoresParent() async {
    let service = ViewModelServiceStub()
    let viewModel = AgentViewModel(
        service: service,
        initialState: AgentViewState(phase: .ready, currentSessionId: "session_1")
    )

    await viewModel.forkFromMessage("entry_4")

    #expect(viewModel.state.draft.targetParentEventId == "entry_4")
}
```

Add stub methods to `ViewModelServiceStub`:

```swift
var didCreateNewChat = false
private let newChatState: AgentViewState

func newChat(state: AgentViewState) async throws -> AgentViewState {
    didCreateNewChat = true
    return newChatState
}

func loadConversations(state: AgentViewState) async throws -> AgentViewState {
    state
}

func selectConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
    state
}
```

- [ ] **Step 3: Extend AgentRuntimeServicing**

Add service requirements:

```swift
func newChat(state: AgentViewState) async throws -> AgentViewState
func loadConversations(state: AgentViewState) async throws -> AgentViewState
func selectConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState
```

Default implementations in the protocol extension should return unchanged state for tests that do not care.

- [ ] **Step 4: Implement service methods**

In `AgentRuntimeService`, implement:

```swift
func newChat(state: AgentViewState) async throws -> AgentViewState {
    guard activeRun == nil else {
        throw AgentRuntimeServiceError.duplicateRun
    }
    let sessionId = try await runtimeClient.createSession()
    var nextState = AgentViewState(phase: .ready, currentSessionId: sessionId)
    try await loadProviderState(into: &nextState)
    return try await loadConversations(state: nextState)
}
```

For `loadConversations`, guard for `ConversationRuntimeClient`:

```swift
func loadConversations(state: AgentViewState) async throws -> AgentViewState {
    guard let conversationClient = runtimeClient as? any ConversationRuntimeClient else {
        return state
    }
    var nextState = state
    nextState.conversations.conversations = try await conversationClient.conversationSummaries().map {
        ConversationSummaryViewState(
            sessionId: $0.sessionId,
            title: $0.title,
            activeLeafId: $0.activeLeafId,
            lastEventId: $0.lastEventId,
            lastUpdatedSequence: $0.lastUpdatedSequence
        )
    }
    return nextState
}
```

For `selectConversation`, load active branch and replay events through `RuntimeEventReducer`.

- [ ] **Step 5: Send with target parent id**

Change `AgentRuntimeService.sendMessage` to read:

```swift
let parentEventId = state.draft.targetParentEventId
```

Pass `parentEventId` to `sendMessageStream` and `sendMessage`.

Clear `nextState.draft.targetParentEventId` after the user message is accepted.

- [ ] **Step 6: Add ViewModel intents**

In `AgentViewModel`, add:

```swift
func newChat() async {
    do {
        state = try await service.newChat(state: state)
    } catch {
        state.errorMessage = error.localizedDescription
    }
}

func loadConversations() async {
    do {
        state = try await service.loadConversations(state: state)
    } catch {
        state.conversations.errorMessage = error.localizedDescription
    }
}

func selectConversation(_ sessionId: String) async {
    do {
        state = try await service.selectConversation(sessionId: sessionId, state: state)
    } catch {
        state.conversations.errorMessage = error.localizedDescription
    }
}

func forkFromMessage(_ messageId: String) async {
    state.draft.targetParentEventId = messageId
}
```

- [ ] **Step 7: Run app tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:LocalAgentAppTests/AgentViewModelTests \
  -only-testing:LocalAgentAppTests/AgentRuntimeServiceTests \
  test
```

Expected: ViewModel and service tests pass.

- [ ] **Step 8: Commit Task 5**

```bash
git add \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ConversationService.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift
git commit -m "feat: add conversation view model intents"
```

---

### Task 6: SwiftUI Message Rendering and Conversation UI

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/MessageContentView.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationListView.swift`

- [ ] **Step 1: Create message content rendering view**

Create `MessageContentView.swift`:

```swift
import SwiftUI

struct MessageContentView: View {
    let message: AgentMessageViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.parts) { part in
                switch part {
                case .text(let text):
                    Text(text.text)
                        .font(.body)
                        .textSelection(.enabled)
                case .reasoning(let reasoning):
                    ReasoningBlockView(reasoning: reasoning)
                case .tool(let tool):
                    Label(tool.displayText, systemImage: "wrench.and.screwdriver")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .error(let error):
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            if message.isStreaming {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

struct ReasoningBlockView: View {
    let reasoning: ReasoningPartViewState
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(reasoning.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(reasoning.isStreaming ? "Thinking..." : "Reasoning", systemImage: "brain.head.profile")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            isExpanded = !reasoning.isCollapsed
        }
    }
}
```

- [ ] **Step 2: Create conversation list sheet**

Create `ConversationListView.swift`:

```swift
import SwiftUI

struct ConversationListView: View {
    let conversations: [ConversationSummaryViewState]
    let activeSessionId: String?
    let onNewChat: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onNewChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }

                Section("Conversations") {
                    ForEach(conversations) { conversation in
                        Button {
                            onSelect(conversation.sessionId)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title)
                                        .lineLimit(1)
                                    Text(conversation.sessionId)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if conversation.sessionId == activeSessionId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chats")
        }
    }
}
```

- [ ] **Step 3: Update ChatView to use structured rendering**

In `ChatView`, replace `Text(messageText)` in `MessageBubble` with:

```swift
MessageContentView(message: message)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .foregroundStyle(foreground)
    .background {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(background)
    }
```

For assistant messages, use a wider max width:

```swift
.frame(maxWidth: UIScreen.main.bounds.width * (isUser ? 0.75 : 0.86), alignment: isUser ? .trailing : .leading)
```

- [ ] **Step 4: Add toolbar actions**

Add leading conversation list button and trailing new chat button:

```swift
ToolbarItem(placement: .topBarLeading) {
    Button {
        Task {
            await viewModel.loadConversations()
            viewModel.state.conversations.isPresented = true
        }
    } label: {
        Image(systemName: "sidebar.left")
    }
}

ToolbarItem(placement: .topBarTrailing) {
    Button {
        Task { await viewModel.newChat() }
    } label: {
        Image(systemName: "square.and.pencil")
    }
    .disabled(viewModel.state.phase.isRunning)
}
```

Keep provider selection in a `Menu` inside an overflow toolbar item if the toolbar becomes crowded.

- [ ] **Step 5: Present conversation sheet**

Add to `ChatView.body`:

```swift
.sheet(isPresented: $viewModel.state.conversations.isPresented) {
    ConversationListView(
        conversations: viewModel.state.conversations.conversations,
        activeSessionId: viewModel.state.currentSessionId,
        onNewChat: {
            viewModel.state.conversations.isPresented = false
            Task { await viewModel.newChat() }
        },
        onSelect: { sessionId in
            viewModel.state.conversations.isPresented = false
            Task { await viewModel.selectConversation(sessionId) }
        }
    )
}
```

- [ ] **Step 6: Add message action menu**

Wrap `MessageBubble` with `.contextMenu`:

```swift
.contextMenu {
    Button {
        UIPasteboard.general.string = message.text
    } label: {
        Label("Copy", systemImage: "doc.on.doc")
    }
    Button {
        Task { await viewModel.forkFromMessage(message.id) }
    } label: {
        Label("Fork from Here", systemImage: "arrow.triangle.branch")
    }
    if message.role == .assistant {
        Button {
            Task { await viewModel.regenerate(from: message.id) }
        } label: {
            Label("Regenerate", systemImage: "arrow.clockwise")
        }
    }
}
```

If `regenerate(from:)` is not implemented until Task 7, add the menu item in Task 7, not in this task.

- [ ] **Step 7: Run app build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "generic/platform=iOS Simulator" \
  build
```

Expected: build succeeds.

- [ ] **Step 8: Commit Task 6**

```bash
git add \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/MessageContentView.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationListView.swift
git commit -m "feat: add chat conversation UI"
```

---

### Task 7: Regenerate, Continue, Fork, and Edit-Resend

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift`

- [ ] **Step 1: Add failing ViewModel tests for branch actions**

Add to `AgentViewModelTests`:

```swift
@Test("regenerate delegates assistant message id")
func regenerateDelegatesMessageId() async {
    let service = ViewModelServiceStub()
    let viewModel = AgentViewModel(service: service, initialState: AgentViewState(phase: .ready, currentSessionId: "session_1"))

    await viewModel.regenerate(from: "assistant_1")

    #expect(await service.regeneratedMessageIds == ["assistant_1"])
}

@Test("continue generation sends continue instruction from active leaf")
func continueGenerationDelegates() async {
    let service = ViewModelServiceStub()
    let viewModel = AgentViewModel(service: service, initialState: AgentViewState(phase: .ready, currentSessionId: "session_1"))

    await viewModel.continueGeneration()

    #expect(await service.didContinueGeneration)
}
```

Add stub properties:

```swift
var regeneratedMessageIds: [String] = []
var didContinueGeneration = false

func regenerate(from messageId: String, state: AgentViewState) async throws -> AgentViewState {
    regeneratedMessageIds.append(messageId)
    return state
}

func continueGeneration(state: AgentViewState) async throws -> AgentViewState {
    didContinueGeneration = true
    return state
}
```

- [ ] **Step 2: Extend AgentRuntimeServicing**

Add:

```swift
func regenerate(from messageId: String, state: AgentViewState) async throws -> AgentViewState
func continueGeneration(state: AgentViewState) async throws -> AgentViewState
func editAndResend(messageId: String, text: String, state: AgentViewState) async throws -> AgentViewState
```

- [ ] **Step 3: Implement ViewModel methods**

Add:

```swift
func regenerate(from messageId: String) async {
    do {
        state = try await service.regenerate(from: messageId, state: state)
    } catch {
        state.errorMessage = error.localizedDescription
    }
}

func continueGeneration() async {
    do {
        state = try await service.continueGeneration(state: state)
    } catch {
        state.errorMessage = error.localizedDescription
    }
}

func editAndResend(messageId: String, text: String) async {
    do {
        state = try await service.editAndResend(messageId: messageId, text: text, state: state)
    } catch {
        state.errorMessage = error.localizedDescription
    }
}
```

- [ ] **Step 4: Implement service branch operations**

For regenerate:

```swift
func regenerate(from messageId: String, state: AgentViewState) async throws -> AgentViewState {
    guard let assistant = state.messages.first(where: { $0.id == messageId }),
          assistant.role == .assistant,
          let parentId = assistant.parentId
    else {
        return state
    }
    var nextState = state
    nextState.draft.targetParentEventId = parentId
    return try await sendMessage("Please regenerate the previous answer.", state: nextState)
}
```

For continue:

```swift
func continueGeneration(state: AgentViewState) async throws -> AgentViewState {
    var nextState = state
    nextState.draft.targetParentEventId = state.messages.last?.id
    return try await sendMessage("Continue.", state: nextState)
}
```

For edit-resend:

```swift
func editAndResend(messageId: String, text: String, state: AgentViewState) async throws -> AgentViewState {
    guard let message = state.messages.first(where: { $0.id == messageId }),
          message.role == .user
    else {
        return state
    }
    var nextState = state
    nextState.draft.targetParentEventId = message.parentId
    return try await sendMessage(text, state: nextState)
}
```

- [ ] **Step 5: Add UI actions**

In message context menu:

- Assistant messages: `Regenerate`, `Continue`, `Fork from Here`.
- User messages: `Edit and Resend`, `Fork from Here`.

Use a simple `.alert` with text field for edit-resend if the codebase does not yet have a custom sheet. The alert should store draft edit text in `@State private var editingMessage: AgentMessageViewState?` and `@State private var editText = ""`.

- [ ] **Step 6: Run ViewModel tests and build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:LocalAgentAppTests/AgentViewModelTests \
  test
```

Then run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "generic/platform=iOS Simulator" \
  build
```

Expected: tests and build pass.

- [ ] **Step 7: Commit Task 7**

```bash
git add \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift
git commit -m "feat: add chat branch actions"
```

---

### Task 8: Photo and Link Attachments

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AttachmentService.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/MessageContentView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift`

- [ ] **Step 1: Create attachment service**

Create `AttachmentService.swift`:

```swift
import Foundation
import UniformTypeIdentifiers

enum AttachmentServiceError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedImageType
}

actor AttachmentService {
    private let fileManager: FileManager
    private let directory: URL

    init(fileManager: FileManager = .default, directory: URL) {
        self.fileManager = fileManager
        self.directory = directory
    }

    func linkDraft(from rawValue: String) throws -> AttachmentDraftViewState {
        guard let url = URL(string: rawValue),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased())
        else {
            throw AttachmentServiceError.invalidURL
        }

        return AttachmentDraftViewState(
            id: "link_\(UUID().uuidString)",
            kind: .link,
            displayName: url.host() ?? url.absoluteString,
            localPath: nil,
            urlString: url.absoluteString,
            mimeType: nil,
            byteCount: nil
        )
    }

    func imageDraft(data: Data, suggestedName: String, mimeType: String) async throws -> AttachmentDraftViewState {
        guard mimeType.hasPrefix("image/") else {
            throw AttachmentServiceError.unsupportedImageType
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString)-\(suggestedName)"
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return AttachmentDraftViewState(
            id: "image_\(UUID().uuidString)",
            kind: .image,
            displayName: suggestedName,
            localPath: url.path,
            urlString: nil,
            mimeType: mimeType,
            byteCount: data.count
        )
    }
}
```

- [ ] **Step 2: Add ViewModel attachment intents**

In `AgentViewModel`, inject `AttachmentService` or create it in composition. Add:

```swift
func addLink(_ rawValue: String) async {
    do {
        let draft = try await attachmentService.linkDraft(from: rawValue)
        state.draft.attachments.append(draft)
    } catch {
        state.errorMessage = error.localizedDescription
    }
}

func removeAttachment(_ id: String) {
    state.draft.attachments.removeAll { $0.id == id }
}
```

For PhotosUI selection, keep the PhotosUI-specific loading in `ChatView` and pass `Data` to the ViewModel:

```swift
func addImage(data: Data, suggestedName: String, mimeType: String) async {
    do {
        let draft = try await attachmentService.imageDraft(data: data, suggestedName: suggestedName, mimeType: mimeType)
        state.draft.attachments.append(draft)
    } catch {
        state.errorMessage = error.localizedDescription
    }
}
```

- [ ] **Step 3: Include draft attachments in visible user message**

In `AgentRuntimeService.sendMessage`, when adding or reducing the user event, include current draft attachments in the local view state. First version may include URL text in model-visible prompt:

```swift
private func promptText(for draft: UserDraftViewState) -> String {
    let links = draft.attachments.compactMap(\.urlString)
    if links.isEmpty {
        return draft.text
    }
    return ([draft.text] + links.map { "Link: \($0)" }).joined(separator: "\n")
}
```

Use `promptText(for: state.draft)` instead of raw `text` when the ViewModel sends a draft.

- [ ] **Step 4: Add composer attachment UI**

In `ChatView`, replace the plain input HStack with:

- `Menu` button using `plus.circle`.
- Menu action `Add Link`.
- `PhotosPicker` for images.
- Thumbnail/chip shelf above the text field.

The shelf should render:

```swift
ForEach(viewModel.state.draft.attachments) { attachment in
    Label(attachment.displayName, systemImage: attachment.kind == .image ? "photo" : "link")
}
```

- [ ] **Step 5: Render message attachments**

In `MessageContentView`, after parts:

```swift
ForEach(message.attachments) { attachment in
    Label(attachment.displayName, systemImage: attachment.kind == .image ? "photo" : "link")
        .font(.footnote)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color(.tertiarySystemBackground), in: Capsule())
}
```

- [ ] **Step 6: Run build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "generic/platform=iOS Simulator" \
  build
```

Expected: build succeeds.

- [ ] **Step 7: Commit Task 8**

```bash
git add \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AttachmentService.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/MessageContentView.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift
git commit -m "feat: add chat attachments"
```

---

### Task 9: Final Verification and Documentation

**Files:**
- Modify: `local-ios-agent/docs/model-providers/simulator-llamacpp-contract.md`
- Modify: `local-ios-agent/docs/superpowers/specs/2026-06-22-ios-chat-experience-design.md`

- [ ] **Step 1: Run full local test suite**

Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
swift test --package-path local-ios-agent/toolkit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -derivedDataPath /private/tmp/local-agent-deriveddata \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  test
```

Expected: all tests pass.

- [ ] **Step 2: Run a simulator manual smoke**

In Xcode or via the existing simulator script, verify:

```text
1. Start a new chat.
2. Ask a question that triggers <think> output.
3. Confirm reasoning renders in a block and raw tags are hidden.
4. Ask for a long answer.
5. Confirm the UI remains scrollable and partial output is preserved if stopped.
6. Open the conversation list and switch back to the chat.
7. Fork from an earlier message and send a new prompt.
8. Add a link attachment and send.
9. Add a photo attachment and confirm it renders as an attachment chip.
```

- [ ] **Step 3: Update local inference docs**

In `docs/model-providers/simulator-llamacpp-contract.md`, document:

```text
Interactive chat should use max_new_tokens between 512 and 1024.
Smoke tests may use 128.
Xcode Run must include LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON.
llama.framework must be linked and embedded for GUI runs.
```

- [ ] **Step 4: Mark spec implemented**

Update `2026-06-22-ios-chat-experience-design.md`:

```text
Status: Implemented
```

Add a short implementation note with the final commit range.

- [ ] **Step 5: Commit Task 9**

```bash
git add \
  local-ios-agent/docs/model-providers/simulator-llamacpp-contract.md \
  local-ios-agent/docs/superpowers/specs/2026-06-22-ios-chat-experience-design.md
git commit -m "docs: document ios chat experience"
```

## Self-Review

Spec coverage:

- Reasoning blocks: Tasks 1, 2, and 6.
- Long streaming output: Task 3.
- Terminal states and partial output: Task 3.
- New chat and conversation switching: Tasks 4, 5, and 6.
- Branch, fork, regenerate, edit-resend: Tasks 4, 5, and 7.
- Photos and links: Task 8.
- SwiftUI and MVVM decoupling: Tasks 5, 6, 7, and 8.
- Tests: every task includes focused tests or build verification.

Type consistency:

- `MessagePartViewState`, `ReasoningPartViewState`, `TextPartViewState`, `AttachmentDraftViewState`, and `UserDraftViewState` are introduced in Task 1 and reused consistently.
- Conversation DTOs are introduced in Task 4 before service and UI tasks depend on them.
- `parentEventId` is already supported by `RuntimeClient`; Tasks 4 and 5 expose the missing branch loading and service-level use.

Placeholder scan:

- This plan uses concrete paths, commands, type names, test snippets, and commit messages.
- No task depends on an unspecified implementation from another task.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-22-ios-chat-experience-implementation.md`. Two execution options:

1. **Subagent-Driven (recommended)** - Dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
