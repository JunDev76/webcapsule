import XCTest
@testable import WebCapsuleCore

final class WebCapsuleConfigValidatorTests: XCTestCase {
    private let valid = WebCapsuleConfig(
        capsuleId: "com.example.guide",
        bundledAssetPath: "webcapsule/guide-1.0.0.capsule",
        publicKeys: ["release-2027": "PUBLIC KEY"],
        runtimeVersion: "1.0.0"
    )

    func testAcceptsValidConfigAndNestedBundlePath() throws {
        XCTAssertNoThrow(try WebCapsuleConfigValidator.validate(valid))
        XCTAssertNoThrow(try WebCapsuleConfigValidator.validate(config(path: "assets/webcapsule/guide.capsule")))
    }

    func testRejectsUnsafeBundledAssetPaths() {
        let decomposed = "assets/cafe\u{301}.capsule"
        let paths = [
            "https://example.com/guide.capsule",
            "file://guide.capsule",
            "/webcapsule/guide.capsule",
            "webcapsule\\guide.capsule",
            "webcapsule/./guide.capsule",
            "webcapsule/../guide.capsule",
            "webcapsule/guide\0.capsule",
            decomposed,
            "webcapsule/guide.zip",
        ]
        for path in paths {
            assertError(.invalidPath) { try WebCapsuleConfigValidator.validate(config(path: path)) }
        }
    }

    func testValidatesCapsuleIDAtManifestContractLevel() {
        for capsuleId in ["", "Example.Guide", "guide", "com..guide", String(repeating: "a", count: 256) + ".b"] {
            assertError(.invalidCapsuleID) {
                try WebCapsuleConfigValidator.validate(WebCapsuleConfig(
                    capsuleId: capsuleId,
                    bundledAssetPath: valid.bundledAssetPath,
                    publicKeys: valid.publicKeys,
                    runtimeVersion: valid.runtimeVersion
                ))
            }
        }
    }

    func testValidatesPublicKeysAndRuntimeVersion() {
        assertError(.invalidArgument) { try WebCapsuleConfigValidator.validate(config(keys: [:])) }
        assertError(.invalidKeyID) { try WebCapsuleConfigValidator.validate(config(keys: ["bad key": "PUBLIC KEY"])) }
        assertError(.invalidPublicKey) { try WebCapsuleConfigValidator.validate(config(keys: ["release-2027": ""])) }
        for version in ["", "1", "01.0.0", "1.0.0-"] {
            assertError(.invalidVersion) { try WebCapsuleConfigValidator.validate(config(version: version)) }
        }
    }

    private func config(
        path: String? = nil,
        keys: [String: String]? = nil,
        version: String? = nil
    ) -> WebCapsuleConfig {
        WebCapsuleConfig(
            capsuleId: valid.capsuleId,
            bundledAssetPath: path ?? valid.bundledAssetPath,
            publicKeys: keys ?? valid.publicKeys,
            runtimeVersion: version ?? valid.runtimeVersion
        )
    }

    private func assertError(
        _ code: WebCapsuleErrorCode,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? WebCapsuleError)?.code, code, file: file, line: line)
        }
    }
}
