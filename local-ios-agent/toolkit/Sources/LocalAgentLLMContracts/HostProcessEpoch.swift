import Foundation
import Security

public enum HostProcessEpochError: Error, Equatable, Sendable {
    case randomGenerationFailed(OSStatus)
}

public struct HostProcessEpoch: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isCanonical(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public static func generate() throws -> HostProcessEpoch {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw HostProcessEpochError.randomGenerationFailed(status)
        }
        let rawValue = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let epoch = HostProcessEpoch(rawValue: rawValue) else {
            preconditionFailure("32 random bytes must encode as a canonical host process epoch")
        }
        return epoch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let epoch = HostProcessEpoch(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "HostProcessEpoch must be canonical unpadded base64url for exactly 32 bytes"
            )
        }
        self = epoch
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isCanonical(_ rawValue: String) -> Bool {
        let canonicalLastCharacters = Set("AEIMQUYcgkosw048".utf8)
        return rawValue.utf8.count == 43
            && rawValue.utf8.allSatisfy {
                (65 ... 90).contains($0)
                    || (97 ... 122).contains($0)
                    || (48 ... 57).contains($0)
                    || $0 == 45
                    || $0 == 95
            }
            && rawValue.utf8.last.map(canonicalLastCharacters.contains) == true
    }
}
