import CryptoKit
import Foundation
import XCTest
@testable import WebCapsuleCore

final class IOSUpdateTests: XCTestCase {
    private let capsuleId = "com.example.android.e2e"
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testSharedSignedIndexFixturesMatchAndroidContract() throws {
        let contract = try JSONSerialization.jsonObject(
            with: Data(contentsOf: repositoryRoot.appendingPathComponent("fixtures/expected-results.json"))
        ) as! [String: Any]
        let fixtures = (contract["fixtures"] as! [[String: Any]]).filter {
            $0["kind"] as? String == "signed-update-index"
        }
        XCTAssertEqual(fixtures.count, 14)
        let publicKey = try self.publicKey()
        for fixture in fixtures {
            let verification = fixture["verification"] as! [String: Any]
            let accepted = fixture["accepted"] as! Bool
            do {
                _ = try UpdateIndexVerifier.verify(
                    Data(contentsOf: repositoryRoot.appendingPathComponent("fixtures").appendingPathComponent(fixture["path"] as! String)),
                    expectedCapsuleId: verification["expectedCapsuleId"] as! String,
                    expectedChannel: verification["expectedChannel"] as! String,
                    publicKeys: ["test-only": publicKey]
                )
                XCTAssertTrue(accepted, "\(fixture["id"]!) should fail")
            } catch let error as WebCapsuleError {
                XCTAssertFalse(accepted, "\(fixture["id"]!) failed with \(error)")
                XCTAssertEqual(error.code.rawValue, fixture["errorCode"] as? String, "\(fixture["id"]!)")
            }
        }
    }

    func testIndexSelectionAndStrictHTTPSContract() throws {
        let index = try UpdateIndexVerifier.verify(
            Data(contentsOf: fixtureRoot.appendingPathComponent("update-index-v1/valid-signed.json")),
            expectedCapsuleId: capsuleId,
            expectedChannel: "stable",
            publicKeys: ["test-only": try publicKey()]
        )
        XCTAssertEqual(
            try UpdateIndexVerifier.select(
                index,
                runtimeVersion: "1.0.0",
                highestSeenVersion: "1.0.0",
                blockedVersions: []
            )?.version,
            "2.0.0"
        )
        XCTAssertNil(try UpdateIndexVerifier.select(
            index,
            runtimeVersion: "1.0.0",
            highestSeenVersion: "2.0.0",
            blockedVersions: []
        ))
        for value in [
            "http://example.com/index.json",
            "https://user@example.com/index.json",
            "https://example.com:443/index.json",
            "https://example.com:/index.json",
            "https://[::1]:/index.json",
            "https://example.com/index.json#fragment",
            "/index.json",
        ] {
            assertError(.invalidURL) { try UpdateIndexVerifier.strictHTTPS(value) }
        }
    }

    func testInstallsVerifiedReleaseAndAtomicallyRegistersPendingState() throws {
        let root = try temporaryDirectory()
        try prepareHealthyV1(root)
        let updateRoot = try temporaryDirectory()
        let transport = FakeUpdateTransport(
            index: try Data(contentsOf: fixtureRoot.appendingPathComponent("update-index-v1/valid-signed.json")),
            capsule: fixtureRoot.appendingPathComponent("capsules/android-e2e-v2.capsule")
        )
        let result = try coordinator(root: root, updateRoot: updateRoot, transport: transport).install(request())
        XCTAssertEqual(
            result,
            .installed(
                previousVersion: "1.0.0",
                currentVersion: "2.0.0",
                highestSeenVersion: "2.0.0",
                generation: 2
            )
        )
        let registry = try XCTUnwrap(try IOSRuntimeBootstrap(storageRootURL: root).readRegistry(capsuleId: capsuleId))
        XCTAssertEqual(registry.active, ActiveVersion(version: "2.0.0", healthy: false))
        XCTAssertEqual(registry.previous, PreviousVersion(version: "1.0.0"))
        XCTAssertEqual(registry.pending, PendingVersion(version: "2.0.0", attempts: 0))
        XCTAssertTrue(try updateOperations(in: updateRoot).isEmpty)
    }

    func testUpToDateDoesNotFetchCapsuleOrMutateRegistry() throws {
        let root = try temporaryDirectory()
        try prepareHealthyV1(root, highestSeenVersion: "2.0.0")
        let registryURL = self.registryURL(root)
        let before = try Data(contentsOf: registryURL)
        let transport = FakeUpdateTransport(
            index: try Data(contentsOf: fixtureRoot.appendingPathComponent("update-index-v1/valid-signed.json")),
            capsule: fixtureRoot.appendingPathComponent("capsules/android-e2e-v2.capsule")
        )
        let result = try coordinator(root: root, updateRoot: try temporaryDirectory(), transport: transport).install(request())
        XCTAssertEqual(result, .upToDate(currentVersion: "1.0.0", highestSeenVersion: "2.0.0", generation: 1))
        XCTAssertEqual(transport.capsuleFetches, 0)
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }

    func testStateRecoveryDoesNotStartTrialOrIncreaseAttempts() throws {
        let root = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        let session = try runtime.start(bundledArchiveURL: v1, request: verificationRequest())
        XCTAssertEqual(session.trialAttempt, 1)
        session.releaseTrial()

        let state = try runtime.ensureState(bundledArchiveURL: v1, request: verificationRequest())
        XCTAssertEqual(state.generation, 1)
        XCTAssertEqual(state.pending, PendingVersion(version: "1.0.0", attempts: 1))
        let second = try runtime.ensureState(bundledArchiveURL: v1, request: verificationRequest())
        XCTAssertEqual(second, state)
    }

    func testStateChangeRejectsCommitAndCleansDownloadedAndVerifierTemps() throws {
        let root = try temporaryDirectory()
        try prepareHealthyV1(root)
        let updateRoot = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        let transport = FakeUpdateTransport(
            index: try Data(contentsOf: fixtureRoot.appendingPathComponent("update-index-v1/valid-signed.json")),
            capsule: fixtureRoot.appendingPathComponent("capsules/android-e2e-v2.capsule")
        )
        let coordinator = IOSUpdateCoordinator(
            storageRootURL: root,
            trustedCacheBaseURL: updateRoot,
            transport: transport,
            beforeCommit: {
                _ = try! runtime.compareAndSwap(capsuleId: self.capsuleId, expectedGeneration: 1) { current in
                    CapsuleRegistry(
                        schemaVersion: 1,
                        capsuleId: current.capsuleId,
                        generation: 2,
                        active: current.active,
                        previous: current.previous,
                        pending: current.pending,
                        highestSeenVersion: current.highestSeenVersion,
                        blockedVersions: current.blockedVersions
                    )
                }
            }
        )
        assertError(.updateStateChanged) { try coordinator.install(self.request()) }
        XCTAssertEqual(try runtime.readRegistry(capsuleId: capsuleId)?.generation, 2)
        XCTAssertTrue(try updateOperations(in: updateRoot).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).isEmpty)
    }

    func testSameCapsuleConcurrentUpdateFailsImmediately() throws {
        let root = try temporaryDirectory()
        try prepareHealthyV1(root)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let transport = FakeUpdateTransport(
            index: try Data(contentsOf: fixtureRoot.appendingPathComponent("update-index-v1/valid-signed.json")),
            capsule: fixtureRoot.appendingPathComponent("capsules/android-e2e-v2.capsule"),
            entered: entered,
            release: release
        )
        let first = coordinator(root: root, updateRoot: try temporaryDirectory(), transport: transport)
        let finished = expectation(description: "first update")
        var firstError: Error?
        DispatchQueue.global().async {
            do { _ = try first.install(self.request()) } catch { firstError = error }
            finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let second = coordinator(
            root: root,
            updateRoot: try temporaryDirectory(),
            transport: FakeUpdateTransport(index: transport.index, capsule: transport.capsule)
        )
        assertError(.updateInProgress) { try second.install(self.request()) }
        release.signal()
        wait(for: [finished], timeout: 10)
        XCTAssertNil(firstError)
    }

    func testDescriptorFailureCleansTemporaryDirectoryAndPreservesRegistry() throws {
        let root = try temporaryDirectory()
        try prepareHealthyV1(root)
        let updateRoot = try temporaryDirectory()
        let before = try Data(contentsOf: registryURL(root))
        let transport = FakeUpdateTransport(
            index: try Data(contentsOf: fixtureRoot.appendingPathComponent("update-index-v1/valid-signed.json")),
            capsule: fixtureRoot.appendingPathComponent("capsules/signature-mismatch.capsule")
        )
        assertError(.idMismatch) {
            try self.coordinator(root: root, updateRoot: updateRoot, transport: transport).install(self.request())
        }
        XCTAssertEqual(try Data(contentsOf: registryURL(root)), before)
        XCTAssertTrue(try updateOperations(in: updateRoot).isEmpty)
    }

    private func coordinator(
        root: URL,
        updateRoot: URL,
        transport: FakeUpdateTransport
    ) -> IOSUpdateCoordinator {
        IOSUpdateCoordinator(storageRootURL: root, trustedCacheBaseURL: updateRoot, transport: transport)
    }

    private func request() -> IOSUpdateRequest {
        IOSUpdateRequest(
            config: WebCapsuleConfig(
                capsuleId: capsuleId,
                bundledAssetPath: "webcapsule/v1.capsule",
                publicKeys: ["test-only": try! publicKey()],
                runtimeVersion: "1.0.0"
            ),
            bundledArchiveURL: v1,
            indexURL: URL(string: "https://example.com/index.json")!,
            channel: "stable"
        )
    }

    private func prepareHealthyV1(_ root: URL, highestSeenVersion: String = "1.0.0") throws {
        _ = try CapsuleInstaller(storageRootURL: root).installBundled(
            archiveURL: v1,
            request: verificationRequest()
        )
        let registry = CapsuleRegistry(
            schemaVersion: 1,
            capsuleId: capsuleId,
            generation: 1,
            active: ActiveVersion(version: "1.0.0", healthy: true),
            previous: nil,
            pending: nil,
            highestSeenVersion: highestSeenVersion,
            blockedVersions: []
        )
        let storage = try CapsuleStorage(rootURL: root)
        try storage.withExclusiveLock(capsuleId: capsuleId) {
            try storage.replaceRegistry(capsuleId: capsuleId, bytes: RegistryCodec.serialize(registry))
        }
    }

    private func verificationRequest() -> CapsuleVerificationRequest {
        CapsuleVerificationRequest(
            expectedCapsuleId: capsuleId,
            runtimeVersion: "1.0.0",
            publicKeys: ["test-only": try! publicKey()]
        )
    }

    private var v1: URL { fixtureRoot.appendingPathComponent("capsules/android-e2e-v1.capsule") }
    private var fixtureRoot: URL { repositoryRoot.appendingPathComponent("fixtures") }
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func publicKey() throws -> String {
        try String(contentsOf: fixtureRoot.appendingPathComponent("keys/test-only-public.pem"), encoding: .utf8)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("webcapsule-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }

    private func updateOperations(in base: URL) throws -> [String] {
        let root = base.appendingPathComponent("webcapsule-update/v1", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
    }

    private func registryURL(_ root: URL) -> URL {
        root.appendingPathComponent("registries/\(CapsuleStorage.encodeStorageKey(capsuleId)).json")
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

private final class FakeUpdateTransport: UpdateTransport, @unchecked Sendable {
    let index: Data
    let capsule: URL
    private let entered: DispatchSemaphore?
    private let release: DispatchSemaphore?
    private let lock = NSLock()
    private(set) var capsuleFetches = 0

    init(
        index: Data,
        capsule: URL,
        entered: DispatchSemaphore? = nil,
        release: DispatchSemaphore? = nil
    ) {
        self.index = index
        self.capsule = capsule
        self.entered = entered
        self.release = release
    }

    func fetchIndex(_ url: URL) throws -> Data {
        entered?.signal()
        if let release { _ = release.wait(timeout: .now() + 5) }
        return index
    }

    func fetchCapsule(_ release: UpdateRelease, trustedCacheBaseURL: URL) throws -> DownloadedCapsule {
        lock.lock(); capsuleFetches += 1; lock.unlock()
        let root = trustedCacheBaseURL.appendingPathComponent("webcapsule-update/v1", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let operation = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: false)
        let target = operation.appendingPathComponent("download.capsule")
        try FileManager.default.copyItem(at: capsule, to: target)
        return DownloadedCapsule(
            fileURL: target,
            operationDirectoryURL: operation,
            cleanupAction: { try? FileManager.default.removeItem(at: operation) }
        )
    }
}
