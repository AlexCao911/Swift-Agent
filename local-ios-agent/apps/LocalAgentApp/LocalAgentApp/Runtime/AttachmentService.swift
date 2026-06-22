import Foundation

enum AttachmentServiceError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case unsupportedImageType

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid http or https URL."
        case .unsupportedImageType:
            "Only image attachments are supported."
        }
    }
}

actor AttachmentService {
    private let fileManager: FileManager
    private let directory: URL

    init(
        fileManager: FileManager = .default,
        directory: URL = AttachmentService.defaultDirectory()
    ) {
        self.fileManager = fileManager
        self.directory = directory
    }

    nonisolated static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DraftAttachments", isDirectory: true)
    }

    func linkDraft(from rawValue: String) throws -> AttachmentDraftViewState {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              let host = url.host,
              !host.isEmpty
        else {
            throw AttachmentServiceError.invalidURL
        }

        return AttachmentDraftViewState(
            id: "link_\(UUID().uuidString)",
            kind: .link,
            displayName: url.host ?? url.absoluteString,
            localPath: nil,
            urlString: url.absoluteString,
            mimeType: nil,
            byteCount: nil
        )
    }

    func imageDraft(
        data: Data,
        suggestedName: String,
        mimeType: String
    ) async throws -> AttachmentDraftViewState {
        guard mimeType.hasPrefix("image/") else {
            throw AttachmentServiceError.unsupportedImageType
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let filename = "\(UUID().uuidString)-\(sanitizedFilename(suggestedName))"
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

    func removeDraft(_ attachment: AttachmentDraftViewState) async {
        guard let localPath = attachment.localPath else {
            return
        }
        try? fileManager.removeItem(atPath: localPath)
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
        return filename
            .components(separatedBy: invalidCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
