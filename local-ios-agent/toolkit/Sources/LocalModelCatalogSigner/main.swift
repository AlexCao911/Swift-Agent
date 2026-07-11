import CryptoKit
import Foundation
import LocalAgentLLMLocal

private struct Arguments {
    let signedPayload: URL
    let envelopeOutput: URL
    let keyRingOutput: URL?

    init(_ values: [String]) throws {
        guard values.count == 3 || values.count == 4 else {
            throw SignerError("usage: LocalModelCatalogSigner SIGNED_JSON ENVELOPE_JSON [KEY_RING_JSON]")
        }
        signedPayload = URL(fileURLWithPath: values[1])
        envelopeOutput = URL(fileURLWithPath: values[2])
        keyRingOutput = values.count == 4 ? URL(fileURLWithPath: values[3]) : nil
    }
}

private struct SignerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

do {
    let arguments = try Arguments(CommandLine.arguments)
    guard let seedText = ProcessInfo.processInfo.environment["LOCAL_MODEL_CATALOG_SIGNING_SEED"],
          !seedText.isEmpty
    else { throw SignerError("LOCAL_MODEL_CATALOG_SIGNING_SEED is required") }

    let seed = try Base64URL.decode(seedText, expectedCount: 32)
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let payloadData = try Data(contentsOf: arguments.signedPayload)
    let payload = try JSONDecoder().decode(SignedLocalModelCatalogPayload.self, from: payloadData)
    guard !payload.keyID.isEmpty else { throw SignerError("signed payload key_id is required") }
    let canonical = try LocalModelCatalogCanonicalDocument.canonicalSignedBytes(from: payload)
    let signature = try privateKey.signature(for: canonical)
    let envelope = CatalogEnvelope(signed: payload, signature: Base64URL.encode(signature))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(envelope).write(to: arguments.envelopeOutput, options: .atomic)

    if let keyRingOutput = arguments.keyRingOutput {
        let keyRing: [String: Any] = [
            "schema_version": "1",
            "keys": [[
                "key_id": payload.keyID,
                "public_key": Base64URL.encode(privateKey.publicKey.rawRepresentation),
                "status": "active",
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: keyRing, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: keyRingOutput, options: .atomic)
    }
} catch {
    FileHandle.standardError.write(Data("catalog signing failed: \(error)\n".utf8))
    exit(2)
}
