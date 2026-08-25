import Darwin
import Foundation
import XCTest
@testable import WebCapsuleCore

final class IOSRuntimeBootstrapTests: XCTestCase {
    private let capsuleId = "com.example.android.e2e"
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testFirstAndSecondStartupCommitBoundedAttemptsBeforePinnedSession() throws {
        let root = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(
            storageRootURL: root,
            registryFaultInjector: { _ in },
            monotonicClock: { 123 },
            sessionID: { "session-1" }
        )
        let first = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())
        XCTAssertEqual(first.sessionId, "session-1")
        XCTAssertEqual(first.version, "1.0.0")
        XCTAssertEqual(first.registryGeneration, 1)
        XCTAssertEqual(first.trialVersion, "1.0.0")
        XCTAssertEqual(first.trialAttempt, 1)
        XCTAssertEqual(first.createdMonotonicNanoseconds, 123)
        XCTAssertEqual(first.entry, "index.html")
        XCTAssertEqual(Set(first.files.keys), ["app.js", "data.json", "index.html", "pixel.png", "style.css"])

        let registryURL = self.registryURL(root)
        let expected = "{\"active\":{\"healthy\":false,\"version\":\"1.0.0\"},\"blockedVersions\":[],\"capsuleId\":\"com.example.android.e2e\",\"generation\":1,\"highestSeenVersion\":\"1.0.0\",\"pending\":{\"attempts\":1,\"version\":\"1.0.0\"},\"previous\":null,\"schemaVersion\":1}\n"
        XCTAssertEqual(try String(contentsOf: registryURL, encoding: .utf8), expected)
        XCTAssertEqual(try mode(registryURL), 0o600)
        first.releaseTrial()

        let restarted = try IOSRuntimeBootstrap(storageRootURL: root)
        let second = try restarted.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())
        XCTAssertEqual(second.version, "1.0.0")
        XCTAssertEqual(second.registryGeneration, 2)
        XCTAssertEqual(second.trialAttempt, 2)
        second.releaseTrial()
        XCTAssertFalse(registryURL.lastPathComponent.contains(capsuleId))
        XCTAssertEqual(registryURL.lastPathComponent, CapsuleStorage.encodeStorageKey(capsuleId) + ".json")
    }

    func testPendingTrialSessionIsProcessExclusiveUntilReleased() throws {
        let root = try temporaryDirectory()
        let firstRuntime = try IOSRuntimeBootstrap(storageRootURL: root)
        let first = try firstRuntime.start(
            bundledArchiveURL: fixture("android-e2e-v1"),
            request: request()
        )
        XCTAssertEqual(first.registryGeneration, 1)
        XCTAssertEqual(first.trialAttempt, 1)

        let secondRuntime = try IOSRuntimeBootstrap(storageRootURL: root)
        assertError(.trialSessionInProgress) {
            try secondRuntime.start(
                bundledArchiveURL: self.fixture("android-e2e-v1"),
                request: self.request()
            )
        }
        XCTAssertEqual(
            try secondRuntime.readRegistry(capsuleId: capsuleId)?.pending,
            PendingVersion(version: "1.0.0", attempts: 1)
        )

        first.releaseTrial()
        first.releaseTrial()
        let second = try secondRuntime.start(
            bundledArchiveURL: fixture("android-e2e-v1"),
            request: request()
        )
        XCTAssertEqual(second.registryGeneration, 2)
        XCTAssertEqual(second.trialAttempt, 2)
        second.releaseTrial()
    }

    func testRegistryCodecRejectsStrictAndSemanticFailures() throws {
        let valid = initialRegistry()
        let bytes = try RegistryCodec.serialize(valid)
        XCTAssertEqual(try RegistryCodec.parse(bytes, expectedCapsuleId: capsuleId), valid)
        let text = String(decoding: bytes, as: UTF8.self)
        let variants = [
            text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"unknown\":0,\"schemaVersion\":1"),
            text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1"),
            text.replacingOccurrences(of: "\"blockedVersions\":[],", with: ""),
            " " + text,
            String(text.dropLast()),
            text.replacingOccurrences(of: "\"generation\":0", with: "\"generation\":9007199254740992"),
            text.replacingOccurrences(of: "\"generation\":0", with: "\"generation\":\"0\""),
            text.replacingOccurrences(of: "\"healthy\":false", with: "\"healthy\":true"),
            text.replacingOccurrences(of: "\"version\":\"1.0.0\"},\"previous\":null", with: "\"version\":\"2.0.0\"},\"previous\":null"),
        ]
        for variant in variants {
            assertError(.registryInvalid) {
                try RegistryCodec.parse(Data(variant.utf8), expectedCapsuleId: self.capsuleId)
            }
        }

        let invalids = [
            registry(active: ActiveVersion(version: "1.0.0", healthy: false), previous: nil, pending: nil),
            registry(active: ActiveVersion(version: "1.0.0", healthy: true), previous: nil, pending: PendingVersion(version: "1.0.0", attempts: 0)),
            registry(active: ActiveVersion(version: "1.0.0", healthy: false), previous: PreviousVersion(version: "1.0.0"), pending: PendingVersion(version: "1.0.0", attempts: 0)),
            registry(active: ActiveVersion(version: "1.0.0", healthy: false), previous: nil, pending: PendingVersion(version: "1.0.0", attempts: 3)),
            registry(active: ActiveVersion(version: "1.0.0", healthy: false), previous: nil, pending: PendingVersion(version: "1.0.0", attempts: 0), highest: "0.9.0"),
            registry(active: ActiveVersion(version: "1.0.0", healthy: false), previous: nil, pending: PendingVersion(version: "1.0.0", attempts: 0), blocked: ["2.0.0", "2.0.0"]),
            registry(active: ActiveVersion(version: "1.0.0", healthy: false), previous: nil, pending: PendingVersion(version: "1.0.0", attempts: 0), highest: "3.0.0", blocked: ["2.0.0", "2.1.0"]),
        ]
        for invalid in invalids { assertError(.registryInvalid) { try RegistryCodec.serialize(invalid) } }
    }

    func testCorruptActiveReferenceRecoversOnlyFromTrustedBundled() throws {
        let root = try temporaryDirectory()
        let installer = try CapsuleInstaller(storageRootURL: root)
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v1"), request: request())
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v2"), request: request())
        try publish(
            registry(
                generation: 3,
                active: ActiveVersion(version: "2.0.0", healthy: true),
                previous: nil,
                pending: nil,
                highest: "2.0.0"
            ),
            root: root
        )
        let record = versionURL(root, version: "2.0.0").appendingPathComponent("record.json")
        XCTAssertEqual(Darwin.chmod(record.path, 0o644), 0)
        try FileHandle(forWritingTo: record).truncate(atOffset: 3)

        let recovered = try IOSRuntimeBootstrap(storageRootURL: root).start(
            bundledArchiveURL: fixture("android-e2e-v1"), request: request()
        )
        XCTAssertEqual(recovered.version, "1.0.0")
        XCTAssertEqual(recovered.registryGeneration, 1)
        XCTAssertEqual(recovered.trialAttempt, 1)
        recovered.releaseTrial()

        let brokenRoot = try temporaryDirectory()
        let broken = try IOSRuntimeBootstrap(storageRootURL: brokenRoot)
        _ = try broken.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())
        let brokenRecord = versionURL(brokenRoot, version: "1.0.0").appendingPathComponent("record.json")
        XCTAssertEqual(Darwin.chmod(brokenRecord.path, 0o644), 0)
        try FileHandle(forWritingTo: brokenRecord).truncate(atOffset: 3)
        assertError(.bundledCapsuleUnavailable) {
            try IOSRuntimeBootstrap(storageRootURL: brokenRoot).start(
                bundledArchiveURL: self.fixture("android-e2e-v1"), request: self.request()
            )
        }
    }

    func testCorruptActiveBlobAndInvalidPreviousForceBundledFreshRecovery() throws {
        let blobRoot = try temporaryDirectory()
        let blobInstaller = try CapsuleInstaller(storageRootURL: blobRoot)
        let v1 = try blobInstaller.installBundled(archiveURL: fixture("android-e2e-v1"), request: request()).record
        let v2 = try blobInstaller.installBundled(archiveURL: fixture("android-e2e-v2"), request: request()).record
        try publish(
            registry(
                generation: 6,
                active: ActiveVersion(version: "2.0.0", healthy: true),
                previous: PreviousVersion(version: "1.0.0"),
                pending: nil,
                highest: "2.0.0"
            ),
            root: blobRoot
        )
        let v1Hashes = Set(v1.files.map(\.sha256))
        let uniqueV2Hash = try XCTUnwrap(v2.files.first(where: { !v1Hashes.contains($0.sha256) })?.sha256)
        let blob = blobRoot.appendingPathComponent("blobs/sha256")
            .appendingPathComponent(String(uniqueV2Hash.prefix(2)))
            .appendingPathComponent(uniqueV2Hash)
        XCTAssertEqual(Darwin.chmod(blob.path, 0o644), 0)
        var corrupt = try Data(contentsOf: blob)
        corrupt[corrupt.startIndex] ^= 0xFF
        try corrupt.write(to: blob)
        let blobRecovered = try IOSRuntimeBootstrap(storageRootURL: blobRoot).start(
            bundledArchiveURL: fixture("android-e2e-v1"), request: request()
        )
        XCTAssertEqual(blobRecovered.version, "1.0.0")
        XCTAssertEqual(blobRecovered.registryGeneration, 1)
        blobRecovered.releaseTrial()

        let previousRoot = try temporaryDirectory()
        let previousInstaller = try CapsuleInstaller(storageRootURL: previousRoot)
        _ = try previousInstaller.installBundled(archiveURL: fixture("android-e2e-v1"), request: request())
        _ = try previousInstaller.installBundled(archiveURL: fixture("android-e2e-v2"), request: request())
        try publish(
            registry(
                generation: 9,
                active: ActiveVersion(version: "1.0.0", healthy: true),
                previous: PreviousVersion(version: "2.0.0"),
                pending: nil,
                highest: "2.0.0"
            ),
            root: previousRoot
        )
        let previousRecord = versionURL(previousRoot, version: "2.0.0").appendingPathComponent("record.json")
        XCTAssertEqual(Darwin.chmod(previousRecord.path, 0o644), 0)
        try FileHandle(forWritingTo: previousRecord).truncate(atOffset: 3)
        let previousRecovered = try IOSRuntimeBootstrap(storageRootURL: previousRoot).start(
            bundledArchiveURL: fixture("android-e2e-v1"), request: request()
        )
        XCTAssertEqual(previousRecovered.version, "1.0.0")
        XCTAssertEqual(previousRecovered.registryGeneration, 1)
        previousRecovered.releaseTrial()
        let fresh = try XCTUnwrap(IOSRuntimeBootstrap(storageRootURL: previousRoot).readRegistry(capsuleId: capsuleId))
        XCTAssertNil(fresh.previous)
        XCTAssertFalse(fresh.active.healthy)
        XCTAssertEqual(fresh.pending, PendingVersion(version: "1.0.0", attempts: 1))
    }

    func testExhaustedPendingRecoversPreviousOrBundledAndNeverRetriesSameBundled() throws {
        let previousRoot = try temporaryDirectory()
        let installer = try CapsuleInstaller(storageRootURL: previousRoot)
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v1"), request: request())
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v2"), request: request())
        let runtime = try IOSRuntimeBootstrap(storageRootURL: previousRoot)
        try publish(
            registry(
                generation: 4,
                active: ActiveVersion(version: "2.0.0", healthy: false),
                previous: PreviousVersion(version: "1.0.0"),
                pending: PendingVersion(version: "2.0.0", attempts: 2),
                highest: "2.0.0"
            ),
            root: previousRoot
        )
        let rolled = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())
        XCTAssertEqual(rolled.version, "1.0.0")
        XCTAssertEqual(rolled.registryGeneration, 5)
        let rolledRegistry = try XCTUnwrap(runtime.readRegistry(capsuleId: capsuleId))
        XCTAssertTrue(rolledRegistry.active.healthy)
        XCTAssertNil(rolledRegistry.previous)
        XCTAssertNil(rolledRegistry.pending)
        XCTAssertEqual(rolledRegistry.blockedVersions, ["2.0.0"])

        let terminalRoot = try temporaryDirectory()
        let terminal = try IOSRuntimeBootstrap(storageRootURL: terminalRoot)
        _ = try terminal.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())
        try publish(
            registry(
                generation: 2,
                active: ActiveVersion(version: "1.0.0", healthy: false),
                previous: nil,
                pending: PendingVersion(version: "1.0.0", attempts: 2)
            ),
            root: terminalRoot
        )
        assertError(.noRunnableVersion) {
            try terminal.start(bundledArchiveURL: self.fixture("android-e2e-v1"), request: self.request())
        }
    }

    func testSessionRemainsPinnedAcrossAtomicActiveTransition() throws {
        let root = try temporaryDirectory()
        let installer = try CapsuleInstaller(storageRootURL: root)
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v1"), request: request())
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v2"), request: request())
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        try publish(
            registry(
                active: ActiveVersion(version: "1.0.0", healthy: true),
                previous: nil,
                pending: nil
            ),
            root: root
        )
        let oldSession = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())
        let oldRegistry = try XCTUnwrap(runtime.readRegistry(capsuleId: capsuleId))
        _ = try runtime.compareAndSwap(capsuleId: capsuleId, expectedGeneration: oldRegistry.generation) { current in
            self.registry(
                generation: current.generation + 1,
                active: ActiveVersion(version: "2.0.0", healthy: false),
                previous: PreviousVersion(version: "1.0.0"),
                pending: PendingVersion(version: "2.0.0", attempts: 0),
                highest: "2.0.0"
            )
        }
        let newSession = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())
        XCTAssertEqual(oldSession.version, "1.0.0")
        XCTAssertEqual(oldSession.registryGeneration, 0)
        XCTAssertEqual(newSession.version, "2.0.0")
        XCTAssertEqual(newSession.registryGeneration, 2)
        XCTAssertEqual(newSession.trialAttempt, 1)
        XCTAssertNotEqual(oldSession.recordSHA256, newSession.recordSHA256)
        newSession.releaseTrial()
    }

    func testGenerationCASAllowsExactlyOneConcurrentWriter() throws {
        let root = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        let selected = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())
        selected.releaseTrial()
        let queue = DispatchQueue(label: "registry-cas", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var successes = 0
        var errors: [WebCapsuleErrorCode] = []
        for _ in 0..<8 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    _ = try runtime.compareAndSwap(capsuleId: self.capsuleId, expectedGeneration: 1) { current in
                        self.registry(
                            generation: current.generation + 1,
                            active: ActiveVersion(version: "1.0.0", healthy: true),
                            previous: nil,
                            pending: nil
                        )
                    }
                    lock.lock(); successes += 1; lock.unlock()
                } catch {
                    lock.lock(); errors.append((error as? WebCapsuleError)?.code ?? .storageIOFailed); lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(errors, Array(repeating: .updateStateChanged, count: 7))
        XCTAssertEqual(try runtime.readRegistry(capsuleId: capsuleId)?.generation, 2)
    }

    func testRegistryWriteFaultsLeaveOldOrCompleteNewState() throws {
        for point in RegistryWriteFaultPoint.allCases {
            let root = try temporaryDirectory()
            let base = try IOSRuntimeBootstrap(storageRootURL: root)
            let selected = try base.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())
            selected.releaseTrial()
            let failing = try IOSRuntimeBootstrap(storageRootURL: root, registryFaultInjector: { current in
                if current == point { throw WebCapsuleError(code: .storageIOFailed, message: "injected") }
            })
            assertError(.storageIOFailed) {
                try failing.compareAndSwap(capsuleId: self.capsuleId, expectedGeneration: 1) { current in
                    self.registry(
                        generation: current.generation + 1,
                        active: ActiveVersion(version: "1.0.0", healthy: true),
                        previous: nil,
                        pending: nil
                    )
                }
            }
            let parsed = try XCTUnwrap(try RegistryCodec.parse(Data(contentsOf: registryURL(root)), expectedCapsuleId: capsuleId))
            XCTAssertTrue(parsed.generation == 1 || parsed.generation == 2)
            XCTAssertEqual(try mode(registryURL(root)), 0o600)
        }
    }

    func testRegistryDestinationAndTempsRejectUnsafeCollisionsWithoutOverwrite() throws {
        for kind in 0..<3 {
            let root = try temporaryDirectory()
            let registries = root.appendingPathComponent("registries")
            try FileManager.default.createDirectory(at: registries, withIntermediateDirectories: false)
            let destination = registryURL(root)
            let target = root.appendingPathComponent("target")
            try Data("keep".utf8).write(to: target)
            if kind == 0 {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
            } else if kind == 1 {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            } else {
                try Data("keep".utf8).write(to: destination)
                XCTAssertEqual(Darwin.chmod(destination.path, 0o644), 0)
            }
            assertError(.registryRecoveryFailed) {
                try IOSRuntimeBootstrap(storageRootURL: root).start(
                    bundledArchiveURL: self.fixture("android-e2e-v1"), request: self.request()
                )
            }
            XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        }

        let tempRoot = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(storageRootURL: tempRoot)
        _ = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())
        let unsafe = tempRoot.appendingPathComponent("registries/.registry-\(CapsuleStorage.encodeStorageKey(capsuleId))-not-a-uuid.tmp")
        try Data("keep".utf8).write(to: unsafe)
        assertError(.unsafeStorageLayout) {
            try runtime.start(bundledArchiveURL: self.fixture("android-e2e-v1"), request: self.request())
        }
        XCTAssertEqual(try Data(contentsOf: unsafe), Data("keep".utf8))
    }

    func testValidActiveDoesNotReadInvalidBundledAndStartupCleansOnlyOwnedStaging() throws {
        let root = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        _ = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())

        let staleName = UUID().uuidString.lowercased()
        let stale = root.appendingPathComponent("staging/\(staleName)")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        let owner = stale.appendingPathComponent(".capsule-owner")
        try Data((CapsuleStorage.encodeStorageKey(capsuleId) + "\n").utf8).write(to: owner)
        XCTAssertEqual(Darwin.chmod(owner.path, 0o600), 0)
        let partial = stale.appendingPathComponent("00000000.blob")
        try Data("partial".utf8).write(to: partial)
        XCTAssertEqual(Darwin.chmod(partial.path, 0o600), 0)
        let selected = try IOSRuntimeBootstrap(storageRootURL: root).start(
            bundledArchiveURL: fixture("invalid-signature"),
            request: request()
        )
        XCTAssertEqual(selected.version, "1.0.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))

        let unexpected = root.appendingPathComponent("staging/caller-owned")
        try Data("keep".utf8).write(to: unexpected)
        assertError(.unsafeStorageLayout) {
            try IOSRuntimeBootstrap(storageRootURL: root).start(
                bundledArchiveURL: self.fixture("android-e2e-v1"), request: self.request()
            )
        }
        XCTAssertEqual(try Data(contentsOf: unexpected), Data("keep".utf8))
    }

    func testMissingRegistryWithUnsafeStagingFailsWithoutBundledRecovery() throws {
        let root = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        let unexpected = root.appendingPathComponent("staging/caller-owned")
        try Data("keep".utf8).write(to: unexpected)

        assertError(.unsafeStorageLayout) {
            try runtime.start(bundledArchiveURL: self.fixture("android-e2e-v1"), request: self.request())
        }
        XCTAssertEqual(try Data(contentsOf: unexpected), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryURL(root).path))
    }

    func testStartupDoesNotDeleteAnotherCapsulesOwnedStagingOperation() throws {
        let root = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        _ = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())

        let operation = root.appendingPathComponent("staging/\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: false)
        let owner = operation.appendingPathComponent(".capsule-owner")
        try Data((CapsuleStorage.encodeStorageKey("com.example.other") + "\n").utf8).write(to: owner)
        XCTAssertEqual(Darwin.chmod(owner.path, 0o600), 0)
        let partial = operation.appendingPathComponent("00000000.blob")
        try Data("in-progress".utf8).write(to: partial)
        XCTAssertEqual(Darwin.chmod(partial.path, 0o600), 0)

        XCTAssertEqual(
            try runtime.start(bundledArchiveURL: fixture("invalid-signature"), request: request()).version,
            "1.0.0"
        )
        XCTAssertEqual(try Data(contentsOf: partial), Data("in-progress".utf8))
    }

    func testExhaustedPendingWithoutPreviousUsesDifferentBundledFallback() throws {
        let root = try temporaryDirectory()
        let installer = try CapsuleInstaller(storageRootURL: root)
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v2"), request: request())
        try publish(
            registry(
                generation: 7,
                active: ActiveVersion(version: "2.0.0", healthy: false),
                previous: nil,
                pending: PendingVersion(version: "2.0.0", attempts: 2),
                highest: "2.0.0"
            ),
            root: root
        )

        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        let selected = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: request())
        XCTAssertEqual(selected.version, "1.0.0")
        XCTAssertEqual(selected.registryGeneration, 9)
        XCTAssertEqual(selected.trialAttempt, 1)
        selected.releaseTrial()
        let registry = try XCTUnwrap(runtime.readRegistry(capsuleId: capsuleId))
        XCTAssertEqual(registry.active, ActiveVersion(version: "1.0.0", healthy: false))
        XCTAssertEqual(registry.pending, PendingVersion(version: "1.0.0", attempts: 1))
        XCTAssertEqual(registry.blockedVersions, ["2.0.0"])
        XCTAssertEqual(registry.highestSeenVersion, "2.0.0")
    }

    func testIncompleteVersionAndOrphanBlobAreNeverSelected() throws {
        let root = try temporaryDirectory()
        _ = try IOSRuntimeBootstrap(storageRootURL: root).start(
            bundledArchiveURL: fixture("android-e2e-v1"), request: request()
        )
        let incomplete = versionURL(root, version: "9.0.0")
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        let orphan = root.appendingPathComponent("blobs/sha256/aa/" + String(repeating: "a", count: 64))
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan)
        XCTAssertEqual(
            try IOSRuntimeBootstrap(storageRootURL: root).start(
                bundledArchiveURL: fixture("android-e2e-v1"), request: request()
            ).version,
            "1.0.0"
        )
    }

    func testSecuritySensitivePublicValuesHaveNoPublicInitializer() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(SessionDescriptor.self)
        requireSendable(CapsuleRegistry.self)
        requireSendable(SessionFile.self)
        XCTAssertEqual(String(describing: SessionDescriptor.self), "SessionDescriptor")
    }

    private func initialRegistry() -> CapsuleRegistry {
        registry(
            active: ActiveVersion(version: "1.0.0", healthy: false),
            previous: nil,
            pending: PendingVersion(version: "1.0.0", attempts: 0)
        )
    }

    private func registry(
        generation: Int64 = 0,
        active: ActiveVersion,
        previous: PreviousVersion?,
        pending: PendingVersion?,
        highest: String = "1.0.0",
        blocked: [String] = []
    ) -> CapsuleRegistry {
        CapsuleRegistry(
            schemaVersion: 1,
            capsuleId: capsuleId,
            generation: generation,
            active: active,
            previous: previous,
            pending: pending,
            highestSeenVersion: highest,
            blockedVersions: blocked
        )
    }

    private func publish(_ registry: CapsuleRegistry, root: URL) throws {
        let registries = root.appendingPathComponent("registries")
        try FileManager.default.createDirectory(at: registries, withIntermediateDirectories: true)
        let destination = registryURL(root)
        try RegistryCodec.serialize(registry).write(to: destination)
        XCTAssertEqual(Darwin.chmod(destination.path, 0o600), 0)
    }

    private func request() -> CapsuleVerificationRequest {
        CapsuleVerificationRequest(
            expectedCapsuleId: capsuleId,
            runtimeVersion: "1.0.0",
            publicKeys: ["test-only": try! publicKey()]
        )
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("webcapsule-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }

    private func registryURL(_ root: URL) -> URL {
        root.appendingPathComponent("registries").appendingPathComponent(CapsuleStorage.encodeStorageKey(capsuleId) + ".json")
    }

    private func versionURL(_ root: URL, version: String) -> URL {
        root.appendingPathComponent("versions")
            .appendingPathComponent(CapsuleStorage.encodeStorageKey(capsuleId))
            .appendingPathComponent(CapsuleStorage.encodeStorageKey(version))
    }

    private func mode(_ url: URL) throws -> mode_t {
        var attributes = stat()
        guard Darwin.lstat(url.path, &attributes) == 0 else { throw CocoaError(.fileReadUnknown) }
        return attributes.st_mode & 0o777
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
