import Foundation
import LocalAgentBridge
import Testing
import UIKit
@testable import LocalAgentApp

@Suite("Agent view model")
@MainActor
struct AgentViewModelTests {
    @Test("empty draft is not sent")
    func emptyDraftIsNotSent() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, draft: "   ", currentSessionId: "session_1")
        )

        await viewModel.send()

        #expect(await service.sentTexts.isEmpty)
        #expect(viewModel.state.draftText == "   ")
    }

    @Test("successful send trims draft and updates state")
    func successfulSendTrimsDraftAndUpdatesState() async {
        let service = ViewModelServiceStub(
            sentState: AgentViewState(
                phase: .ready,
                messages: [
                    AgentMessageViewState(id: "user_1", role: .user, text: "hello", isStreaming: false),
                ],
                currentSessionId: "session_1"
            )
        )
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, draft: " hello ", currentSessionId: "session_1")
        )

        await viewModel.send()

        #expect(await service.sentTexts == ["hello"])
        #expect(viewModel.state.draftText == "")
        #expect(viewModel.state.messages.map(\.text) == ["hello"])
    }

    @Test("send allows attachment only draft")
    func sendAllowsAttachmentOnlyDraft() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(
                phase: .ready,
                draft: UserDraftViewState(
                    text: "   ",
                    attachments: [
                        AttachmentDraftViewState(
                            id: "link_1",
                            kind: .link,
                            displayName: "example.com",
                            localPath: nil,
                            urlString: "https://example.com",
                            mimeType: nil,
                            byteCount: nil
                        ),
                    ]
                ),
                currentSessionId: "session_1"
            )
        )

        await viewModel.send()

        #expect(await service.sentTexts == [""])
    }

    @Test("send applies streamed event before final state")
    func sendAppliesStreamedEventBeforeFinalState() async {
        let service = StreamingViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, draft: "hello", currentSessionId: "session_1")
        )

        let sendTask = Task {
            await viewModel.send()
        }
        await service.waitForStreamedEvent()

        #expect(viewModel.state.messages.map(\.text) == ["partial"])

        await service.releaseFinalState()
        await sendTask.value

        #expect(viewModel.state.messages.map(\.text) == ["final"])
    }

    @Test("streamed user message preserves visible attachments")
    func streamedUserMessagePreservesVisibleAttachments() async {
        let service = AttachmentStreamingViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(
                phase: .ready,
                draft: UserDraftViewState(
                    text: "hello",
                    attachments: [
                        AttachmentDraftViewState(
                            id: "link_1",
                            kind: .link,
                            displayName: "example.com",
                            localPath: nil,
                            urlString: "https://example.com",
                            mimeType: nil,
                            byteCount: nil
                        ),
                    ]
                ),
                currentSessionId: "session_1"
            )
        )

        let sendTask = Task {
            await viewModel.send()
        }
        await service.waitForStreamedEvent()

        #expect(viewModel.state.draft.attachments.isEmpty)
        #expect(viewModel.state.messages.first?.text == "hello")
        #expect(viewModel.state.messages.first?.attachments.count == 1)

        await service.releaseFinalState()
        await sendTask.value
    }


    @Test("send failure marks streamed partial output failed")
    func sendFailureMarksStreamedPartialOutputFailed() async {
        let service = FailingStreamingViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, draft: "hello", currentSessionId: "session_1")
        )

        await viewModel.send()

        #expect(viewModel.state.phase == .failed(message: "stream stopped"))
        #expect(viewModel.state.errorMessage == "stream stopped")
        #expect(viewModel.state.lastTerminalReason == .failed("stream stopped"))
        #expect(viewModel.state.messages.map(\.text) == ["partial"])
        #expect(viewModel.state.messages[0].streaming == .failed("stream stopped"))
    }

    @Test("select provider delegates to service")
    func selectProviderDelegatesToService() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        await viewModel.selectProvider("local_llm")

        #expect(await service.selectedProviderIds == ["local_llm"])
    }

    @Test("new chat delegates to service and clears messages")
    func newChatDelegatesToService() async {
        let service = ViewModelServiceStub(
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

    @Test("start chat handoff creates new chat and prefills draft")
    func startChatHandoffCreatesNewChatAndPrefillsDraft() async {
        let service = ViewModelServiceStub(
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

        await viewModel.startNewChat(prefilledText: "  explain this image  ")

        #expect(await service.didCreateNewChat)
        #expect(await service.sentTexts.isEmpty)
        #expect(viewModel.state.currentSessionId == "session_2")
        #expect(viewModel.state.messages.isEmpty)
        #expect(viewModel.state.draftText == "explain this image")
    }

    @Test("fork from message creates and selects a new conversation")
    func forkFromMessageCreatesAndSelectsNewConversation() async {
        let service = ViewModelServiceStub(
            forkedState: AgentViewState(
                phase: .ready,
                messages: [
                    AgentMessageViewState(id: "assistant_copy", role: .assistant, text: "answer", isStreaming: false),
                ],
                currentSessionId: "session_2"
            )
        )
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(
                phase: .ready,
                messages: [
                    AgentMessageViewState(
                        id: "assistant_ui_message",
                        branchLeafId: "assistant_completed_event",
                        role: .assistant,
                        parts: [.text(TextPartViewState(id: "assistant_text", text: "answer"))]
                    ),
                ],
                currentSessionId: "session_1"
            )
        )

        await viewModel.forkFromMessage("assistant_ui_message")

        #expect(await service.forkRequests == [
            ViewModelServiceStub.ForkRequest(sessionId: "session_1", leafId: "assistant_completed_event"),
        ])
        #expect(viewModel.state.currentSessionId == "session_2")
        #expect(viewModel.state.messages.map(\.text) == ["answer"])
    }

    @Test("regenerate delegates assistant message id")
    func regenerateDelegatesMessageId() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        await viewModel.regenerate(from: "assistant_1")

        #expect(await service.regeneratedMessageIds == ["assistant_1"])
    }

    @Test("add link appends draft attachment")
    func addLinkAppendsDraftAttachment() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            attachmentService: AttachmentService(directory: attachmentTestDirectory()),
            initialState: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        await viewModel.addLink("https://example.com/path")

        #expect(viewModel.state.draft.attachments.count == 1)
        #expect(viewModel.state.draft.attachments[0].kind == .link)
        #expect(viewModel.state.draft.attachments[0].displayName == "example.com")
        #expect(viewModel.state.draft.attachments[0].urlString == "https://example.com/path")
    }

    @Test("invalid link reports error")
    func invalidLinkReportsError() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            attachmentService: AttachmentService(directory: attachmentTestDirectory()),
            initialState: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        await viewModel.addLink("https://")

        #expect(viewModel.state.draft.attachments.isEmpty)
        #expect(viewModel.state.errorMessage == "Enter a valid http or https URL.")
    }

    @Test("add image writes draft attachment")
    func addImageWritesDraftAttachment() async throws {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            attachmentService: AttachmentService(directory: attachmentTestDirectory()),
            initialState: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        let imageData = try samplePNGData()

        await viewModel.addImage(data: imageData, suggestedName: "photo.png", mimeType: "image/png")

        let attachment = try #require(viewModel.state.draft.attachments.first)
        #expect(attachment.kind == .image)
        #expect(attachment.displayName == "photo.png")
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.byteCount == imageData.count)
        #expect(attachment.imageWidth == 2)
        #expect(attachment.imageHeight == 2)
        #expect(attachment.rgbDataBase64 != nil)
        #expect(attachment.localPath != nil)
        let localPath = try #require(attachment.localPath)
        #expect(FileManager.default.contents(atPath: localPath) == imageData)
    }

    @Test("unsupported image type reports error")
    func unsupportedImageTypeReportsError() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            attachmentService: AttachmentService(directory: attachmentTestDirectory()),
            initialState: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        await viewModel.addImage(data: Data([1, 2, 3]), suggestedName: "note.txt", mimeType: "text/plain")

        #expect(viewModel.state.draft.attachments.isEmpty)
        #expect(viewModel.state.errorMessage == "Only image attachments are supported.")
    }

    @Test("remove attachment deletes matching draft")
    func removeAttachmentDeletesMatchingDraft() async throws {
        let directory = attachmentTestDirectory()
        let service = ViewModelServiceStub()
        let attachmentService = AttachmentService(directory: directory)
        let draft = try await attachmentService.imageDraft(
            data: samplePNGData(),
            suggestedName: "photo.png",
            mimeType: "image/png"
        )
        let viewModel = AgentViewModel(
            service: service,
            attachmentService: attachmentService,
            initialState: AgentViewState(
                phase: .ready,
                draft: UserDraftViewState(
                    attachments: [draft]
                ),
                currentSessionId: "session_1"
            )
        )

        await viewModel.removeAttachment(draft.id)

        #expect(viewModel.state.draft.attachments.isEmpty)
        let localPath = try #require(draft.localPath)
        #expect(!FileManager.default.fileExists(atPath: localPath))
    }
}

private func attachmentTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalAgentAttachmentTests")
        .appendingPathComponent(UUID().uuidString)
}

private func samplePNGData() throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format)
    let image = renderer.image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    return try #require(image.pngData())
}

private actor ViewModelServiceStub: AgentRuntimeServicing {
    struct ForkRequest: Equatable, Sendable {
        var sessionId: String
        var leafId: String
    }

    var sentTexts: [String] = []
    var selectedProviderIds: [String] = []
    var didCreateNewChat = false
    var regeneratedMessageIds: [String] = []
    var forkRequests: [ForkRequest] = []
    private let preparedState: AgentViewState
    private let sentState: AgentViewState
    private let newChatState: AgentViewState
    private let forkedState: AgentViewState

    init(
        preparedState: AgentViewState = AgentViewState(phase: .ready, currentSessionId: "session_1"),
        sentState: AgentViewState = AgentViewState(phase: .ready, currentSessionId: "session_1"),
        newChatState: AgentViewState = AgentViewState(phase: .ready, messages: [], currentSessionId: "session_2"),
        forkedState: AgentViewState = AgentViewState(phase: .ready, currentSessionId: "session_2")
    ) {
        self.preparedState = preparedState
        self.sentState = sentState
        self.newChatState = newChatState
        self.forkedState = forkedState
    }

    func prepare() async throws -> AgentViewState {
        preparedState
    }

    func sendMessage(
        _ text: String,
        state: AgentViewState,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState {
        sentTexts.append(text)
        return sentState
    }

    func cancel(state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func selectProvider(_ providerId: String, state: AgentViewState) async throws -> AgentViewState {
        selectedProviderIds.append(providerId)
        return state
    }

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

    func forkConversation(sessionId: String, leafId: String, state: AgentViewState) async throws -> AgentViewState {
        forkRequests.append(ForkRequest(sessionId: sessionId, leafId: leafId))
        return forkedState
    }

    func regenerate(from messageId: String, state: AgentViewState) async throws -> AgentViewState {
        regeneratedMessageIds.append(messageId)
        return state
    }
}

private actor StreamingViewModelServiceStub: AgentRuntimeServicing {
    private var streamedEventContinuation: CheckedContinuation<Void, Never>?
    private var finalStateContinuation: CheckedContinuation<Void, Never>?
    private var didStreamEvent = false
    private var canReturnFinalState = false

    func prepare() async throws -> AgentViewState {
        AgentViewState(phase: .ready, currentSessionId: "session_1")
    }

    func sendMessage(
        _ text: String,
        state: AgentViewState,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState {
        await onEvent(RuntimeEventDTO(
            id: "delta_1",
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 1,
            depth: 0,
            kind: .assistantTextDelta,
            payload: "partial",
            blobRefs: []
        ))
        didStreamEvent = true
        streamedEventContinuation?.resume()
        streamedEventContinuation = nil

        if !canReturnFinalState {
            await withCheckedContinuation { continuation in
                finalStateContinuation = continuation
            }
        }

        return AgentViewState(
            phase: .ready,
            messages: [
                AgentMessageViewState(
                    id: "assistant_final",
                    role: .assistant,
                    text: "final",
                    isStreaming: false
                ),
            ],
            currentSessionId: "session_1"
        )
    }

    func waitForStreamedEvent() async {
        if didStreamEvent {
            return
        }
        await withCheckedContinuation { continuation in
            streamedEventContinuation = continuation
        }
    }

    func releaseFinalState() {
        canReturnFinalState = true
        finalStateContinuation?.resume()
        finalStateContinuation = nil
    }

    func cancel(state: AgentViewState) async throws -> AgentViewState {
        state
    }
}

private actor AttachmentStreamingViewModelServiceStub: AgentRuntimeServicing {
    private var streamedEventContinuation: CheckedContinuation<Void, Never>?
    private var finalStateContinuation: CheckedContinuation<Void, Never>?
    private var didStreamEvent = false
    private var canReturnFinalState = false

    func prepare() async throws -> AgentViewState {
        AgentViewState(phase: .ready, currentSessionId: "session_1")
    }

    func sendMessage(
        _ text: String,
        state: AgentViewState,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState {
        await onEvent(RuntimeEventDTO(
            id: "user_1",
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 1,
            depth: 0,
            kind: .userMessage,
            payload: "hello\nLink: https://example.com",
            blobRefs: []
        ))
        didStreamEvent = true
        streamedEventContinuation?.resume()
        streamedEventContinuation = nil

        if !canReturnFinalState {
            await withCheckedContinuation { continuation in
                finalStateContinuation = continuation
            }
        }

        return AgentViewState(
            phase: .ready,
            messages: [
                AgentMessageViewState(
                    id: "user_1",
                    role: .user,
                    text: "hello",
                    isStreaming: false
                ),
            ],
            currentSessionId: "session_1"
        )
    }

    func waitForStreamedEvent() async {
        if didStreamEvent {
            return
        }
        await withCheckedContinuation { continuation in
            streamedEventContinuation = continuation
        }
    }

    func releaseFinalState() {
        canReturnFinalState = true
        finalStateContinuation?.resume()
        finalStateContinuation = nil
    }

    func cancel(state: AgentViewState) async throws -> AgentViewState {
        state
    }
}

private actor FailingStreamingViewModelServiceStub: AgentRuntimeServicing {
    func prepare() async throws -> AgentViewState {
        AgentViewState(phase: .ready, currentSessionId: "session_1")
    }

    func sendMessage(
        _ text: String,
        state: AgentViewState,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState {
        await onEvent(RuntimeEventDTO(
            id: "delta_1",
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 1,
            depth: 0,
            kind: .assistantTextDelta,
            payload: "partial",
            blobRefs: []
        ))
        throw StreamingViewModelServiceError.streamStopped
    }

    func cancel(state: AgentViewState) async throws -> AgentViewState {
        state
    }
}

private enum StreamingViewModelServiceError: LocalizedError {
    case streamStopped

    var errorDescription: String? {
        "stream stopped"
    }
}
