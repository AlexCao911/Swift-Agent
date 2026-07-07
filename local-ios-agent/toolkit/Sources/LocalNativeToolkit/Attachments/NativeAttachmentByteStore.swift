import Foundation

public struct NativeAttachmentStoredBytes: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var filename: String
    public var contentType: String
    public var byteCount: Int

    public init(attachmentId: String, filename: String, contentType: String, byteCount: Int) {
        self.attachmentId = attachmentId
        self.filename = filename
        self.contentType = contentType
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case filename
        case contentType = "content_type"
        case byteCount = "byte_count"
    }
}

public enum NativeAttachmentByteStoreError: Error, Equatable, Sendable {
    case notFound
}

public protocol NativeAttachmentByteStore: Sendable {
    func put(_ data: Data, filename: String, contentType: String) async throws -> NativeAttachmentStoredBytes
    func describe(attachmentId: String) async throws -> NativeAttachmentStoredBytes
    func read(attachmentId: String, maxBytes: Int) async throws -> Data
}

public actor FileBackedNativeAttachmentByteStore: NativeAttachmentByteStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func put(
        _ data: Data,
        filename: String,
        contentType: String
    ) async throws -> NativeAttachmentStoredBytes {
        let id = "att_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let metadata = NativeAttachmentStoredBytes(
            attachmentId: id,
            filename: filename,
            contentType: contentType,
            byteCount: data.count
        )
        try data.write(to: dataURL(for: id), options: [.atomic])
        try encoder.encode(metadata).write(to: metadataURL(for: id), options: [.atomic])
        return metadata
    }

    public func describe(attachmentId: String) async throws -> NativeAttachmentStoredBytes {
        let url = metadataURL(for: attachmentId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NativeAttachmentByteStoreError.notFound
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(NativeAttachmentStoredBytes.self, from: data)
    }

    public func read(attachmentId: String, maxBytes: Int) async throws -> Data {
        let url = dataURL(for: attachmentId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NativeAttachmentByteStoreError.notFound
        }
        let data = try Data(contentsOf: url)
        return Data(data.prefix(max(0, maxBytes)))
    }

    private func dataURL(for id: String) -> URL {
        directory.appending(path: "\(id).bin")
    }

    private func metadataURL(for id: String) -> URL {
        directory.appending(path: "\(id).json")
    }
}
