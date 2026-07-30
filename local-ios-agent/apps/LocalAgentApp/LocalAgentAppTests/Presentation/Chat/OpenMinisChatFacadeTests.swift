import LocalAgentBridge
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentApp

@Suite("OpenMinis chat presentation facade")
@MainActor
struct OpenMinisChatFacadeTests {
    @Test("send submits the current draft exactly once")
    func sendSubmitsCurrentDraftExactlyOnce() async {
        let recorder = SubmissionRecorder()
        let viewModel = AIChatViewModel(
            conversationStreamID: "conversation-1",
            submit: { submission, _ in
                recorder.append(submission)
            }
        )
        viewModel.draft = "Inspect the repository"

        await viewModel.send()

        let submissions = recorder.submissions
        #expect(submissions.count == 1)
        #expect(submissions.first?.conversationStreamID == "conversation-1")
        #expect(submissions.first?.text == "Inspect the repository")
        #expect(submissions.first?.attachments.isEmpty == true)
    }

    @Test("conversation switching changes the stream used by later commands")
    func conversationSwitchingChangesTheSubmissionStream() async {
        let recorder = SubmissionRecorder()
        let viewModel = AIChatViewModel(
            conversationStreamID: "conversation-1",
            submit: { submission, _ in
                recorder.append(submission)
            },
            performTranscriptAction: { streamID, action, _ in
                recorder.append(streamID: streamID, action: action)
            },
            selectConversation: { streamID in
                recorder.selectedConversationIDs.append(streamID)
            }
        )

        viewModel.switchConversation(to: "conversation-2")
        viewModel.draft = "Continue here"
        await viewModel.send()
        await viewModel.retry(anchorEventID: "assistant-1")

        #expect(viewModel.conversationStreamID == "conversation-2")
        #expect(recorder.submissions.map(\.conversationStreamID) == [
            "conversation-2",
        ])
        #expect(recorder.actions == [
            .init(
                streamID: "conversation-2",
                action: .retry(anchorEventID: "assistant-1")
            ),
        ])
        #expect(recorder.selectedConversationIDs == ["conversation-2"])
    }

    @Test("running state follows projections and stop targets the active Rust run")
    func runningStateAndStopFollowTheActiveRun() async {
        let store = ChatStore()
        let recorder = StopRecorder()
        let viewModel = AIChatViewModel(
            conversationStreamID: "conversation-1",
            submit: { _, _ in },
            chatStore: store,
            stopRun: { runID in recorder.runIDs.append(runID) }
        )

        store.markRunAccepted(
            conversationStreamID: "conversation-1",
            runID: "run-1"
        )
        #expect(viewModel.isRunning)

        await viewModel.stop()

        #expect(recorder.runIDs == ["run-1"])
    }

    @Test("stop cancels a submission before Rust returns the active run")
    func stopCancelsPendingSubmission() async {
        let recorder = SubmissionCancellationRecorder()
        let viewModel = AIChatViewModel(
            conversationStreamID: "conversation-1",
            submit: { _, _ in
                recorder.started = true
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch is CancellationError {
                    recorder.cancelled = true
                    throw CancellationError()
                }
            }
        )
        viewModel.draft = "Start a long request"
        let sendTask = Task { await viewModel.send() }
        while !recorder.started {
            await Task.yield()
        }

        await viewModel.stop()
        let cancelledByStop = recorder.cancelled
        sendTask.cancel()
        await sendTask.value

        #expect(cancelledByStop)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("stop targets the predicted run while command submission is pending")
    func stopTargetsPredictedRunDuringSubmission() async {
        let recorder = SubmissionCancellationRecorder()
        let stops = StopRecorder()
        let viewModel = AIChatViewModel(
            conversationStreamID: "conversation-1",
            submit: { _, reportRunID in
                reportRunID("run-predicted")
                recorder.started = true
                try await Task.sleep(for: .seconds(10))
            },
            stopRun: { runID in stops.runIDs.append(runID) }
        )
        viewModel.draft = "Start a long request"
        let sendTask = Task { await viewModel.send() }
        while !recorder.started {
            await Task.yield()
        }

        await viewModel.stop()
        await sendTask.value

        #expect(stops.runIDs == ["run-predicted"])
        #expect(viewModel.errorMessage == nil)
    }

    @Test("attachment drafts become stable Rust transcript references")
    func attachmentDraftBecomesTranscriptReference() throws {
        let attachment = AttachmentDraftViewState(
            id: "attachment-1",
            kind: .file,
            displayName: "hello.txt",
            mimeType: "text/plain",
            byteCount: 5,
            textContent: "hello"
        )

        let reference = try attachment.transcriptReference(maximumBytes: 16)

        #expect(reference.attachmentID == "attachment-1")
        #expect(reference.displayName == "hello.txt")
        #expect(reference.mediaType == "text/plain")
        #expect(reference.modality == "file")
        #expect(
            reference.contentDigest
                == "2cf24dba5fb0a30e26e83b2ac5b9e29e"
                + "1b161e5c1fa7425e73043362938b9824"
        )
    }

    @Test("file picker input populates the shipping attachment draft")
    func filePickerInputPopulatesAttachmentDraft() throws {
        let source = FileManager.default.temporaryDirectory.appending(
            path: "picked-\(UUID().uuidString).txt"
        )
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let viewModel = AIChatViewModel(
            conversationStreamID: "conversation-1",
            submit: { _, _ in }
        )

        try viewModel.addFileAttachment(from: source)

        let attachment = try #require(viewModel.inputAttachments.first)
        #expect(attachment.displayName == source.lastPathComponent)
        #expect(attachment.mimeType == "text/plain")
        #expect(attachment.byteCount == 5)
        #expect(attachment.localPath != nil)
    }

    @Test("photo transfer rejects an oversized file before copying it")
    func photoTransferChecksFileSizeBeforeCopying() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        let source = root.appending(path: "oversized.raw")
        let cache = root.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(
            atOffset: UInt64(
                OpenMinisAttachmentPolicy.productDefault
                    .maximumSingleAttachmentBytes + 1
            )
        )
        try handle.close()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: Error.self) {
            try OpenMinisPickedPhoto.importing(
                fileURL: source,
                cacheDirectory: cache
            )
        }
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("photo transfer copies an accepted file without loading Data")
    func photoTransferCopiesAcceptedFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        let source = root.appending(path: "photo.jpg")
        let cache = root.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("image".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let photo = try OpenMinisPickedPhoto.importing(
            fileURL: source,
            cacheDirectory: cache
        )

        #expect(photo.byteCount == 5)
        #expect(photo.displayName == "photo.jpg")
        #expect(
            try photo.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                == 5
        )
    }

    @Test("attachment bytes survive repository relaunch and are digest checked")
    func attachmentRepositoryPersistsAndResolvesDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = AttachmentDraftViewState(
            id: "attachment-persisted",
            kind: .file,
            displayName: "hello.txt",
            mimeType: "text/plain",
            byteCount: 5,
            textContent: "hello"
        )
        let first = OpenMinisAttachmentRepository(directory: root)
        let references = try await first.ingest([draft])
        let relaunched = OpenMinisAttachmentRepository(directory: root)
        let hostReferences = references.map {
            HostAttachmentReference(
                attachmentID: $0.attachmentID,
                displayName: $0.displayName,
                mediaType: $0.mediaType,
                modality: $0.modality,
                contentDigest: $0.contentDigest
            )
        }

        let resolved = try await relaunched.resolve(hostReferences)

        #expect(resolved.count == 1)
        #expect(resolved[0].reference == hostReferences[0])
        #expect(resolved[0].content == .text("hello"))
    }

    @Test("attachment repository reads metadata written before byte limits")
    func attachmentRepositoryReadsLegacyMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = OpenMinisAttachmentRepository(directory: root)
        let references = try await repository.ingest([
            AttachmentDraftViewState(
                id: "legacy-attachment",
                kind: .file,
                displayName: "legacy.txt",
                mimeType: "text/plain",
                byteCount: 6,
                textContent: "legacy"
            ),
        ])
        let metadataURL = try #require(
            FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "json" })
        )
        var metadata = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL)
            ) as? [String: Any]
        )
        metadata.removeValue(forKey: "byteCount")
        try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.sortedKeys]
        ).write(to: metadataURL, options: .atomic)
        let reference = try #require(references.first)

        let resolved = try await OpenMinisAttachmentRepository(
            directory: root
        ).resolve([
            HostAttachmentReference(
                attachmentID: reference.attachmentID,
                displayName: reference.displayName,
                mediaType: reference.mediaType,
                modality: reference.modality,
                contentDigest: reference.contentDigest
            ),
        ])

        #expect(resolved.first?.content == .text("legacy"))
    }

    @Test("attachment repository rejects oversized files before persisting")
    func attachmentRepositoryRejectsOversizedFileBeforePersisting() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        let source = root.appending(path: "oversized.txt")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("123456".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appending(path: "store", directoryHint: .isDirectory)
        let repository = OpenMinisAttachmentRepository(
            directory: store,
            policy: OpenMinisAttachmentPolicy(
                maximumSingleAttachmentBytes: 5,
                maximumRequestAttachmentBytes: 8,
                maximumRepositoryBytes: 32,
                estimatedBytesPerInputToken: 4,
                maximumContextSharePercent: 25
            )
        )
        let draft = AttachmentDraftViewState(
            id: "too-large",
            kind: .file,
            displayName: "oversized.txt",
            localPath: source.path,
            mimeType: "text/plain",
            byteCount: 6
        )

        var rejected = false
        do {
            _ = try await repository.ingest(
                [draft],
                modelContextWindow: ModelContextWindowDTO(
                    contextWindowTokens: 1_000,
                    maxOutputTokens: 100
                )
            )
        } catch {
            rejected = true
        }

        #expect(rejected)
        let persisted = try FileManager.default.contentsOfDirectory(
            at: store,
            includingPropertiesForKeys: nil
        )
        #expect(persisted.isEmpty)
    }

    @Test("markdown keeps structural blocks and math nodes")
    func markdownKeepsStructuralBlocksAndMathNodes() {
        let content = MarkdownContent(
            """
            # Result

            - first
            - second

            Inline $x^2$.

            $$
            \\sum_{i=1}^{n} i
            $$
            """
        )

        #expect(content.blocks.contains { block in
            guard case .heading(level: 1, _) = block else { return false }
            return true
        })
        #expect(content.blocks.contains { block in
            guard case .bulletedList = block else { return false }
            return true
        })
        #expect(content.blocks.contains { block in
            guard case .mathBlock(content: let latex) = block else { return false }
            return latex.contains("\\sum")
        })
        #expect(content.blocks.contains { block in
            guard case .paragraph(content: let nodes) = block else { return false }
            return nodes.contains(.inlineMath("x^2"))
        })
    }
}

@MainActor
private final class SubmissionRecorder {
    private(set) var submissions: [AIChatViewModel.Submission] = []
    private(set) var actions: [TranscriptActionRecord] = []
    var selectedConversationIDs: [String] = []

    func append(_ submission: AIChatViewModel.Submission) {
        submissions.append(submission)
    }

    func append(
        streamID: String,
        action: AIChatViewModel.TranscriptAction
    ) {
        actions.append(.init(streamID: streamID, action: action))
    }
}

@MainActor
private final class StopRecorder {
    var runIDs: [String] = []
}

@MainActor
private final class SubmissionCancellationRecorder {
    var started = false
    var cancelled = false
}

private struct TranscriptActionRecord: Equatable {
    var streamID: String
    var action: AIChatViewModel.TranscriptAction
}
