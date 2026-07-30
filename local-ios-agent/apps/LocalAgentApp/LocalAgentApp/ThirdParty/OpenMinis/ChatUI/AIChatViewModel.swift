import CryptoKit
import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMHost
import SwiftUI

typealias InputAttachment = AttachmentDraftViewState
typealias ChatMessage = AgentMessageViewState
typealias ChatSession = ConversationSummaryViewState

@MainActor
final class AIChatViewModel: ObservableObject {
    struct Submission: Equatable, Sendable {
        var conversationStreamID: String
        var text: String
        var attachments: [InputAttachment]
    }

    enum TranscriptAction: Equatable, Sendable {
        case retry(anchorEventID: String)
        case edit(
            targetEventID: String,
            replacementText: String,
            replacementAttachments: [InputAttachment]
        )
        case delete(targetEventID: String)
        case clear
        case branch(anchorEventID: String, newConversationStreamID: String)
        case archive
    }

    typealias Submit = @MainActor @Sendable (Submission) async throws -> Void
    typealias PerformTranscriptAction = @MainActor @Sendable (
        _ conversationStreamID: String,
        _ action: TranscriptAction
    ) async throws -> Void
    typealias SelectConversation = @MainActor @Sendable (
        _ conversationStreamID: String
    ) throws -> Void

    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var inputAttachments: [InputAttachment] = []
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    @Published private(set) var conversationStreamID: String
    private let submit: Submit
    private let performTranscriptAction: PerformTranscriptAction?
    private let selectConversation: SelectConversation

    init(
        conversationStreamID: String,
        submit: @escaping Submit,
        performTranscriptAction: PerformTranscriptAction? = nil,
        selectConversation: @escaping SelectConversation = { _ in }
    ) {
        self.conversationStreamID = conversationStreamID
        self.submit = submit
        self.performTranscriptAction = performTranscriptAction
        self.selectConversation = selectConversation
    }

    func switchConversation(to conversationStreamID: String) {
        guard !conversationStreamID.isEmpty,
              conversationStreamID != self.conversationStreamID
        else { return }
        do {
            try selectConversation(conversationStreamID)
            self.conversationStreamID = conversationStreamID
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prefill(_ text: String) {
        draft = text
    }

    func send() async {
        guard !isRunning else {
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !inputAttachments.isEmpty else {
            return
        }

        let submission = Submission(
            conversationStreamID: conversationStreamID,
            text: text,
            attachments: inputAttachments
        )

        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        do {
            try await submit(submission)
            draft = ""
            inputAttachments = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retry(anchorEventID: String) async {
        await perform(.retry(anchorEventID: anchorEventID))
    }

    func edit(
        targetEventID: String,
        replacementText: String,
        replacementAttachments: [InputAttachment] = []
    ) async {
        await perform(.edit(
            targetEventID: targetEventID,
            replacementText: replacementText,
            replacementAttachments: replacementAttachments
        ))
    }

    func delete(targetEventID: String) async {
        await perform(.delete(targetEventID: targetEventID))
    }

    func clear() async {
        await perform(.clear)
    }

    func branch(
        anchorEventID: String,
        newConversationStreamID: String
    ) async {
        await perform(.branch(
            anchorEventID: anchorEventID,
            newConversationStreamID: newConversationStreamID
        ))
    }

    func archive() async {
        await perform(.archive)
    }

    private func perform(_ action: TranscriptAction) async {
        guard !isRunning, let performTranscriptAction else {
            return
        }

        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            try await performTranscriptAction(conversationStreamID, action)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct OpenMinisAttachmentPolicy: Equatable, Sendable {
    let maximumSingleAttachmentBytes: Int
    let maximumRequestAttachmentBytes: Int
    let maximumRepositoryBytes: Int
    let estimatedBytesPerInputToken: Int
    let maximumContextSharePercent: Int

    static let productDefault = OpenMinisAttachmentPolicy(
        maximumSingleAttachmentBytes: 20 * 1_024 * 1_024,
        maximumRequestAttachmentBytes: 50 * 1_024 * 1_024,
        maximumRepositoryBytes: 1_024 * 1_024 * 1_024,
        estimatedBytesPerInputToken: 4,
        maximumContextSharePercent: 50
    )

    func textByteBudget(
        modelContextWindow: ModelContextWindowDTO?
    ) -> Int {
        guard let modelContextWindow else {
            return maximumRequestAttachmentBytes
        }
        let inputTokens = modelContextWindow.contextWindowTokens
            > modelContextWindow.maxOutputTokens
            ? modelContextWindow.contextWindowTokens
                - modelContextWindow.maxOutputTokens
            : 0
        let contextBytes = inputTokens
            .multipliedReportingOverflow(
                by: UInt64(estimatedBytesPerInputToken)
            )
        guard !contextBytes.overflow else {
            return maximumRequestAttachmentBytes
        }
        let shared = contextBytes.partialValue
            .multipliedReportingOverflow(
                by: UInt64(maximumContextSharePercent)
            )
        guard !shared.overflow else {
            return maximumRequestAttachmentBytes
        }
        return min(
            maximumRequestAttachmentBytes,
            Int(clamping: shared.partialValue / 100)
        )
    }
}

extension AttachmentDraftViewState {
    func transcriptReference(
        maximumBytes: Int
    ) throws -> TranscriptAttachmentReferenceDTO {
        try transcriptReference(
            content: transcriptContent(maximumBytes: maximumBytes)
        )
    }

    fileprivate func transcriptReference(
        content: Data
    ) throws -> TranscriptAttachmentReferenceDTO {
        let digest = SHA256.hash(data: content)
            .map { String(format: "%02x", $0) }
            .joined()
        return TranscriptAttachmentReferenceDTO(
            attachmentID: id,
            displayName: displayName,
            mediaType: mimeType ?? defaultMediaType,
            modality: kind.rawValue,
            contentDigest: digest
        )
    }

    fileprivate func transcriptContent(maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else {
            throw AttachmentTranscriptReferenceError.tooLarge(displayName)
        }
        if let rgbDataBase64 {
            return try boundedBase64Data(
                rgbDataBase64,
                maximumBytes: maximumBytes
            )
        }
        if let textContent {
            guard textContent.utf8.count <= maximumBytes else {
                throw AttachmentTranscriptReferenceError.tooLarge(displayName)
            }
            return Data(textContent.utf8)
        }
        if let previewDataBase64 {
            return try boundedBase64Data(
                previewDataBase64,
                maximumBytes: maximumBytes
            )
        }
        if let localPath {
            let url = URL(fileURLWithPath: localPath)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > maximumBytes {
                throw AttachmentTranscriptReferenceError.tooLarge(displayName)
            }
            return try Self.readBounded(
                url,
                maximumBytes: maximumBytes,
                displayName: displayName
            )
        }
        if let urlString {
            guard urlString.utf8.count <= maximumBytes else {
                throw AttachmentTranscriptReferenceError.tooLarge(displayName)
            }
            return Data(urlString.utf8)
        }
        throw AttachmentTranscriptReferenceError.missingContent(displayName)
    }

    private func boundedBase64Data(
        _ encoded: String,
        maximumBytes: Int
    ) throws -> Data {
        let maximumEncodedBytes = ((maximumBytes + 2) / 3) * 4
        guard encoded.utf8.count <= maximumEncodedBytes,
              let data = Data(base64Encoded: encoded),
              data.count <= maximumBytes
        else {
            throw AttachmentTranscriptReferenceError.tooLarge(displayName)
        }
        return data
    }

    fileprivate static func readBounded(
        _ url: URL,
        maximumBytes: Int,
        displayName: String
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw AttachmentTranscriptReferenceError.tooLarge(displayName)
        }
        return data
    }

    private var defaultMediaType: String {
        switch kind {
        case .image: "image/jpeg"
        case .link: "text/uri-list"
        case .file: "application/octet-stream"
        }
    }
}

actor OpenMinisAttachmentRepository: RustReActAttachmentResolving {
    private struct StoredMetadata: Codable {
        let reference: TranscriptAttachmentReferenceDTO
        let kind: AttachmentKindViewState
        let imageWidth: Int?
        let imageHeight: Int?
        let byteCount: Int?
    }

    private let directory: URL
    private let policy: OpenMinisAttachmentPolicy
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        directory: URL,
        policy: OpenMinisAttachmentPolicy = .productDefault
    ) {
        self.directory = directory
        self.policy = policy
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func ingest(
        _ drafts: [AttachmentDraftViewState],
        modelContextWindow: ModelContextWindowDTO? = nil
    ) throws -> [TranscriptAttachmentReferenceDTO] {
        let textBudget = policy.textByteBudget(
            modelContextWindow: modelContextWindow
        )
        var totalBytes = 0
        var textBytes = 0
        let prepared = try drafts.map { draft in
            let maximumBytes = draft.kind == .image
                ? policy.maximumSingleAttachmentBytes
                : min(policy.maximumSingleAttachmentBytes, textBudget)
            let data = try draft.transcriptContent(
                maximumBytes: maximumBytes
            )
            totalBytes += data.count
            if draft.kind != .image {
                textBytes += data.count
            }
            guard totalBytes <= policy.maximumRequestAttachmentBytes,
                  textBytes <= textBudget
            else {
                throw AttachmentTranscriptReferenceError.requestTooLarge
            }
            let reference = try draft.transcriptReference(content: data)
            let metadata = StoredMetadata(
                reference: reference,
                kind: draft.kind,
                imageWidth: draft.imageWidth,
                imageHeight: draft.imageHeight,
                byteCount: data.count
            )
            return (reference, data, metadata)
        }
        let existingBytes = try repositoryByteCount()
        let addedBytes = prepared
            .filter {
                !FileManager.default.fileExists(
                    atPath: metadataURL(for: $0.0.attachmentID).path
                )
            }
            .reduce(0) { $0 + $1.1.count }
        guard existingBytes + addedBytes <= policy.maximumRepositoryBytes else {
            throw AttachmentTranscriptReferenceError.repositoryFull
        }

        return try prepared.map { reference, data, metadata in
            let metadataURL = metadataURL(for: reference.attachmentID)
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                let existing = try decoder.decode(
                    StoredMetadata.self,
                    from: Data(contentsOf: metadataURL)
                )
                guard existing.reference == reference else {
                    throw AttachmentTranscriptReferenceError.identityConflict(
                        reference.attachmentID
                    )
                }
            } else {
                try data.write(
                    to: dataURL(for: reference.attachmentID),
                    options: .atomic
                )
                try encoder.encode(metadata).write(
                    to: metadataURL,
                    options: .atomic
                )
            }
            return reference
        }
    }

    func resolve(
        _ references: [HostAttachmentReference]
    ) throws -> [RustReActResolvedAttachment] {
        let metadata = try references.map { reference in
            let metadata = try decoder.decode(
                StoredMetadata.self,
                from: Data(contentsOf: metadataURL(for: reference.attachmentID))
            )
            guard metadata.reference.matches(reference) else {
                throw AttachmentTranscriptReferenceError.identityConflict(
                    reference.attachmentID
                )
            }
            let byteCount = try metadata.byteCount
                ?? dataURL(for: reference.attachmentID)
                    .resourceValues(forKeys: [.fileSizeKey])
                    .fileSize
                ?? policy.maximumSingleAttachmentBytes + 1
            return (reference, metadata, byteCount)
        }
        guard metadata.reduce(0, { $0 + $1.2 })
            <= policy.maximumRequestAttachmentBytes
        else {
            throw AttachmentTranscriptReferenceError.requestTooLarge
        }
        return try metadata.map { reference, metadata, byteCount in
            let data = try AttachmentDraftViewState.readBounded(
                dataURL(for: reference.attachmentID),
                maximumBytes: min(
                    byteCount,
                    policy.maximumSingleAttachmentBytes
                ),
                displayName: reference.displayName
            )
            guard Self.digest(data) == reference.contentDigest else {
                throw AttachmentTranscriptReferenceError.digestMismatch(
                    reference.attachmentID
                )
            }
            return RustReActResolvedAttachment(
                reference: reference,
                content: try resolvedContent(data: data, metadata: metadata)
            )
        }
    }

    private func repositoryByteCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        .filter { $0.pathExtension == "bin" }
        .reduce(0) { count, url in
            count + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    private func resolvedContent(
        data: Data,
        metadata: StoredMetadata
    ) throws -> RustReActResolvedAttachmentContent {
        if metadata.kind == .image,
           let width = metadata.imageWidth,
           let height = metadata.imageHeight,
           width > 0,
           height > 0,
           UInt64(width) * UInt64(height) * 3 == UInt64(data.count),
           let resolvedWidth = UInt32(exactly: width),
           let resolvedHeight = UInt32(exactly: height) {
            return .imageRGB8(
                data,
                width: resolvedWidth,
                height: resolvedHeight
            )
        }
        if metadata.kind == .link
            || metadata.reference.mediaType.hasPrefix("text/"),
            let text = String(data: data, encoding: .utf8) {
            return .text(text)
        }
        return .opaque
    }

    private func dataURL(for attachmentID: String) -> URL {
        directory.appending(path: "\(Self.fileStem(attachmentID)).bin")
    }

    private func metadataURL(for attachmentID: String) -> URL {
        directory.appending(path: "\(Self.fileStem(attachmentID)).json")
    }

    private static func fileStem(_ attachmentID: String) -> String {
        digest(Data(attachmentID.utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension TranscriptAttachmentReferenceDTO {
    func matches(_ reference: HostAttachmentReference) -> Bool {
        attachmentID == reference.attachmentID
            && displayName == reference.displayName
            && mediaType == reference.mediaType
            && modality == reference.modality
            && contentDigest == reference.contentDigest
    }
}

private enum AttachmentTranscriptReferenceError: LocalizedError {
    case missingContent(String)
    case tooLarge(String)
    case requestTooLarge
    case repositoryFull
    case identityConflict(String)
    case digestMismatch(String)

    var errorDescription: String? {
        switch self {
        case let .missingContent(displayName):
            "Attachment \(displayName) has no readable content"
        case let .tooLarge(displayName):
            "Attachment \(displayName) exceeds the configured size limit"
        case .requestTooLarge:
            "The selected attachments exceed the configured request limit"
        case .repositoryFull:
            "The attachment repository has reached its configured limit"
        case let .identityConflict(attachmentID):
            "Attachment \(attachmentID) conflicts with stored content"
        case let .digestMismatch(attachmentID):
            "Attachment \(attachmentID) failed its content digest check"
        }
    }
}
