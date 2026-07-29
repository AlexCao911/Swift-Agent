import CoreFoundation
import Foundation
import Testing
@testable import LocalAgentLLMContracts

@Suite("CanonicalDigestV1")
struct CanonicalDigestTests {
    @Test
    func canonicalizesRFC8785NumberSample() throws {
        let fixture = try DigestFixture.load("jcs-number-samples.json")

        let bytes = try CanonicalDigestV1.canonicalize(fixture.document)

        #expect(String(decoding: bytes, as: UTF8.self) == fixture.expectedCanonicalUTF8)
    }

    @Test
    func requirementsDigestMatchesRustGolden() throws {
        let fixture = try DigestFixture.load("agent-requirements-v1.json")

        let digest = try CanonicalDigestV1.digest(
            domain: try #require(fixture.domain),
            document: fixture.document
        )

        let expectedSHA256 = try #require(fixture.expectedSHA256)
        #expect(digest.hex == expectedSHA256)
        #expect(digest.hex == "df309a1f80fb005d51e9aa7f249939f9480d106d5d5ea43d102935bdd1baee30")
    }

    @Test
    func localCapabilityDigestsMatchSharedFixtures() throws {
        for name in [
            "capability-evidence-local-catalog-v1.json",
            "capability-observation-local-catalog-v1.json",
            "capability-snapshot-local-v1.json",
            "resolved-parameters-local-v1.json",
            "egress-subject-local-v1.json",
            "egress-attestation-local-v1.json",
        ] {
            let fixture = try DigestFixture.load(name)
            let canonical = try CanonicalDigestV1.canonicalize(fixture.document)
            #expect(String(decoding: canonical, as: UTF8.self) == fixture.expectedCanonicalUTF8)
            let digest = try CanonicalDigestV1.digest(
                domain: try #require(fixture.domain),
                document: fixture.document
            )
            let expected = try #require(fixture.expectedSHA256)
            #expect(digest.hex == expected)
        }
    }

    @Test
    func hostBridgeDigestsMatchSharedFixtures() throws {
        for name in [
            "host-command-payload-v1.json",
            "host-command-envelope-v1.json",
            "llm-event-envelope-v1.json",
            "llm-event-receipt-v1.json",
            "host-tool-effect-result-v1.json",
        ] {
            let fixture = try DigestFixture.load(name)
            let expected = try #require(fixture.expectedSHA256)
            #expect(String(decoding: try CanonicalDigestV1.canonicalize(fixture.document), as: UTF8.self)
                == fixture.expectedCanonicalUTF8)
            #expect(try CanonicalDigestV1.digest(
                domain: try #require(fixture.domain),
                document: fixture.document
            ).hex == expected)
        }
    }

    @Test
    func cloudPolicyDigestsMatchSharedFixtures() throws {
        for name in [
            "generation-disclosure-cloud-v1.json",
            "provider-retention-approval-cloud-v1.json",
            "credential-use-lease-cloud-v1.json",
            "egress-approval-summary-cloud-v1.json",
            "egress-scope-grant-cloud-v1.json",
            "egress-generation-authorization-cloud-v1.json",
            "egress-subject-cloud-v1.json",
            "egress-attestation-cloud-v1.json",
            "egress-audit-chain-cloud-v1.json",
            "capability-evidence-cloud-v1.json",
            "capability-observation-cloud-v1.json",
            "capability-snapshot-cloud-v1.json",
            "resolved-parameters-cloud-v1.json",
        ] {
            let fixture = try DigestFixture.load(name)
            let canonical = try CanonicalDigestV1.canonicalize(fixture.document)
            #expect(String(decoding: canonical, as: UTF8.self) == fixture.expectedCanonicalUTF8)
            let digest = try CanonicalDigestV1.digest(
                domain: try #require(fixture.domain),
                document: fixture.document
            )
            let expected = try #require(fixture.expectedSHA256)
            #expect(digest.hex == expected)
        }
    }

    @Test
    func preparedStartDigestsMatchRustGoldens() throws {
        let registration = try CanonicalJSONValue.object(entries: [
            .init(name: "preparation_id", value: .string("prep-1")),
            .init(name: "proposed_run_id", value: .string("run-1")),
            .init(name: "session_handle", value: .string("session-1")),
            .init(name: "swift_snapshot_id", value: .string("snapshot-1")),
            .init(name: "host_process_epoch", value: .string("epoch-1")),
            .init(name: "binding_id", value: .string("binding-1")),
            .init(name: "binding_revision", value: .number(1)),
            .init(name: "binding_hash", value: .string("hash-1")),
        ])
        #expect(try CanonicalDigestV1.digest(
            domain: "prepared-session-registration:v1",
            document: registration
        ).hex == "bf8781c344b00320a632381b2224bb4acb6b99e160baac2013a82691da1a5265")

        let capability = try CanonicalJSONValue.object(entries: [
            .init(name: "supported_capabilities", value: .array([.string("reasoning")])),
            .init(name: "input_modalities", value: .array([.string("text")])),
            .init(name: "context_length", value: .string("8192")),
            .init(name: "streaming", value: .bool(true)),
            .init(name: "tool_calling", value: .bool(true)),
            .init(name: "expiration_millis", value: .number(120_000)),
        ])
        #expect(try CanonicalDigestV1.digest(
            domain: "capability-attestation:v1",
            document: capability
        ).hex == "9673926303e128b9467da26d2a89a39f06f1b1f5c1b01a3eed185c27542cb862")

    }

    @Test
    func registeredDomainsMatchSharedRegistry() throws {
        let registry = try DigestRegistry.load()

        #expect(CanonicalDigestV1.registeredDomains == registry.domains)
        #expect(registry.domains.count == 37)
    }

    @Test
    func duplicateObjectNamesAreRejected() {
        #expect(throws: CanonicalDigestError.self) {
            try CanonicalJSONValue.object(entries: [
                CanonicalJSONObjectEntry(name: "same", value: .bool(true)),
                CanonicalJSONObjectEntry(name: "same", value: .bool(false)),
            ])
        }
    }

    @Test
    func malformedAndUnregisteredDomainsAreRejected() throws {
        let document = try CanonicalJSONValue.object(entries: [
            CanonicalJSONObjectEntry(name: "schema_version", value: .string("1")),
        ])

        assertDigestError("canonical_digest.domain_unregistered") {
            try CanonicalDigestV1.digest(domain: "not-registered:v1", document: document)
        }
        assertDigestError("canonical_digest.domain_invalid") {
            try CanonicalDigestV1.digest(domain: "Agent-requirements:v1", document: document)
        }
        assertDigestError("canonical_digest.domain_invalid") {
            try CanonicalDigestV1.digest(domain: "agent-requirements:v1\0x", document: document)
        }
    }

    @Test
    func numberAndStringEdgeCasesFollowJCS() throws {
        #expect(try canonicalString(.number(-0.0)) == "0")
        #expect(try canonicalString(.number(1e20)) == "100000000000000000000")
        #expect(try canonicalString(.number(1e21)) == "1e+21")
        #expect(try canonicalString(.number(1e-6)) == "0.000001")
        #expect(try canonicalString(.number(1e-7)) == "1e-7")
        #expect(try canonicalString(.string("\u{000f}\n\"\\/")) == "\"\\u000f\\n\\\"\\\\/\"")
        assertDigestError("canonical_digest.number_non_finite") {
            try CanonicalDigestV1.canonicalize(.number(.infinity))
        }
    }

    @Test
    func objectKeysUseUnsignedUTF16Ordering() throws {
        let document = try CanonicalJSONValue.object(entries: [
            CanonicalJSONObjectEntry(name: "😀", value: .number(6)),
            CanonicalJSONObjectEntry(name: "€", value: .number(5)),
            CanonicalJSONObjectEntry(name: "ö", value: .number(4)),
            CanonicalJSONObjectEntry(name: "\u{0080}", value: .number(3)),
            CanonicalJSONObjectEntry(name: "1", value: .number(2)),
            CanonicalJSONObjectEntry(name: "\r", value: .number(1)),
        ])

        #expect(
            try canonicalString(document)
                == "{\"\\r\":1,\"1\":2,\"\u{0080}\":3,\"ö\":4,\"€\":5,\"😀\":6}"
        )
    }
}

private struct DigestFixture {
    let domain: String?
    let document: CanonicalJSONValue
    let expectedCanonicalUTF8: String
    let expectedSHA256: String?

    static func load(_ name: String) throws -> Self {
        let object = try JSONObject.load(contractsRoot.appendingPathComponent("fixtures/\(name)"))
        return Self(
            domain: object["domain"] as? String,
            document: try canonicalValue(try #require(object["document"])),
            expectedCanonicalUTF8: try #require(object["expected_canonical_utf8"] as? String),
            expectedSHA256: object["expected_sha256"] as? String
        )
    }
}

private struct DigestRegistry {
    let domains: Set<String>

    static func load() throws -> Self {
        let object = try JSONObject.load(contractsRoot.appendingPathComponent("registry.json"))
        let rows = try #require(object["domains"] as? [[String: Any]])
        return Self(domains: Set(try rows.map { try #require($0["domain"] as? String) }))
    }
}

private enum JSONObject {
    static func load(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private var contractsRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("contracts/canonical-digest-v1")
}

private func canonicalValue(_ value: Any) throws -> CanonicalJSONValue {
    if value is NSNull {
        return .null
    }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        return .number(number.doubleValue)
    }
    if let string = value as? String {
        return .string(string)
    }
    if let array = value as? [Any] {
        return .array(try array.map(canonicalValue))
    }
    if let object = value as? [String: Any] {
        return try .object(entries: object.map {
            CanonicalJSONObjectEntry(name: $0.key, value: try canonicalValue($0.value))
        })
    }
    throw FixtureError.unsupportedValue(String(describing: type(of: value)))
}

private func canonicalString(_ value: CanonicalJSONValue) throws -> String {
    String(decoding: try CanonicalDigestV1.canonicalize(value), as: UTF8.self)
}

private func assertDigestError<T>(
    _ expectedCode: String,
    operation: () throws -> T
) {
    do {
        _ = try operation()
        Issue.record("expected CanonicalDigestError with code \(expectedCode)")
    } catch let error as CanonicalDigestError {
        #expect(error.code == expectedCode)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private enum FixtureError: Error {
    case unsupportedValue(String)
}
