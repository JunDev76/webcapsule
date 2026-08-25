import CryptoKit
import Foundation
import XCTest
@testable import WebCapsuleCore

final class SignedManifestVerifierTests: XCTestCase {
    private let signatureDomain = Data("WEBCAPSULE-MANIFEST-V1\n".utf8)

    func testVerifiesCanonicalSignedManifest() throws {
        let vector = try makeVector()
        let manifest = try SignedManifestVerifier.verify(
            manifestData: vector.manifest,
            signatureData: vector.signature,
            request: vector.request
        )

        XCTAssertEqual(manifest.capsuleId, "com.example.fixture")
        XCTAssertEqual(manifest.keyId, "test-only")
        XCTAssertEqual(manifest.minimumRuntimeVersion, "1.0.0")
    }

    func testVerifiesCLIProducedFixtureVector() throws {
        // Public artifacts extracted from fixtures/capsules/valid-minimal.capsule.
        let manifest = Data((
            #"{"capsuleId":"com.example.fixture","createdAt":"2026-08-18T10:00:02Z","entry":"index.html","files":[{"mediaType":"text/html","path":"index.html","sha256":"5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03","size":6}],"formatVersion":1,"keyId":"test-only","minimumRuntimeVersion":"1.0.0","policy":{"bridgeCapabilities":[],"navigation":{"externalOrigins":[]},"network":{"mode":"deny"}},"version":"1.0.0"}"#
                + "\n"
        ).utf8)
        let signature = Data(
            "LDSemRaKEmc3jgm+mNoxQsxdTfNRes9zOf0GrpY2wATNn2tYt4u3R/VvfW1CblcJG9b5UvXTNm3OerUTumMfAw==\n".utf8
        )
        let publicKey = """
        -----BEGIN PUBLIC KEY-----
        MCowBQYDK2VwAyEASZ2/sWI/dMRkbB6ZWbqwOcRDDTjr1jYvHikcGiCZS+k=
        -----END PUBLIC KEY-----

        """

        let verified = try SignedManifestVerifier.verify(
            manifestData: manifest,
            signatureData: signature,
            request: ManifestVerificationRequest(
                expectedCapsuleId: "com.example.fixture",
                runtimeVersion: "1.0.0",
                publicKeys: ["test-only": publicKey]
            )
        )
        XCTAssertEqual(verified.files.first?.sha256, "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    }

    func testRejectsNoncanonicalManifestBeforeSignatureVerification() throws {
        let vector = try makeVector()
        let canonical = String(decoding: vector.manifest, as: UTF8.self)
        let variants = [
            " " + canonical,
            String(canonical.dropLast()),
            canonical + "\n",
            noncanonicalManifestSource() + "\n",
            canonical.replacingOccurrences(of: "com.example.fixture", with: "com.example.fixtur\\u0065"),
        ]
        for value in variants {
            assertError(.invalidManifest) {
                try SignedManifestVerifier.verify(
                    manifestData: Data(value.utf8),
                    signatureData: Data("not a signature".utf8),
                    request: vector.request
                )
            }
        }
    }

    func testCanonicalJSONUsesRFC8785UTF16KeyOrderingAndEscapes() throws {
        let value = try StrictJSON.parse(Data(#"{"\uE000":1,"\uD800\uDC00":2,"controls":"\u0000\b\t\n\f\r","plain":"/"}"#.utf8))
        XCTAssertEqual(
            String(decoding: CanonicalJSON.serialize(value), as: UTF8.self),
            #"{"controls":"\u0000\b\t\n\f\r","plain":"/","𐀀":2,"":1}"#
        )
    }

    func testRejectsMalformedSignatureEncodings() throws {
        let vector = try makeVector()
        var wrongAlphabet = vector.signature
        wrongAlphabet[0] = 0x2D
        var wrongPadding = vector.signature
        wrongPadding[86] = 0x41
        let cases = [
            Data(),
            vector.signature.dropLast(),
            vector.signature + Data([0x0A]),
            wrongAlphabet,
            wrongPadding,
            Data(String(repeating: "A", count: 84).appending("====\n").utf8),
        ]
        for signature in cases {
            assertError(.invalidSignature) {
                try SignedManifestVerifier.verify(
                    manifestData: vector.manifest,
                    signatureData: Data(signature),
                    request: vector.request
                )
            }
        }
    }

    func testRejectsMissingExactKeyAndNeverTriesAnotherKey() throws {
        let vector = try makeVector()
        let missingKeyRequest = ManifestVerificationRequest(
            expectedCapsuleId: "com.example.fixture",
            runtimeVersion: "1.0.0",
            publicKeys: ["other": vector.publicKey]
        )
        assertError(.invalidSignature) {
            try SignedManifestVerifier.verify(
                manifestData: vector.manifest,
                signatureData: Data("invalid".utf8),
                request: missingKeyRequest
            )
        }
        assertError(.keyIDMismatch) {
            try SignedManifestVerifier.verify(
                manifestData: vector.manifest,
                signatureData: vector.signature,
                request: missingKeyRequest
            )
        }

        let other = Curve25519.Signing.PrivateKey()
        let request = ManifestVerificationRequest(
            expectedCapsuleId: "com.example.fixture",
            runtimeVersion: "1.0.0",
            publicKeys: [
                "test-only": pem(for: other.publicKey.rawRepresentation),
                "fallback": vector.publicKey,
            ]
        )
        assertError(.signatureMismatch) {
            try SignedManifestVerifier.verify(
                manifestData: vector.manifest,
                signatureData: vector.signature,
                request: request
            )
        }
    }

    func testRejectsNoncanonicalAndInvalidPublicKeys() throws {
        let vector = try makeVector()
        let wrongAlgorithmDER = Data([
            0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x6E, 0x03, 0x21, 0x00,
        ]) + Data(repeating: 0x01, count: 32)
        let wrongAlgorithm = pem(forDER: wrongAlgorithmDER)
        let variants = [
            "not a key",
            vector.publicKey.replacingOccurrences(of: "\n", with: "\r\n"),
            String(vector.publicKey.dropLast()),
            " \(vector.publicKey)",
            vector.publicKey + vector.publicKey,
            vector.publicKey.replacingOccurrences(of: "MCow", with: "****"),
            wrongAlgorithm,
        ]
        for pem in variants {
            assertError(.invalidPublicKey) {
                try SignedManifestVerifier.verify(
                    manifestData: vector.manifest,
                    signatureData: vector.signature,
                    request: ManifestVerificationRequest(
                        expectedCapsuleId: "com.example.fixture",
                        runtimeVersion: "1.0.0",
                        publicKeys: ["test-only": pem]
                    )
                )
            }
        }
    }

    func testRejectsSignatureMutationIDMismatchAndRuntimeMismatch() throws {
        let vector = try makeVector()
        var rawSignature = Data(base64Encoded: vector.signature.dropLast())!
        rawSignature[0] ^= 0x01
        let mutation = Data(rawSignature.base64EncodedString().utf8) + Data([0x0A])
        assertError(.signatureMismatch) {
            try SignedManifestVerifier.verify(
                manifestData: vector.manifest,
                signatureData: mutation,
                request: vector.request
            )
        }

        assertError(.idMismatch) {
            try SignedManifestVerifier.verify(
                manifestData: vector.manifest,
                signatureData: vector.signature,
                request: ManifestVerificationRequest(
                    expectedCapsuleId: "com.other.fixture",
                    runtimeVersion: "1.0.0",
                    publicKeys: ["test-only": vector.publicKey]
                )
            )
        }
        assertError(.invalidVersion) {
            try SignedManifestVerifier.verify(
                manifestData: vector.manifest,
                signatureData: vector.signature,
                request: ManifestVerificationRequest(
                    expectedCapsuleId: "com.example.fixture",
                    runtimeVersion: "01.0.0",
                    publicKeys: ["test-only": vector.publicKey]
                )
            )
        }
        assertError(.runtimeIncompatible) {
            try SignedManifestVerifier.verify(
                manifestData: vector.manifest,
                signatureData: vector.signature,
                request: ManifestVerificationRequest(
                    expectedCapsuleId: "com.example.fixture",
                    runtimeVersion: "0.9.0",
                    publicKeys: ["test-only": vector.publicKey]
                )
            )
        }
    }

    func testRequestIsEquatableAndSendable() throws {
        let request = try makeVector().request
        XCTAssertEqual(request, request)
        assertSendable(request)
    }

    private struct Vector {
        let manifest: Data
        let signature: Data
        let request: ManifestVerificationRequest
        let publicKey: String
    }

    private func makeVector() throws -> Vector {
        let parsed = try StrictJSON.parse(Data(noncanonicalManifestSource().utf8))
        var manifest = CanonicalJSON.serialize(parsed)
        manifest.append(0x0A)

        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let signatureBytes = try privateKey.signature(for: signatureDomain + manifest.dropLast())
        let signature = Data(signatureBytes.base64EncodedString().utf8) + Data([0x0A])
        let publicKey = pem(for: privateKey.publicKey.rawRepresentation)
        return Vector(
            manifest: manifest,
            signature: signature,
            request: ManifestVerificationRequest(
                expectedCapsuleId: "com.example.fixture",
                runtimeVersion: "1.0.0",
                publicKeys: ["test-only": publicKey]
            ),
            publicKey: publicKey
        )
    }

    private func noncanonicalManifestSource() -> String {
        #"{"formatVersion":1,"capsuleId":"com.example.fixture","version":"1.0.0","entry":"index.html","createdAt":"2026-08-18T10:00:02Z","minimumRuntimeVersion":"1.0.0","keyId":"test-only","files":[{"path":"index.html","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":6,"mediaType":"text/html"}],"policy":{"network":{"mode":"deny"},"navigation":{"externalOrigins":[]},"bridgeCapabilities":[]}}"#
    }

    private func pem(for rawKey: Data) -> String {
        let prefix = Data([
            0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00,
        ])
        return pem(forDER: prefix + rawKey)
    }

    private func pem(forDER der: Data) -> String {
        "-----BEGIN PUBLIC KEY-----\n\(der.base64EncodedString())\n-----END PUBLIC KEY-----\n"
    }

    private func assertSendable<T: Sendable>(_: T) {}

    private func assertError(
        _ code: WebCapsuleErrorCode,
        operation: () throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? WebCapsuleError)?.code, code, file: file, line: line)
        }
    }
}
