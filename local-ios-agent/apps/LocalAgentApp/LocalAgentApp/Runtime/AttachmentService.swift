import Foundation
import UIKit

enum AttachmentServiceError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case unsupportedImageType
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid http or https URL."
        case .unsupportedImageType:
            "Only image attachments are supported."
        case .invalidImageData:
            "The selected image could not be decoded."
        }
    }
}

actor AttachmentService {
    private struct RGBImageInput: Sendable {
        var width: Int
        var height: Int
        var data: Data
    }

    private let fileManager: FileManager
    private let directory: URL
    private let maxImageDimension: CGFloat = 448

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
            rgbDataBase64: rgbInput.data.base64EncodedString()
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

        return RGBImageInput(width: width, height: height, data: Data(rgbBytes))
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
