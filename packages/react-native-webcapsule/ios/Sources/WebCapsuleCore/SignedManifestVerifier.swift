import CryptoKit
import Foundation

public struct ManifestVerificationRequest: Equatable, Sendable {
    public let expectedCapsuleId: String
    public let runtimeVersion: String
    public let publicKeys: [String: String]

    public init(expectedCapsuleId: String, runtimeVersion: String, publicKeys: [String: String]) {
        self.expectedCapsuleId = expectedCapsuleId
        self.runtimeVersion = runtimeVersion
        self.publicKeys = publicKeys
    }
}

struct SignedManifestVerification {
    let manifest: CapsuleManifest
    let canonicalManifest: Data
}

/// Verifies only the authenticity and host compatibility of `capsule.json`.
/// Archive structure, content hashes, installation, and activation remain unverified.
public enum SignedManifestVerifier {
    private static let signatureDomain = Data("WEBCAPSULE-MANIFEST-V1\n".utf8)
    private static let updateIndexSignatureDomain = Data("WEBCAPSULE-UPDATE-INDEX-V1\n".utf8)
    private static let publicKeyPrefix = Data([
        0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00,
    ])

    public static func verify(
        manifestData: Data,
        signatureData: Data,
        request: ManifestVerificationRequest
    ) throws -> CapsuleManifest {
        try validate(request)
        return try verifyValidated(
            manifestData: manifestData,
            signatureData: signatureData,
            request: request
        ).manifest
    }

    static func validate(_ request: ManifestVerificationRequest) throws {
        try CapsuleManifestParser.validateCapsuleID(request.expectedCapsuleId)
        try SemanticVersion.validate(request.runtimeVersion)
        guard !request.publicKeys.isEmpty else {
            throw WebCapsuleError(code: .invalidArgument, message: "publicKeys must not be empty")
        }
        for (keyId, pem) in request.publicKeys {
            try CapsuleManifestParser.validateKeyID(keyId)
            guard !pem.isEmpty else {
                throw WebCapsuleError(code: .invalidPublicKey, message: "Public key must not be empty")
            }
        }
    }

    static func verifyValidated(
        manifestData: Data,
        signatureData: Data,
        request: ManifestVerificationRequest
    ) throws -> SignedManifestVerification {
        let parsedJSON = try StrictJSON.parse(manifestData)
        let manifest = try CapsuleManifestParser.parse(parsedJSON)
        let canonicalManifest = CanonicalJSON.serialize(parsedJSON)
        var storedManifest = canonicalManifest
        storedManifest.append(0x0A)
        guard storedManifest == manifestData else {
            throw WebCapsuleError(code: .invalidManifest, message: "capsule.json is not canonical with one final LF")
        }

        guard manifest.capsuleId == request.expectedCapsuleId else {
            throw WebCapsuleError(code: .idMismatch, message: "Capsule ID does not match expected ID")
        }
        guard try SemanticVersion.compare(request.runtimeVersion, manifest.minimumRuntimeVersion) != .orderedAscending else {
            throw WebCapsuleError(code: .runtimeIncompatible, message: "Runtime version is incompatible")
        }
        let signature = try parseSignature(signatureData)
        guard let pem = request.publicKeys[manifest.keyId] else {
            throw WebCapsuleError(code: .keyIDMismatch, message: "No trusted key exists for the manifest key ID")
        }
        let publicKey = try parsePublicKey(pem)
        let payload = signatureDomain + canonicalManifest
        guard publicKey.isValidSignature(signature, for: payload) else {
            throw WebCapsuleError(code: .signatureMismatch, message: "Manifest signature verification failed")
        }
        return SignedManifestVerification(manifest: manifest, canonicalManifest: canonicalManifest)
    }

    static func verifyUpdateIndex(
        canonicalIndex: Data,
        signature: Data,
        keyId: String,
        publicKeys: [String: String]
    ) throws {
        guard signature.count == 64 else { throw invalidSignature() }
        guard let pem = publicKeys[keyId] else {
            throw WebCapsuleError(code: .keyIDMismatch, message: "No exact trusted update key ID")
        }
        let publicKey = try parsePublicKey(pem)
        guard publicKey.isValidSignature(signature, for: updateIndexSignatureDomain + canonicalIndex) else {
            throw WebCapsuleError(code: .signatureMismatch, message: "Update index signature verification failed")
        }
    }

    private static func parseSignature(_ data: Data) throws -> Data {
        guard data.count == 89, data.last == 0x0A else {
            throw invalidSignature()
        }
        let encoded = data.dropLast()
        guard encoded.count == 88,
              encoded.dropLast(2).allSatisfy(isBase64Character),
              encoded.suffix(2).elementsEqual([0x3D, 0x3D]),
              let decoded = Data(base64Encoded: Data(encoded), options: []),
              decoded.count == 64 else {
            throw invalidSignature()
        }
        return decoded
    }

    private static func parsePublicKey(_ pem: String) throws -> Curve25519.Signing.PublicKey {
        let begin = "-----BEGIN PUBLIC KEY-----\n"
        let end = "-----END PUBLIC KEY-----\n"
        guard pem.hasPrefix(begin), pem.hasSuffix(end) else {
            throw invalidPublicKey()
        }
        let start = pem.index(pem.startIndex, offsetBy: begin.count)
        let finish = pem.index(pem.endIndex, offsetBy: -end.count)
        let body = String(pem[start..<finish])
        guard body.utf8.count == 61,
              body.last == "\n",
              body.dropLast().utf8.count == 60,
              body.dropLast().utf8.allSatisfy(isBase64CharacterOrPadding),
              let der = Data(base64Encoded: String(body.dropLast()), options: []),
              der.count == 44,
              der.prefix(publicKeyPrefix.count) == publicKeyPrefix else {
            throw invalidPublicKey()
        }
        let rawKey = der.dropFirst(publicKeyPrefix.count)
        guard rawKey.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
              canonicalPEM(for: der) == pem else {
            throw invalidPublicKey()
        }
        return key
    }

    private static func canonicalPEM(for der: Data) -> String {
        "-----BEGIN PUBLIC KEY-----\n\(der.base64EncodedString())\n-----END PUBLIC KEY-----\n"
    }

    private static func isBase64Character(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte) || byte == 0x2B || byte == 0x2F
    }

    private static func isBase64CharacterOrPadding(_ byte: UInt8) -> Bool {
        isBase64Character(byte) || byte == 0x3D
    }

    private static func invalidSignature() -> WebCapsuleError {
        WebCapsuleError(code: .invalidSignature, message: "capsule.sig encoding is invalid")
    }

    private static func invalidPublicKey() -> WebCapsuleError {
        WebCapsuleError(code: .invalidPublicKey, message: "Public key must be one canonical Ed25519 SPKI PEM block")
    }
}
