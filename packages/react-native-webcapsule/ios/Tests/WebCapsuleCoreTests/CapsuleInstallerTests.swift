import Darwin
import Foundation
import XCTest
@testable import WebCapsuleCore

final class CapsuleInstallerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testInstallsBundledFixtureWithExactLayoutRecordBytesAndModes() throws {
        let root = try temporaryDirectory()
        let result = try installer(root).installBundled(archiveURL: fixture("valid-minimal"), request: fixtureRequest())

        XCTAssertTrue(result.installed)
        XCTAssertEqual(result.publishedBlobCount, 1)
        XCTAssertEqual(result.record.capsuleId, "com.example.fixture")
        let digest = result.record.files[0].sha256
        let blob = blobURL(root, digest)
        XCTAssertEqual(try Data(contentsOf: blob), Data("hello\n".utf8))
        XCTAssertEqual(try mode(blob), 0o444)

        let recordURL = versionURL(root, id: result.record.capsuleId, version: result.record.version)
            .appendingPathComponent("record.json")
        let expected = "{\"capsuleId\":\"com.example.fixture\",\"createdAt\":\"2026-08-18T10:00:02Z\",\"entry\":\"index.html\",\"files\":[{\"mediaType\":\"text/html\",\"path\":\"index.html\",\"sha256\":\"5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03\",\"size\":6}],\"keyId\":\"test-only\",\"manifestSha256\":\"eeac8a1a8578110eead251fcb7533f3c6f52eea62e1fe11a8d16c47583d96b53\",\"schemaVersion\":1,\"version\":\"1.0.0\"}\n"
        XCTAssertEqual(try String(contentsOf: recordURL, encoding: .utf8), expected)
        XCTAssertEqual(try mode(recordURL), 0o444)
        XCTAssertEqual(try names(recordURL.deletingLastPathComponent()), ["record.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("registries").path))
        XCTAssertEqual(try installer(root).readInstalledVersion(capsuleId: "com.example.fixture", version: "1.0.0"), result.record)
    }

    func testSecondInstallIsIdempotentAndSharedContentIsDeduplicated() throws {
        let root = try temporaryDirectory()
        let store = try installer(root)
        let first = try store.installBundled(archiveURL: fixture("valid-minimal"), request: fixtureRequest())
        let second = try store.installBundled(archiveURL: fixture("valid-minimal"), request: fixtureRequest())
        XCTAssertTrue(first.installed)
        XCTAssertFalse(second.installed)
        XCTAssertEqual(second.publishedBlobCount, 0)

        let e2e = try temporaryDirectory()
        let e2eStore = try installer(e2e)
        let v1 = try e2eStore.installBundled(archiveURL: fixture("android-e2e-v1"), request: e2eRequest())
        let v2 = try e2eStore.installBundled(archiveURL: fixture("android-e2e-v2"), request: e2eRequest())
        XCTAssertEqual(v1.publishedBlobCount, 5)
        XCTAssertEqual(v2.publishedBlobCount, 2)
        XCTAssertEqual(try regularFileCount(e2e.appendingPathComponent("blobs/sha256")), 7)
    }

    func testRejectsStagedMutationSizeChangeAndSymlinkReplacement() throws {
        for mutation in 0..<3 {
            let root = try temporaryDirectory()
            let verified = try verify(root: root)
            let staged = verified.files[0].stagedURL
            switch mutation {
            case 0:
                try Data("jello\n".utf8).write(to: staged)
            case 1:
                try Data("too long".utf8).write(to: staged)
            default:
                try FileManager.default.removeItem(at: staged)
                let target = root.appendingPathComponent("target")
                try Data("hello\n".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: target)
            }
            let expected: WebCapsuleErrorCode = mutation == 0 ? .hashMismatch : (mutation == 1 ? .storageInvariantViolation : .unsafeStorageLayout)
            assertError(expected) { try self.installer(root).installVerified(verified) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: versionURL(root, id: "com.example.fixture", version: "1.0.0").path))
        }
    }

    func testExistingValidBlobIsReusedAndUnsafeBlobCollisionsAreNeverOverwritten() throws {
        let digest = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
        let validRoot = try temporaryDirectory()
        let validBlob = blobURL(validRoot, digest)
        try FileManager.default.createDirectory(at: validBlob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: validBlob)
        XCTAssertEqual(Darwin.chmod(validBlob.path, 0o444), 0)
        XCTAssertEqual(try installer(validRoot).installBundled(archiveURL: fixture("valid-minimal"), request: fixtureRequest()).publishedBlobCount, 0)

        for collision in 0..<3 {
            let root = try temporaryDirectory()
            let destination = blobURL(root, digest)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if collision == 0 {
                try Data("wrong!".utf8).write(to: destination)
                XCTAssertEqual(Darwin.chmod(destination.path, 0o444), 0)
            } else if collision == 1 {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: fixture("valid-minimal"))
            } else {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            }
            assertError(.storageInvariantViolation) {
                try self.installer(root).installBundled(archiveURL: self.fixture("valid-minimal"), request: self.fixtureRequest())
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: versionURL(root, id: "com.example.fixture", version: "1.0.0").path))
            if collision == 0 { XCTAssertEqual(try Data(contentsOf: destination), Data("wrong!".utf8)) }
        }
    }

    func testExistingVersionMustBeExactCanonicalCompleteAndNeverRepaired() throws {
        for mutation in 0..<5 {
            let root = try temporaryDirectory()
            let store = try installer(root)
            _ = try store.installBundled(archiveURL: fixture("valid-minimal"), request: fixtureRequest())
            let directory = versionURL(root, id: "com.example.fixture", version: "1.0.0")
            let record = directory.appendingPathComponent("record.json")
            XCTAssertEqual(Darwin.chmod(record.path, 0o644), 0)
            switch mutation {
            case 0: try FileHandle(forWritingTo: record).truncate(atOffset: 2)
            case 1:
                let bytes = try Data(contentsOf: record)
                try Data(bytes.dropLast()).write(to: record)
            case 2:
                try Data("x".utf8).write(to: directory.appendingPathComponent("extra"))
            case 3:
                try FileManager.default.removeItem(at: record)
            default:
                try FileManager.default.removeItem(at: record)
                try FileManager.default.createSymbolicLink(at: record, withDestinationURL: fixture("valid-minimal"))
            }
            assertError(.storageInvariantViolation) {
                try store.installBundled(archiveURL: self.fixture("valid-minimal"), request: self.fixtureRequest())
            }
        }

        let incompleteRoot = try temporaryDirectory()
        let incomplete = versionURL(incompleteRoot, id: "com.example.fixture", version: "1.0.0")
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        assertError(.storageInvariantViolation) {
            try self.installer(incompleteRoot).installBundled(archiveURL: self.fixture("valid-minimal"), request: self.fixtureRequest())
        }
    }

    func testVersionRecordParserRejectsUnknownMissingDuplicateAndNoncanonicalBytes() throws {
        let root = try temporaryDirectory()
        let installed = try installer(root).installBundled(archiveURL: fixture("valid-minimal"), request: fixtureRequest())
        let valid = try VersionRecordCodec.serialize(installed.record)
        XCTAssertEqual(try VersionRecordCodec.parse(valid), installed.record)
        let source = String(decoding: valid, as: UTF8.self)
        let variants = [
            source.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"unknown\":0,\"schemaVersion\":1"),
            source.replacingOccurrences(of: "\"entry\":\"index.html\",", with: ""),
            source.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1"),
            " " + source,
            String(source.dropLast()),
        ]
        for bytes in variants {
            assertError(.versionRecordInvalid) { try VersionRecordCodec.parse(Data(bytes.utf8)) }
        }
    }

    func testStrictReadRejectsMissingBlobAndRecordSymlink() throws {
        let root = try temporaryDirectory()
        let store = try installer(root)
        let result = try store.installBundled(archiveURL: fixture("valid-minimal"), request: fixtureRequest())
        XCTAssertEqual(Darwin.chmod(blobURL(root, result.record.files[0].sha256).path, 0o644), 0)
        try FileManager.default.removeItem(at: blobURL(root, result.record.files[0].sha256))
        assertError(.blobMissing) { try store.readInstalledVersion(capsuleId: "com.example.fixture", version: "1.0.0") }

        let other = try temporaryDirectory()
        let otherStore = try installer(other)
        _ = try otherStore.installBundled(archiveURL: fixture("valid-minimal"), request: fixtureRequest())
        let record = versionURL(other, id: "com.example.fixture", version: "1.0.0").appendingPathComponent("record.json")
        XCTAssertEqual(Darwin.chmod(record.path, 0o644), 0)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: fixture("valid-minimal"))
        assertError(.versionRecordInvalid) { try otherStore.readInstalledVersion(capsuleId: "com.example.fixture", version: "1.0.0") }
    }

    func testVerifiedCapsuleIsConsumedOnceAndCleanupPreservesSiblings() throws {
        let root = try temporaryDirectory()
        _ = try installer(root)
        let sibling = root.appendingPathComponent("staging/caller-owned")
        try Data("keep".utf8).write(to: sibling)
        let verified = try verify(root: root)
        let operation = verified.operationDirectory
        _ = try installer(root).installVerified(verified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: operation.path))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
        assertError(.storageInvariantViolation) { try self.installer(root).installVerified(verified) }
    }

    func testAbandonedVerifiedCapsuleCleansOnlyOwnedStaging() throws {
        let root = try temporaryDirectory()
        _ = try installer(root)
        let sibling = root.appendingPathComponent("staging/caller-owned")
        try Data("keep".utf8).write(to: sibling)
        var verified: VerifiedCapsule? = try verify(root: root)
        let operation = try XCTUnwrap(verified?.operationDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: operation.path))

        verified = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: operation.path))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
    }

    func testConcurrentSameInstallProducesOnePublicationWithoutCorruption() throws {
        let root = try temporaryDirectory()
        let installers = try (0..<8).map { _ in try installer(root) }
        let queue = DispatchQueue(label: "webcapsule.install.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [CapsuleInstallResult] = []
        var failures: [Error] = []
        for store in installers {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let result = try store.installBundled(archiveURL: self.fixture("valid-minimal"), request: self.fixtureRequest())
                    lock.lock(); results.append(result); lock.unlock()
                } catch {
                    lock.lock(); failures.append(error); lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(results.filter(\.installed).count, 1)
        XCTAssertEqual(results.filter { !$0.installed }.count, 7)
        XCTAssertEqual(try installer(root).readInstalledVersion(capsuleId: "com.example.fixture", version: "1.0.0").version, "1.0.0")
    }

    func testFaultInjectionNeverLeavesPartialFinalVersionAndPreservesPriorVersion() throws {
        for point in CapsuleInstallFaultPoint.allCases {
            let root = try temporaryDirectory()
            let base = try installer(root)
            _ = try base.installBundled(archiveURL: fixture("android-e2e-v1"), request: e2eRequest())
            let failing = try CapsuleInstaller(storageRootURL: root, faultInjector: { current in
                if current == point { throw WebCapsuleError(code: .installFailed, message: "injected") }
            })
            assertError(.installFailed) {
                try failing.installBundled(archiveURL: self.fixture("android-e2e-v2"), request: self.e2eRequest())
            }
            XCTAssertEqual(try base.readInstalledVersion(capsuleId: "com.example.android.e2e", version: "1.0.0").version, "1.0.0")
            let final = versionURL(root, id: "com.example.android.e2e", version: "2.0.0")
            if point == .afterVersionPublish {
                XCTAssertEqual(try base.readInstalledVersion(capsuleId: "com.example.android.e2e", version: "2.0.0").version, "2.0.0")
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: final.path), "\(point)")
            }
        }
    }

    func testRejectsMissingFileSymlinkRootsUnsafeChildrenAndLockSymlink() throws {
        let parent = try temporaryDirectory()
        assertError(.unsafeStorageLayout) { try CapsuleInstaller(storageRootURL: parent.appendingPathComponent("missing")) }
        let file = parent.appendingPathComponent("file")
        try Data().write(to: file)
        assertError(.unsafeStorageLayout) { try CapsuleInstaller(storageRootURL: file) }
        let real = try temporaryDirectory()
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        assertError(.unsafeStorageLayout) { try CapsuleInstaller(storageRootURL: link) }

        let unsafe = try temporaryDirectory()
        let target = try temporaryDirectory()
        try FileManager.default.createSymbolicLink(at: unsafe.appendingPathComponent("blobs"), withDestinationURL: target)
        assertError(.unsafeStorageLayout) { try CapsuleInstaller(storageRootURL: unsafe) }

        let writableRoot = try temporaryDirectory()
        XCTAssertEqual(Darwin.chmod(writableRoot.path, 0o777), 0)
        assertError(.unsafeStorageLayout) { try CapsuleInstaller(storageRootURL: writableRoot) }

        let writableChildRoot = try temporaryDirectory()
        try FileManager.default.createDirectory(at: writableChildRoot.appendingPathComponent("blobs"), withIntermediateDirectories: false)
        XCTAssertEqual(Darwin.chmod(writableChildRoot.appendingPathComponent("blobs").path, 0o777), 0)
        assertError(.unsafeStorageLayout) { try CapsuleInstaller(storageRootURL: writableChildRoot) }

        let versionLinkRoot = try temporaryDirectory()
        let versionStore = try installer(versionLinkRoot)
        let capsuleDirectory = versionURL(versionLinkRoot, id: "com.example.fixture", version: "1.0.0")
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(at: capsuleDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: capsuleDirectory.appendingPathComponent(CapsuleStorage.encodeStorageKey("1.0.0")),
            withDestinationURL: target
        )
        assertError(.storageInvariantViolation) {
            try versionStore.installBundled(archiveURL: self.fixture("valid-minimal"), request: self.fixtureRequest())
        }

        let lockRoot = try temporaryDirectory()
        let store = try installer(lockRoot)
        let lockTarget = lockRoot.appendingPathComponent("target")
        try Data().write(to: lockTarget)
        try FileManager.default.createSymbolicLink(at: lockRoot.appendingPathComponent("locks/install.lock"), withDestinationURL: lockTarget)
        assertError(.lockFailed) {
            try store.installBundled(archiveURL: self.fixture("valid-minimal"), request: self.fixtureRequest())
        }
    }

    func testLogicalManifestPathsAreNeverPhysicalStoragePaths() throws {
        let root = try temporaryDirectory()
        _ = try installer(root).installBundled(archiveURL: fixture("android-e2e-v1"), request: e2eRequest())
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        let names = enumerator.compactMap { ($0 as? URL)?.lastPathComponent }
        for logical in ["app.js", "data.json", "index.html", "pixel.png", "style.css"] {
            XCTAssertFalse(names.contains(logical))
        }
    }

    private func installer(_ root: URL) throws -> CapsuleInstaller { try CapsuleInstaller(storageRootURL: root) }

    private func verify(root: URL) throws -> VerifiedCapsule {
        _ = try installer(root)
        return try CapsuleVerifier().verify(
            archiveURL: fixture("valid-minimal"),
            stagingRootURL: root.appendingPathComponent("staging"),
            request: fixtureRequest()
        )
    }

    private func fixtureRequest() -> CapsuleVerificationRequest {
        CapsuleVerificationRequest(expectedCapsuleId: "com.example.fixture", runtimeVersion: "1.0.0", publicKeys: ["test-only": try! publicKey()])
    }

    private func e2eRequest() -> CapsuleVerificationRequest {
        CapsuleVerificationRequest(expectedCapsuleId: "com.example.android.e2e", runtimeVersion: "1.0.0", publicKeys: ["test-only": try! publicKey()])
    }

    private func publicKey() throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent("fixtures/keys/test-only-public.pem"), encoding: .utf8)
    }

    private func fixture(_ name: String) -> URL {
        repositoryRoot.appendingPathComponent("fixtures/capsules/\(name).capsule")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("webcapsule-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }

    private func versionURL(_ root: URL, id: String, version: String) -> URL {
        root.appendingPathComponent("versions").appendingPathComponent(CapsuleStorage.encodeStorageKey(id))
            .appendingPathComponent(CapsuleStorage.encodeStorageKey(version))
    }

    private func blobURL(_ root: URL, _ digest: String) -> URL {
        root.appendingPathComponent("blobs/sha256").appendingPathComponent(String(digest.prefix(2))).appendingPathComponent(digest)
    }

    private func names(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func mode(_ url: URL) throws -> mode_t {
        var attributes = stat()
        guard Darwin.lstat(url.path, &attributes) == 0 else { throw CocoaError(.fileReadUnknown) }
        return attributes.st_mode & 0o777
    }

    private func regularFileCount(_ root: URL) throws -> Int {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        return try enumerator.reduce(into: 0) { count, item in
            if let url = item as? URL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { count += 1 }
        }
    }

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
