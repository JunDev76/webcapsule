import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import WebCapsuleCore

final class CapsuleVerifierTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testVerifiesValidMinimalIntoSafeTransientStaging() throws {
        let root = try temporaryDirectory()
        let result = try verify(fixture("valid-minimal"), stagingRoot: root)

        XCTAssertEqual(result.manifest.capsuleId, "com.example.fixture")
        XCTAssertEqual(result.manifest.version, "1.0.0")
        XCTAssertEqual(result.manifest.files.map(\.path), ["index.html"])
        XCTAssertEqual(result.canonicalManifest.last, UInt8(ascii: "}"))
        XCTAssertNotEqual(result.canonicalManifest.last, 0x0A)
        XCTAssertEqual(
            result.manifestSHA256,
            SHA256.hash(data: result.canonicalManifest).map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].path, "index.html")
        XCTAssertEqual(result.files[0].mediaType, "text/html")
        XCTAssertEqual(result.files[0].stagedURL.lastPathComponent, "00000000.blob")
        XCTAssertFalse(result.files[0].stagedURL.path.contains("index.html"))
        XCTAssertEqual(try Data(contentsOf: result.files[0].stagedURL), Data("hello\n".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.operationDirectory.path))
        XCTAssertEqual(result.operationDirectory.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)

        try FileManager.default.removeItem(at: result.operationDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.operationDirectory.path))
    }

    func testMatchesEverySharedIOSCapsuleFixtureContract() throws {
        let contractData = try Data(contentsOf: repositoryRoot.appendingPathComponent("fixtures/expected-results.json"))
        let rootObject = try XCTUnwrap(JSONSerialization.jsonObject(with: contractData) as? [String: Any])
        let fixtures = try XCTUnwrap(rootObject["fixtures"] as? [[String: Any]])
        let publicKey = try fixturePublicKey()

        for fixture in fixtures {
            guard fixture["kind"] as? String == "capsule",
                  let platforms = fixture["platforms"] as? [String],
                  platforms.contains("ios") else {
                continue
            }
            let identifier = try XCTUnwrap(fixture["id"] as? String)
            let path = try XCTUnwrap(fixture["path"] as? String)
            let verification = try XCTUnwrap(fixture["verification"] as? [String: Any])
            let expectedID = try XCTUnwrap(verification["expectedCapsuleId"] as? String)
            let runtimeVersion = try XCTUnwrap(verification["runtimeVersion"] as? String)
            let trustedKeyID = verification["trustedKeyId"] as? String ?? "test-only"
            let stagingRoot = try temporaryDirectory()
            let request = CapsuleVerificationRequest(
                expectedCapsuleId: expectedID,
                runtimeVersion: runtimeVersion,
                publicKeys: [trustedKeyID: publicKey]
            )
            do {
                let result = try CapsuleVerifier().verify(
                    archiveURL: repositoryRoot.appendingPathComponent("fixtures").appendingPathComponent(path),
                    stagingRootURL: stagingRoot,
                    request: request
                )
                XCTAssertEqual(fixture["accepted"] as? Bool, true, identifier)
                try FileManager.default.removeItem(at: result.operationDirectory)
            } catch {
                XCTAssertEqual(fixture["accepted"] as? Bool, false, "\(identifier): \(error)")
                XCTAssertEqual(
                    (error as? WebCapsuleError)?.code.rawValue,
                    fixture["errorCode"] as? String,
                    identifier
                )
            }
            XCTAssertEqual(try directoryNames(stagingRoot), [], "staging leak: \(identifier)")
        }
    }

    func testCleansOperationAndPreservesSiblingForMetadataSignatureAndHashFailures() throws {
        let cases = ["noncanonical-manifest", "signature-mismatch", "content-hash-mismatch"]
        for name in cases {
            let root = try temporaryDirectory()
            let sibling = root.appendingPathComponent("caller-owned.txt")
            try Data("keep".utf8).write(to: sibling)
            XCTAssertThrowsError(try verify(fixture(name), stagingRoot: root))
            XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8), name)
            XCTAssertEqual(try directoryNames(root), ["caller-owned.txt"], name)
        }
    }

    func testRejectsDeclaredCentralSizeMismatchBeforeCreatingAContentFile() throws {
        var archive = try Data(contentsOf: fixture("valid-minimal"))
        let record = try zipRecords(archive)[2]
        set32(&archive, record.central + 24, record.uncompressedSize + 1)
        if record.flags & 0x0008 != 0 {
            set32(&archive, record.data + Int(record.compressedSize) + 12, record.uncompressedSize + 1)
        } else {
            set32(&archive, record.local + 22, record.uncompressedSize + 1)
        }
        let url = try temporaryArchive(archive)
        let root = try temporaryDirectory()
        assertError(.hashMismatch) {
            try verify(url, stagingRoot: root)
        }
        XCTAssertEqual(try directoryNames(root), [])
    }

    func testEnforcesInjectedArchiveMetadataFileCountAndAggregateLimits() throws {
        let archiveSize = UInt64(try Data(contentsOf: fixture("valid-minimal")).count)
        let cases: [(CapsuleVerificationLimits, WebCapsuleErrorCode)] = [
            (CapsuleVerificationLimits(archiveBytes: archiveSize - 1), .limitExceeded),
            (CapsuleVerificationLimits(manifestBytes: 1), .limitExceeded),
            (CapsuleVerificationLimits(contentBytes: 5), .limitExceeded),
            (CapsuleVerificationLimits(fileBytes: 5), .limitExceeded),
            (CapsuleVerificationLimits(fileCount: 0), .limitExceeded),
        ]
        for (limits, code) in cases {
            let root = try temporaryDirectory()
            assertError(code) {
                try verify(fixture("valid-minimal"), stagingRoot: root, limits: limits)
            }
            XCTAssertEqual(try directoryNames(root), [])
        }
    }

    func testRejectsMalformedAndOversizedSignatureMetadata() throws {
        let malformedRoot = try temporaryDirectory()
        assertError(.invalidSignature) {
            try verify(fixture("malformed-signature"), stagingRoot: malformedRoot)
        }
        XCTAssertEqual(try directoryNames(malformedRoot), [])

        var oversized = try Data(contentsOf: fixture("valid-minimal"))
        let signature = try zipRecords(oversized)[1]
        set32(&oversized, signature.central + 24, 90)
        if signature.flags & 0x0008 != 0 {
            set32(&oversized, signature.data + Int(signature.compressedSize) + 12, 90)
        } else {
            set32(&oversized, signature.local + 22, 90)
        }
        let oversizedRoot = try temporaryDirectory()
        assertError(.limitExceeded) {
            try verify(temporaryArchive(oversized), stagingRoot: oversizedRoot)
        }
        XCTAssertEqual(try directoryNames(oversizedRoot), [])
    }

    func testCleansCompletedAndPartialFilesAfterMidContentCorruption() throws {
        var archive = try Data(contentsOf: fixture("android-e2e-v1"))
        let records = try zipRecords(archive)
        XCTAssertGreaterThan(records.count, 4)
        let secondContent = records[3]
        archive[secondContent.data + Int(secondContent.compressedSize / 2)] ^= 0xFF
        let root = try temporaryDirectory()
        let request = CapsuleVerificationRequest(
            expectedCapsuleId: "com.example.android.e2e",
            runtimeVersion: "1.0.0",
            publicKeys: ["test-only": try fixturePublicKey()]
        )
        assertError(.archiveInvalid) {
            try CapsuleVerifier().verify(
                archiveURL: temporaryArchive(archive),
                stagingRootURL: root,
                request: request
            )
        }
        XCTAssertEqual(try directoryNames(root), [])
    }

    func testRejectsRawDOSTimestampMismatchAndOutOfRangeYears() throws {
        var archive = try Data(contentsOf: fixture("valid-minimal"))
        for record in try zipRecords(archive) {
            set16(&archive, record.central + 12, read16(archive, record.central + 12) ^ 1)
            set16(&archive, record.local + 10, read16(archive, record.local + 10) ^ 1)
        }
        let root = try temporaryDirectory()
        assertError(.invalidTimestamp) {
            try verify(temporaryArchive(archive), stagingRoot: root)
        }
        XCTAssertEqual(try directoryNames(root), [])

        assertError(.invalidTimestamp) { try DOSTimestamp(createdAt: "1979-12-31T23:59:58Z") }
        assertError(.invalidTimestamp) { try DOSTimestamp(createdAt: "2108-01-01T00:00:00Z") }
        let lower = try DOSTimestamp(createdAt: "1980-01-01T00:00:00Z")
        let upper = try DOSTimestamp(createdAt: "2107-12-31T23:59:58Z")
        XCTAssertEqual(lower.date, 0x0021)
        XCTAssertEqual(upper.date, 0xFF9F)
    }

    func testRejectsInvalidStagingRootsAndArchiveSymlinkWithoutTouchingTargets() throws {
        let parent = try temporaryDirectory()
        let missing = parent.appendingPathComponent("missing", isDirectory: true)
        assertError(.unsafeStorageLayout) {
            try verify(fixture("valid-minimal"), stagingRoot: missing)
        }

        let fileRoot = parent.appendingPathComponent("file")
        try Data().write(to: fileRoot)
        assertError(.unsafeStorageLayout) {
            try verify(fixture("valid-minimal"), stagingRoot: fileRoot)
        }

        let realRoot = try temporaryDirectory()
        let rootLink = parent.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: realRoot)
        assertError(.unsafeStorageLayout) {
            try verify(fixture("valid-minimal"), stagingRoot: rootLink)
        }
        XCTAssertEqual(try directoryNames(realRoot), [])

        let archiveLink = parent.appendingPathComponent("archive-link.capsule")
        try FileManager.default.createSymbolicLink(at: archiveLink, withDestinationURL: fixture("valid-minimal"))
        assertError(.archiveInvalid) {
            try verify(archiveLink, stagingRoot: realRoot)
        }
        XCTAssertEqual(try directoryNames(realRoot), [])
    }

    func testValidatesRequestBeforeFilesystemArgumentsAndRejectsUnsafeLimits() throws {
        let missing = URL(fileURLWithPath: "/definitely/missing/archive.capsule")
        let root = try temporaryDirectory()
        let invalidRequest = CapsuleVerificationRequest(
            expectedCapsuleId: "invalid",
            runtimeVersion: "1.0.0",
            publicKeys: [:]
        )
        assertError(.invalidCapsuleID) {
            try CapsuleVerifier().verify(archiveURL: missing, stagingRootURL: root, request: invalidRequest)
        }
        assertError(.invalidArgument) {
            try verify(
                fixture("valid-minimal"),
                stagingRoot: root,
                limits: CapsuleVerificationLimits(signatureBytes: 88)
            )
        }
        XCTAssertEqual(try directoryNames(root), [])
    }

    func testPublicVerificationModelsAreImmutableValueTypesAndSendable() throws {
        let request = defaultRequest()
        let limits = CapsuleVerificationLimits.v1
        XCTAssertEqual(request, request)
        XCTAssertEqual(limits, limits)
        assertSendable(request)
        assertSendable(limits)
        let result = try verify(fixture("valid-minimal"), stagingRoot: temporaryDirectory())
        XCTAssertEqual(result, result)
        assertSendable(result)
        try FileManager.default.removeItem(at: result.operationDirectory)
    }

    private func verify(
        _ archive: URL,
        stagingRoot: URL,
        limits: CapsuleVerificationLimits = .v1
    ) throws -> VerifiedCapsule {
        try CapsuleVerifier(limits: limits).verify(
            archiveURL: archive,
            stagingRootURL: stagingRoot,
            request: defaultRequest()
        )
    }

    private func defaultRequest() -> CapsuleVerificationRequest {
        CapsuleVerificationRequest(
            expectedCapsuleId: "com.example.fixture",
            runtimeVersion: "1.0.0",
            publicKeys: ["test-only": try! fixturePublicKey()]
        )
    }

    private func fixturePublicKey() throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("fixtures/keys/test-only-public.pem"),
            encoding: .utf8
        )
    }

    private func fixture(_ name: String) -> URL {
        repositoryRoot
            .appendingPathComponent("fixtures/capsules", isDirectory: true)
            .appendingPathComponent("\(name).capsule")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("webcapsule-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }

    private func temporaryArchive(_ data: Data) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("test.capsule")
        try data.write(to: url)
        return url
    }

    private func directoryNames(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func assertSendable<T: Sendable>(_: T) {}

    private func assertError(
        _ code: WebCapsuleErrorCode,
        operation: () throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? WebCapsuleError)?.code, code, "\(error)", file: file, line: line)
        }
    }
}

private struct VerifierTestZipRecord {
    let central: Int
    let local: Int
    let data: Int
    let flags: UInt16
    let compressedSize: UInt32
    let uncompressedSize: UInt32
}

private func zipRecords(_ bytes: Data) throws -> [VerifierTestZipRecord] {
    guard bytes.count >= 22 else { throw VerifierTestZipError.invalid }
    var eocd: Int?
    for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
    where read32(bytes, offset) == 0x0605_4B50 {
        eocd = offset
        break
    }
    guard let eocd else { throw VerifierTestZipError.invalid }
    let count = Int(read16(bytes, eocd + 10))
    var central = Int(read32(bytes, eocd + 16))
    var result: [VerifierTestZipRecord] = []
    for _ in 0..<count {
        guard read32(bytes, central) == 0x0201_4B50 else { throw VerifierTestZipError.invalid }
        let nameLength = Int(read16(bytes, central + 28))
        let extraLength = Int(read16(bytes, central + 30))
        let commentLength = Int(read16(bytes, central + 32))
        let local = Int(read32(bytes, central + 42))
        let localNameLength = Int(read16(bytes, local + 26))
        let localExtraLength = Int(read16(bytes, local + 28))
        result.append(VerifierTestZipRecord(
            central: central,
            local: local,
            data: local + 30 + localNameLength + localExtraLength,
            flags: read16(bytes, central + 8),
            compressedSize: read32(bytes, central + 20),
            uncompressedSize: read32(bytes, central + 24)
        ))
        central += 46 + nameLength + extraLength + commentLength
    }
    return result
}

private func read16(_ bytes: Data, _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func read32(_ bytes: Data, _ offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
}

private func set16(_ bytes: inout Data, _ offset: Int, _ value: UInt16) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func set32(_ bytes: inout Data, _ offset: Int, _ value: UInt32) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}

private enum VerifierTestZipError: Error {
    case invalid
}
