import CryptoKit
import Combine
import Foundation
import ImageIO
import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMHost
import LocalNativeToolkit
import SwiftUI
import UniformTypeIdentifiers

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

    typealias ReportRunID = @MainActor @Sendable (_ runID: String) -> Void
    typealias Submit = @MainActor @Sendable (
        _ submission: Submission,
        _ reportRunID: @escaping ReportRunID
    ) async throws -> Void
    typealias PerformTranscriptAction = @MainActor @Sendable (
        _ conversationStreamID: String,
        _ action: TranscriptAction,
        _ reportRunID: @escaping ReportRunID
    ) async throws -> Void
    typealias SelectConversation = @MainActor @Sendable (
        _ conversationStreamID: String
    ) throws -> Void
    typealias RestoreProductState = @MainActor @Sendable () async throws -> Void
    typealias StopRun = @MainActor @Sendable (_ runID: String) async throws -> Void

    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var inputAttachments: [InputAttachment] = []
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    @Published private(set) var conversationStreamID: String
    private let submit: Submit
    private let performTranscriptAction: PerformTranscriptAction?
    private let selectConversation: SelectConversation
    private let restoreProductState: RestoreProductState?
    private let stopRun: StopRun?
    private weak var chatStore: ChatStore?
    private var subscriptions: Set<AnyCancellable> = []
    private var isSubmitting = false
    private var pendingOperation: Task<Void, Error>?
    private var pendingRunID: String?

    init(
        conversationStreamID: String,
        submit: @escaping Submit,
        performTranscriptAction: PerformTranscriptAction? = nil,
        selectConversation: @escaping SelectConversation = { _ in },
        restoreProductState: RestoreProductState? = nil,
        chatStore: ChatStore? = nil,
        stopRun: StopRun? = nil
    ) {
        self.conversationStreamID = conversationStreamID
        self.submit = submit
        self.performTranscriptAction = performTranscriptAction
        self.selectConversation = selectConversation
        self.restoreProductState = restoreProductState
        self.chatStore = chatStore
        self.stopRun = stopRun
        chatStore?.$activeRunIDByConversation
            .sink { [weak self] activeRuns in
                guard let self else { return }
                self.isRunning = self.isSubmitting
                    || activeRuns[self.conversationStreamID] != nil
            }
            .store(in: &subscriptions)
    }

    func restore() async {
        guard let restoreProductState else { return }
        do {
            try await restoreProductState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchConversation(to conversationStreamID: String) {
        guard !conversationStreamID.isEmpty,
              conversationStreamID != self.conversationStreamID
        else { return }
        do {
            try selectConversation(conversationStreamID)
            self.conversationStreamID = conversationStreamID
            errorMessage = nil
            refreshRunningState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prefill(_ text: String) {
        draft = text
    }

    func addFileAttachment(from sourceURL: URL) throws {
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = values.fileSize ?? 0
        guard byteCount <= OpenMinisAttachmentPolicy.productDefault
            .maximumSingleAttachmentBytes else {
            throw AttachmentInputError.tooLarge(sourceURL.lastPathComponent)
        }
        let destination = try cacheInputAttachment(
            sourceURL: sourceURL,
            preferredName: sourceURL.lastPathComponent
        )
        let type = UTType(filenameExtension: sourceURL.pathExtension)
        inputAttachments.append(AttachmentDraftViewState(
            id: UUID().uuidString.lowercased(),
            kind: type?.conforms(to: .image) == true ? .image : .file,
            displayName: sourceURL.lastPathComponent,
            localPath: destination.path,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            byteCount: byteCount
        ))
    }

    func addPhotoAttachment(_ photo: OpenMinisPickedPhoto) {
        inputAttachments.append(AttachmentDraftViewState(
            id: UUID().uuidString.lowercased(),
            kind: .image,
            displayName: photo.displayName,
            localPath: photo.fileURL.path,
            mimeType: photo.mediaType,
            byteCount: photo.byteCount
        ))
    }

    func removeInputAttachment(id: String) {
        inputAttachments.removeAll { $0.id == id }
    }

    func reportAttachmentError(_ error: Error) {
        errorMessage = error.localizedDescription
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

        isSubmitting = true
        refreshRunningState()
        errorMessage = nil
        defer {
            isSubmitting = false
            pendingOperation = nil
            pendingRunID = nil
            refreshRunningState()
        }

        let operation = Task { @MainActor [submit] in
            try await submit(submission) { [weak self] runID in
                self?.pendingRunID = runID
            }
        }
        pendingOperation = operation
        do {
            try await operation.value
            draft = ""
            inputAttachments = []
        } catch is CancellationError {
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

    func stop() async {
        let operation = pendingOperation
        operation?.cancel()
        let runID = pendingRunID ?? chatStore?.activeRunID(
            conversationStreamID: conversationStreamID
        )
        if let runID, let stopRun {
            do {
                try await stopRun(runID)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if let operation {
            _ = await operation.result
        }
    }

    private func perform(_ action: TranscriptAction) async {
        guard !isRunning, let performTranscriptAction else {
            return
        }

        isSubmitting = true
        refreshRunningState()
        errorMessage = nil
        defer {
            isSubmitting = false
            pendingOperation = nil
            pendingRunID = nil
            refreshRunningState()
        }
        let operation = Task { @MainActor [performTranscriptAction] in
            try await performTranscriptAction(
                conversationStreamID,
                action
            ) { [weak self] runID in
                self?.pendingRunID = runID
            }
        }
        pendingOperation = operation
        do {
            try await operation.value
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshRunningState() {
        isRunning = isSubmitting
            || chatStore?.activeRunID(
                conversationStreamID: conversationStreamID
            ) != nil
    }

    private func cacheInputAttachment(
        sourceURL: URL,
        preferredName: String
    ) throws -> URL {
        let destination = inputAttachmentCacheDirectory().appending(
            path: "\(UUID().uuidString.lowercased())-\(preferredName)"
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func inputAttachmentCacheDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "LocalAgentInputAttachments",
            directoryHint: .isDirectory
        )
    }
}

private enum AttachmentInputError: LocalizedError {
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case let .tooLarge(name):
            "Attachment \(name) exceeds the configured size limit"
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

    func put(
        _ data: Data,
        filename: String,
        contentType: String
    ) async throws -> NativeAttachmentStoredBytes {
        guard data.count <= policy.maximumSingleAttachmentBytes else {
            throw AttachmentTranscriptReferenceError.tooLarge(filename)
        }
        let attachmentID = "att_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let reference = TranscriptAttachmentReferenceDTO(
            attachmentID: attachmentID,
            displayName: filename,
            mediaType: contentType,
            modality: contentType.hasPrefix("image/") ? "image" : "file",
            contentDigest: Self.digest(data)
        )
        let metadata = StoredMetadata(
            reference: reference,
            kind: contentType.hasPrefix("image/") ? .image : .file,
            imageWidth: nil,
            imageHeight: nil,
            byteCount: data.count
        )
        guard try repositoryByteCount() + data.count
            <= policy.maximumRepositoryBytes else {
            throw AttachmentTranscriptReferenceError.repositoryFull
        }
        try data.write(to: dataURL(for: attachmentID), options: .atomic)
        try encoder.encode(metadata).write(
            to: metadataURL(for: attachmentID),
            options: .atomic
        )
        return NativeAttachmentStoredBytes(
            attachmentId: attachmentID,
            filename: filename,
            contentType: contentType,
            byteCount: data.count
        )
    }

    func putModelImage(
        _ data: Data,
        filename: String,
        contentType _: String
    ) async throws -> TranscriptAttachmentReferenceDTO {
        guard data.count <= policy.maximumSingleAttachmentBytes else {
            throw AttachmentTranscriptReferenceError.tooLarge(filename)
        }
        let image = try Self.rgb8Image(data)
        guard image.data.count <= policy.maximumSingleAttachmentBytes else {
            throw AttachmentTranscriptReferenceError.tooLarge(filename)
        }
        let attachmentID = "att_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let reference = TranscriptAttachmentReferenceDTO(
            attachmentID: attachmentID,
            displayName: filename,
            mediaType: "image/rgb8",
            modality: "image",
            contentDigest: Self.digest(image.data)
        )
        let metadata = StoredMetadata(
            reference: reference,
            kind: .image,
            imageWidth: image.width,
            imageHeight: image.height,
            byteCount: image.data.count
        )
        guard try repositoryByteCount() + image.data.count
            <= policy.maximumRepositoryBytes else {
            throw AttachmentTranscriptReferenceError.repositoryFull
        }
        try image.data.write(to: dataURL(for: attachmentID), options: .atomic)
        try encoder.encode(metadata).write(
            to: metadataURL(for: attachmentID),
            options: .atomic
        )
        return reference
    }

    func describe(
        attachmentId: String
    ) async throws -> NativeAttachmentStoredBytes {
        let metadata = try decoder.decode(
            StoredMetadata.self,
            from: Data(contentsOf: metadataURL(for: attachmentId))
        )
        let byteCount = try metadata.byteCount
            ?? dataURL(for: attachmentId)
                .resourceValues(forKeys: [.fileSizeKey])
                .fileSize
            ?? 0
        return NativeAttachmentStoredBytes(
            attachmentId: attachmentId,
            filename: metadata.reference.displayName,
            contentType: metadata.reference.mediaType,
            byteCount: byteCount
        )
    }

    func read(attachmentId: String, maxBytes: Int) async throws -> Data {
        let handle = try FileHandle(
            forReadingFrom: dataURL(for: attachmentId)
        )
        defer { try? handle.close() }
        return try handle.read(upToCount: max(0, maxBytes)) ?? Data()
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

    private static func rgb8Image(_ data: Data) throws -> (
        data: Data,
        width: Int,
        height: Int
    ) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AttachmentTranscriptReferenceError.invalidImage
        }
        let scale = min(1, 2_000 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let rgbaBytesPerRow = width * 4
        var rgba = Data(count: rgbaBytesPerRow * height)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rgbaBytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else {
            throw AttachmentTranscriptReferenceError.invalidImage
        }
        var rgb = Data()
        rgb.reserveCapacity(width * height * 3)
        rgba.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for pixel in stride(from: 0, to: bytes.count, by: 4) {
                rgb.append(bytes[pixel])
                rgb.append(bytes[pixel + 1])
                rgb.append(bytes[pixel + 2])
            }
        }
        return (rgb, width, height)
    }
}

extension OpenMinisAttachmentRepository: NativeAttachmentByteStore {}
extension OpenMinisAttachmentRepository: OpenMinisImageAttachmentStoring {}

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
    case invalidImage

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
        case .invalidImage:
            "Attachment is not a decodable image"
        }
    }
}
