import CryptoKit
import Foundation
import LocalAgentLLMCloud

private struct Arguments {
    let signedPayload: URL
    let envelopeOutput: URL
    let keyRingOutput: URL?

    init(_ values: [String]) throws {
        guard values.count == 3 || values.count == 4 else {
            throw SignerError(
                "usage: CloudCapabilityCatalogSigner SIGNED_JSON ENVELOPE_JSON [KEY_RING_JSON]"
            )
        }
        signedPayload = URL(fileURLWithPath: values[1])
        envelopeOutput = URL(fileURLWithPath: values[2])
        keyRingOutput = values.count == 4 ? URL(fileURLWithPath: values[3]) : nil
    }
}

private struct CatalogEnvelope: Encodable {
    let signed: SignedCloudCapabilityCatalogPayload
    let signature: String
}

private struct SignerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

do {
    let arguments = try Arguments(CommandLine.arguments)
    guard let seedText = ProcessInfo.processInfo.environment[
        "CLOUD_CAPABILITY_CATALOG_SIGNING_SEED"
    ], !seedText.isEmpty else {
        throw SignerError("CLOUD_CAPABILITY_CATALOG_SIGNING_SEED is required")
    }
    let seed = try CloudBase64URL.decode(seedText, expectedCount: 32)
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let payloadData = try Data(contentsOf: arguments.signedPayload)
    let payload = try JSONDecoder().decode(
        SignedCloudCapabilityCatalogPayload.self,
        from: payloadData
    )
    guard !payload.keyID.isEmpty else { throw SignerError("signed payload key_id is required") }
    let canonical = try CloudCapabilityCatalogVerifier.canonicalSignedBytes(payload)
    let signature = try privateKey.signature(for: canonical)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(CatalogEnvelope(
        signed: payload,
        signature: CloudBase64URL.encode(signature)
    )).write(to: arguments.envelopeOutput, options: .atomic)

    if let keyRingOutput = arguments.keyRingOutput {
        let keyRing: [String: Any] = [
            "schema_version": "1",
            "keys": [[
                "key_id": payload.keyID,
                "public_key": CloudBase64URL.encode(privateKey.publicKey.rawRepresentation),
                "status": "active",
            ]],
        ]
        try JSONSerialization.data(
            withJSONObject: keyRing,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ).write(to: keyRingOutput, options: .atomic)
    }
} catch {
    FileHandle.standardError.write(Data("cloud catalog signing failed: \(error)\n".utf8))
    exit(2)
}
