import Foundation
import XCTest
@testable import WebCapsuleCore

final class CapsuleManifestParserTests: XCTestCase {
    private let sha256 = String(repeating: "a", count: 64)

    func testParsesCompleteManifestAndRepositoryFixture() throws {
        let manifest = try CapsuleManifestParser.parse(data())
        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.capsuleId, "com.example.guide")
        XCTAssertEqual(manifest.files.first?.size, 12)
        XCTAssertEqual(manifest.policy.network.mode, .allowlist)
        XCTAssertEqual(manifest.policy.network.origins, ["https://api.example.com"])
        XCTAssertEqual(manifest.policy.bridgeCapabilities, ["storage.read"])

        let fixture = try repositoryFixture(named: "fixtures/format-v1/manifest.json")
        XCTAssertNoThrow(try CapsuleManifestParser.parse(Data(contentsOf: fixture)))
    }

    func testRejectsDuplicateRootAndNestedKeys() {
        assertError(.duplicateJSONKey) {
            try CapsuleManifestParser.parse(Data(#"{"formatVersion":1,"formatVersion":1}"#.utf8))
        }
        let json = String(data: data(), encoding: .utf8)!
            .replacingOccurrences(of: #""mode":"allowlist""#, with: #""mode":"allowlist","mode":"allowlist""#)
        assertError(.duplicateJSONKey) { try CapsuleManifestParser.parse(Data(json.utf8)) }
    }

    func testRejectsMalformedUTF8AndNonObjectRoot() {
        assertError(.invalidJSONValue) { try CapsuleManifestParser.parse(Data([0xFF])) }
        assertError(.invalidJSONValue) { try CapsuleManifestParser.parse(Data("[]".utf8)) }
    }

    func testRejectsMissingExtraAndMistypedFields() {
        var missing = validManifest()
        missing.removeValue(forKey: "keyId")
        assertError(.invalidJSONValue) { try CapsuleManifestParser.parse(data(missing)) }

        var extra = validManifest()
        extra["extra"] = true
        assertError(.invalidJSONValue) { try CapsuleManifestParser.parse(data(extra)) }

        var wrongType = validManifest()
        wrongType["version"] = 1
        assertError(.invalidJSONValue) { try CapsuleManifestParser.parse(data(wrongType)) }

        var nestedExtra = validManifest()
        var files = nestedExtra["files"] as! [[String: Any]]
        files[0]["extra"] = true
        nestedExtra["files"] = files
        assertError(.invalidJSONValue) { try CapsuleManifestParser.parse(data(nestedExtra)) }
    }

    func testValidatesFormatIdentifiersVersionsHashAndMediaType() {
        assertMutation("formatVersion", value: 2, code: .unsupportedFormatVersion)
        assertMutation("capsuleId", value: "Example", code: .invalidCapsuleID)
        assertMutation("capsuleId", value: String(repeating: "a", count: 254) + ".b", code: .invalidCapsuleID)
        assertMutation("version", value: "01.0.0", code: .invalidVersion)
        assertMutation("minimumRuntimeVersion", value: "1.0", code: .invalidVersion)
        assertMutation("keyId", value: "bad key", code: .invalidKeyID)
        assertFileMutation("sha256", value: String(repeating: "A", count: 64), code: .invalidHash)
        assertFileMutation("mediaType", value: "html", code: .invalidMediaType)
    }

    func testValidatesExactTimestampAndCalendar() {
        for timestamp in [
            "2026-08-14T10:00:03Z",
            "2026-08-14T10:00:02.000Z",
            "2026-08-14T10:00:02+00:00",
            "2026-02-29T10:00:02Z",
            "2024-02-30T10:00:02Z",
            "2024-13-01T10:00:02Z",
            "2024-01-01T24:00:02Z",
        ] {
            assertMutation("createdAt", value: timestamp, code: .invalidTimestamp)
        }
        assertMutationAccepts("createdAt", value: "2024-02-29T10:00:02Z")
    }

    func testValidatesPathSetOrderAndEntry() {
        assertFileMutation("path", value: "../index.html", code: .invalidPath)

        var duplicate = validManifest()
        duplicate["files"] = [file("a.html", size: 1), file("a.html", size: 1)]
        duplicate["entry"] = "a.html"
        assertError(.duplicatePath) { try CapsuleManifestParser.parse(data(duplicate)) }

        var collision = validManifest()
        collision["files"] = [file("A.html", size: 1), file("a.html", size: 1)]
        collision["entry"] = "A.html"
        assertError(.caseCollision) { try CapsuleManifestParser.parse(data(collision)) }

        var unordered = validManifest()
        unordered["files"] = [file("b.html", size: 1), file("a.html", size: 1)]
        unordered["entry"] = "b.html"
        assertError(.invalidOrder) { try CapsuleManifestParser.parse(data(unordered)) }

        assertMutation("entry", value: "missing.html", code: .invalidManifest)

        var empty = validManifest()
        empty["files"] = []
        assertError(.invalidManifest) { try CapsuleManifestParser.parse(data(empty)) }
    }

    func testEnforcesDeclaredSizeLimits() {
        assertFileMutation("size", value: -1, code: .limitExceeded)
        assertFileMutation("size", value: 50 * 1024 * 1024 + 1, code: .limitExceeded)

        var aggregate = validManifest()
        aggregate["files"] = (0..<6).map { file("\($0).bin", size: 50 * 1024 * 1024) }
        aggregate["entry"] = "0.bin"
        assertError(.limitExceeded) { try CapsuleManifestParser.parse(data(aggregate)) }
    }

    func testValidatesNetworkPolicyShapeOriginsCapabilitiesAndDuplicates() {
        var deny = validManifest()
        deny["policy"] = [
            "network": ["mode": "deny"],
            "navigation": ["externalOrigins": []],
            "bridgeCapabilities": [],
        ]
        let parsed = try? CapsuleManifestParser.parse(data(deny))
        XCTAssertEqual(parsed?.policy.network, CapsuleNetworkPolicy(mode: .deny))

        assertPolicy(network: ["mode": "unknown"], code: .invalidPolicy)
        assertPolicy(network: ["mode": "deny", "origins": []], code: .invalidJSONValue)
        assertPolicy(network: ["mode": "allowlist"], code: .invalidJSONValue)
        for origin in [
            "http://example.com", "https://user@example.com", "https://example.com/",
            "https://example.com/path", "https://example.com?x=1", "https://example.com#x",
            "https://example.com:8443", "https://example.com:", "HTTPS://example.com",
            "https://EXAMPLE.com", "https://%65xample.com",
        ] {
            assertPolicy(network: ["mode": "allowlist", "origins": [origin]], code: .invalidURL)
        }
        assertPolicyAccepts(network: [
            "mode": "allowlist",
            "origins": ["https://xn--r8jz45g.jp", "https://[::1]"],
        ])
        assertPolicy(
            network: ["mode": "allowlist", "origins": ["https://example.com", "https://example.com"]],
            code: .invalidPolicy
        )

        var duplicateNavigation = validManifest()
        duplicateNavigation["policy"] = [
            "network": ["mode": "deny"],
            "navigation": ["externalOrigins": ["https://example.com", "https://example.com"]],
            "bridgeCapabilities": [],
        ]
        assertError(.invalidPolicy) { try CapsuleManifestParser.parse(data(duplicateNavigation)) }

        var invalidCapability = validManifest()
        invalidCapability["policy"] = [
            "network": ["mode": "deny"],
            "navigation": ["externalOrigins": []],
            "bridgeCapabilities": ["bad capability"],
        ]
        assertError(.invalidPolicy) { try CapsuleManifestParser.parse(data(invalidCapability)) }
        invalidCapability["policy"] = [
            "network": ["mode": "deny"],
            "navigation": ["externalOrigins": []],
            "bridgeCapabilities": ["storage.read", "storage.read"],
        ]
        assertError(.invalidPolicy) { try CapsuleManifestParser.parse(data(invalidCapability)) }
    }

    private func validManifest() -> [String: Any] {
        [
            "formatVersion": 1,
            "capsuleId": "com.example.guide",
            "version": "1.0.0",
            "entry": "index.html",
            "createdAt": "2026-08-14T10:00:02Z",
            "minimumRuntimeVersion": "1.0.0",
            "keyId": "release-1",
            "files": [file("index.html", size: 12, mediaType: "text/html")],
            "policy": [
                "network": ["mode": "allowlist", "origins": ["https://api.example.com"]],
                "navigation": ["externalOrigins": ["https://example.com"]],
                "bridgeCapabilities": ["storage.read"],
            ],
        ]
    }

    private func file(_ path: String, size: Int, mediaType: String = "application/octet-stream") -> [String: Any] {
        ["path": path, "sha256": sha256, "size": size, "mediaType": mediaType]
    }

    private func data(_ manifest: [String: Any]? = nil) -> Data {
        try! JSONSerialization.data(withJSONObject: manifest ?? validManifest(), options: [.sortedKeys])
    }

    private func assertMutation(
        _ key: String,
        value: Any,
        code: WebCapsuleErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var manifest = validManifest()
        manifest[key] = value
        assertError(code, file: file, line: line) { try CapsuleManifestParser.parse(data(manifest)) }
    }

    private func assertMutationAccepts(
        _ key: String,
        value: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var manifest = validManifest()
        manifest[key] = value
        XCTAssertNoThrow(try CapsuleManifestParser.parse(data(manifest)), file: file, line: line)
    }

    private func assertFileMutation(
        _ key: String,
        value: Any,
        code: WebCapsuleErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var manifest = validManifest()
        var files = manifest["files"] as! [[String: Any]]
        files[0][key] = value
        manifest["files"] = files
        assertError(code, file: file, line: line) { try CapsuleManifestParser.parse(data(manifest)) }
    }

    private func assertPolicy(network: [String: Any], code: WebCapsuleErrorCode) {
        let manifest = manifestWithPolicy(network: network)
        assertError(code) { try CapsuleManifestParser.parse(data(manifest)) }
    }

    private func assertPolicyAccepts(network: [String: Any]) {
        let manifest = manifestWithPolicy(network: network)
        XCTAssertNoThrow(try CapsuleManifestParser.parse(data(manifest)))
    }

    private func manifestWithPolicy(network: [String: Any]) -> [String: Any] {
        var manifest = validManifest()
        manifest["policy"] = [
            "network": network,
            "navigation": ["externalOrigins": []],
            "bridgeCapabilities": [],
        ]
        return manifest
    }

    private func assertError(
        _ code: WebCapsuleErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Any
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? WebCapsuleError)?.code, code, file: file, line: line)
        }
    }

    private func repositoryFixture(named relativePath: String) throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Repository fixture is unavailable")
    }
}
