import CryptoKit
import Foundation

public struct CanonicalDigest: Equatable, Sendable {
    public let hex: String

    init(hex: String) {
        self.hex = hex
    }
}

public struct CanonicalDigestError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum CanonicalDigestV1 {
    public static let registeredDomains: Set<String> = [
        "agent-host-binding:v1",
        "agent-input:v1",
        "agent-requirements:v1",
        "capability-attestation:v1",
        "capability-evidence:v1",
        "capability-observation:v1",
        "capability-snapshot:v1",
        "conversation-frame:v1",
        "credential-use-lease:v1",
        "egress-approval-summary:v1",
        "egress-attestation:v1",
        "egress-audit-chain:v1",
        "egress-generation-authorization:v1",
        "egress-scope-grant:v1",
        "egress-subject:v1",
        "execution-plan:v1",
        "generation-disclosure:v1",
        "host-binding-staging-receipt:v1",
        "host-command-envelope:v1",
        "host-command-payload:v1",
        "host-tool-effect-result:v1",
        "llm-event-envelope:v1",
        "llm-event-receipt:v1",
        "preparation-binding:v1",
        "preparation-token:v1",
        "prepared-session-cleanup-command:v1",
        "prepared-session-closed-receipt:v1",
        "prepared-session-registration:v1",
        "provider-retention-approval:v1",
        "resolved-parameters:v1",
        "resolved-run-snapshot:v1",
        "saga-token:v1",
        "source-revisions:v1",
        "tool-schema:v1",
    ]

    public static func canonicalize(_ value: CanonicalJSONValue) throws -> Data {
        var output = String()
        try append(value, to: &output)
        guard let data = output.data(using: .utf8) else {
            throw CanonicalDigestError(
                code: "canonical_digest.utf8_encoding_failed",
                message: "canonical JSON could not be encoded as UTF-8"
            )
        }
        return data
    }

    public static func digest(
        domain: String,
        document: CanonicalJSONValue
    ) throws -> CanonicalDigest {
        try validate(domain: domain)
        guard registeredDomains.contains(domain) else {
            throw CanonicalDigestError(
                code: "canonical_digest.domain_unregistered",
                message: "canonical digest domain is not registered: \(domain)"
            )
        }

        var preimage = Data(domain.utf8)
        preimage.append(0)
        preimage.append(try canonicalize(document))
        let bytes = SHA256.hash(data: preimage)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return CanonicalDigest(hex: hex)
    }

    private static func validate(domain: String) throws {
        guard domain.hasSuffix(":v1") else {
            throw invalidDomain(domain)
        }
        let name = domain.dropLast(3)
        guard !name.isEmpty,
              name.utf8.allSatisfy({ byte in
                  (byte >= 0x61 && byte <= 0x7A)
                      || (byte >= 0x30 && byte <= 0x39)
                      || byte == 0x2D
              })
        else {
            throw invalidDomain(domain)
        }
    }

    private static func invalidDomain(_ domain: String) -> CanonicalDigestError {
        CanonicalDigestError(
            code: "canonical_digest.domain_invalid",
            message: "canonical digest domain has invalid syntax: \(String(reflecting: domain))"
        )
    }

    private static func append(_ value: CanonicalJSONValue, to output: inout String) throws {
        switch value {
        case .null:
            output += "null"
        case let .bool(value):
            output += value ? "true" : "false"
        case let .string(value):
            appendEscaped(value, to: &output)
        case let .number(value):
            output += try canonicalNumber(value)
        case let .array(values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 {
                    output += ","
                }
                try append(value, to: &output)
            }
            output += "]"
        case let .object(object):
            output += "{"
            let entries = object.entries.sorted { lhs, rhs in
                lhs.name.utf16.lexicographicallyPrecedes(rhs.name.utf16)
            }
            for (index, entry) in entries.enumerated() {
                if index > 0 {
                    output += ","
                }
                appendEscaped(entry.name, to: &output)
                output += ":"
                try append(entry.value, to: &output)
            }
            output += "}"
        }
    }

    private static func appendEscaped(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                output += "\\b"
            case 0x09:
                output += "\\t"
            case 0x0A:
                output += "\\n"
            case 0x0C:
                output += "\\f"
            case 0x0D:
                output += "\\r"
            case 0x22:
                output += "\\\""
            case 0x5C:
                output += "\\\\"
            case 0x00 ... 0x1F:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    private static func canonicalNumber(_ value: Double) throws -> String {
        guard value.isFinite else {
            throw CanonicalDigestError(
                code: "canonical_digest.number_non_finite",
                message: "canonical JSON numbers must be finite"
            )
        }
        if value == 0 {
            return "0"
        }

        var raw = value.description
        var sign = ""
        if raw.first == "-" {
            sign = "-"
            raw.removeFirst()
        }

        let exponentParts = raw.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
        let mantissa = String(exponentParts[0])
        let explicitExponent = exponentParts.count == 2 ? Int(exponentParts[1])! : 0
        let decimalIndex = mantissa.firstIndex(of: ".")
        let fractionCount = decimalIndex.map { mantissa.distance(from: mantissa.index(after: $0), to: mantissa.endIndex) } ?? 0
        var digits = mantissa.filter { $0 != "." }
        var decimalExponent = explicitExponent - fractionCount

        while digits.first == "0" && digits.count > 1 {
            digits.removeFirst()
        }
        while digits.last == "0" && digits.count > 1 {
            digits.removeLast()
            decimalExponent += 1
        }

        let scientificExponent = digits.count - 1 + decimalExponent
        let body: String
        if scientificExponent >= -6 && scientificExponent < 21 {
            let decimalPosition = digits.count + decimalExponent
            if decimalPosition <= 0 {
                body = "0." + String(repeating: "0", count: -decimalPosition) + digits
            } else if decimalPosition >= digits.count {
                body = digits + String(repeating: "0", count: decimalPosition - digits.count)
            } else {
                let split = digits.index(digits.startIndex, offsetBy: decimalPosition)
                body = String(digits[..<split]) + "." + String(digits[split...])
            }
        } else {
            let first = digits.removeFirst()
            let fraction = digits.isEmpty ? "" : ".\(digits)"
            let exponentSign = scientificExponent >= 0 ? "+" : ""
            body = "\(first)\(fraction)e\(exponentSign)\(scientificExponent)"
        }
        return sign + body
    }
}
