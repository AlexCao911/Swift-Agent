import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

enum AttachmentServiceError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case unsupportedImageType
    case invalidImageData
    case unsupportedFileType
    case fileTooLarge(maxBytes: Int)
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid http or https URL."
        case .unsupportedImageType:
            "Only image attachments are supported."
        case .invalidImageData:
            "The selected image could not be decoded."
        case .unsupportedFileType:
            "Only text-based files can be attached for now."
        case .fileTooLarge(let maxBytes):
            "The selected file is larger than \(maxBytes / 1024) KB."
        case .unreadableFile:
            "The selected file could not be read."
        }
    }
}

actor AttachmentService {
    private struct RGBImageInput: Sendable {
        var width: Int
        var height: Int
        var data: Data
        var previewData: Data
    }

    private let fileManager: FileManager
    private let directory: URL
    private let maxImageDimension: CGFloat = 448
    private let maxFileBytes = 512 * 1024
    private let maxFileContentCharacters = 20_000

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
        let rgbInput = try makeRGBInput(from: data)

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
            byteCount: data.count,
            imageWidth: rgbInput.width,
            imageHeight: rgbInput.height,
            rgbDataBase64: rgbInput.data.base64EncodedString(),
            previewDataBase64: rgbInput.previewData.base64EncodedString()
        )
    }

    func fileDraft(
        from sourceURL: URL,
        contentType explicitContentType: UTType? = nil
    ) async throws -> AttachmentDraftViewState {
        let didStartSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let resourceValues = try? sourceURL.resourceValues(forKeys: [.contentTypeKey])
        let contentType = explicitContentType
            ?? resourceValues?.contentType
            ?? UTType(filenameExtension: sourceURL.pathExtension)

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw AttachmentServiceError.unreadableFile
        }
        guard data.count <= maxFileBytes else {
            throw AttachmentServiceError.fileTooLarge(maxBytes: maxFileBytes)
        }
        let text = try textContent(from: data, contentType: contentType)

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let displayName = sourceURL.lastPathComponent.isEmpty ? "file.txt" : sourceURL.lastPathComponent
        let filename = "\(UUID().uuidString)-\(sanitizedFilename(displayName))"
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)

        return AttachmentDraftViewState(
            id: "file_\(UUID().uuidString)",
            kind: .file,
            displayName: displayName,
            localPath: url.path,
            urlString: nil,
            mimeType: contentType?.preferredMIMEType ?? "text/plain",
            byteCount: data.count,
            textContent: clippedTextContent(text)
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

    private func makeRGBInput(from data: Data) throws -> RGBImageInput {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw AttachmentServiceError.invalidImageData
        }

        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, maxImageDimension / longestSide)
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        let rendered = render(image: image, width: width, height: height)
        guard let previewData = rendered.jpegData(compressionQuality: 0.78) else {
            throw AttachmentServiceError.invalidImageData
        }
        guard let cgImage = rendered.cgImage else {
            throw AttachmentServiceError.invalidImageData
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgbaData = Data(count: height * bytesPerRow)
        let didDraw = rgbaData.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else {
            throw AttachmentServiceError.invalidImageData
        }

        var rgbBytes: [UInt8] = []
        rgbBytes.reserveCapacity(width * height * 3)
        rgbaData.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: bytes.count, by: bytesPerPixel) {
                rgbBytes.append(bytes[index])
                rgbBytes.append(bytes[index + 1])
                rgbBytes.append(bytes[index + 2])
            }
        }

        return RGBImageInput(width: width, height: height, data: Data(rgbBytes), previewData: previewData)
    }

    private func textContent(from data: Data, contentType: UTType?) throws -> String {
        if contentType?.conforms(to: .pdf) == true {
            guard let text = pdfTextContent(from: data) else {
                throw AttachmentServiceError.unsupportedFileType
            }
            return text
        }

        guard let text = decodedTextContent(from: data, contentType: contentType) else {
            throw AttachmentServiceError.unsupportedFileType
        }
        return text
    }

    private func pdfTextContent(from data: Data) -> String? {
        guard let document = PDFDocument(data: data),
              let text = document.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        return text
    }

    private func decodedTextContent(from data: Data, contentType: UTType?) -> String? {
        let decoded = [
            String(data: data, encoding: .utf8),
            String(data: data, encoding: .utf16),
            String(data: data, encoding: .utf16LittleEndian),
            String(data: data, encoding: .utf16BigEndian),
        ].compactMap { $0 }.first

        guard let decoded,
              !decoded.contains("\u{0}")
        else {
            return nil
        }

        if let contentType,
           !contentType.conforms(to: .text),
           contentType.preferredMIMEType?.hasPrefix("text/") != true
        {
            return nil
        }

        return decoded
    }

    private func clippedTextContent(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.count > maxFileContentCharacters else {
            return normalized
        }

        return String(normalized.prefix(maxFileContentCharacters))
            + "\n[File content truncated]"
    }

    private func render(image: UIImage, width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}
