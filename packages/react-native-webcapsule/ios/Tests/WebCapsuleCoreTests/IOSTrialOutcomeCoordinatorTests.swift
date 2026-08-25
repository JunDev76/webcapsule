import Darwin
import Foundation
import XCTest
@testable import WebCapsuleCore

final class IOSTrialOutcomeCoordinatorTests: XCTestCase {
    private let capsuleId = "com.example.android.e2e"
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.reversed().forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testFirstFailureLeavesAttemptCommittedAndDuplicateIsIdempotent() throws {
        let root = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        let selected = try runtime.start(
            bundledArchiveURL: fixture("android-e2e-v1"),
            request: request()
        )
        let outcomes = try coordinator(root: root, bundled: "android-e2e-v1")
        let first = try outcomes.recordExplicitFailure(selected)
        let second = try outcomes.recordExplicitFailure(selected)
        XCTAssertEqual(first, second)
        guard case let .pending(registry) = first else {
            return XCTFail("First failure must remain pending")
        }
        XCTAssertEqual(registry.generation, 1)
        XCTAssertEqual(registry.pending, PendingVersion(version: "1.0.0", attempts: 1))
        XCTAssertEqual(try runtime.readRegistry(capsuleId: capsuleId), registry)
        XCTAssertNil(IOSTrialOutcomeCoordinator.rollbackEvent(
            session: selected,
            outcome: first,
            reason: .readyTimeout
        ))
    }

    func testHealthyCommitRequiresExactSessionAndPreservesPrevious() throws {
        let root = try temporaryDirectory()
        let installer = try CapsuleInstaller(storageRootURL: root)
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v1"), request: request())
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v2"), request: request())
        try publish(registry(
            generation: 4,
            active: ActiveVersion(version: "2.0.0", healthy: false),
            previous: PreviousVersion(version: "1.0.0"),
            pending: PendingVersion(version: "2.0.0", attempts: 0),
            highest: "2.0.0"
        ), root: root)
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        let selected = try runtime.start(
            bundledArchiveURL: fixture("android-e2e-v1"),
            request: request()
        )
        XCTAssertEqual(selected.registryGeneration, 5)
        let outcomes = try coordinator(root: root, bundled: "android-e2e-v1")
        guard case let .healthy(committed) = try outcomes.commitHealthy(selected) else {
            return XCTFail("Expected healthy commit")
        }
        XCTAssertEqual(committed.generation, 6)
        XCTAssertEqual(committed.active, ActiveVersion(version: "2.0.0", healthy: true))
        XCTAssertEqual(committed.previous, PreviousVersion(version: "1.0.0"))
        XCTAssertNil(committed.pending)
        assertError(.sessionMismatch) { try outcomes.commitHealthy(selected) }
    }

    func testSecondFailureAtomicallyRollsBackCompletePreviousAndEmitsExactPayload() throws {
        let root = try temporaryDirectory()
        let installer = try CapsuleInstaller(storageRootURL: root)
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v1"), request: request())
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v2"), request: request())
        try publish(registry(
            generation: 8,
            active: ActiveVersion(version: "2.0.0", healthy: false),
            previous: PreviousVersion(version: "1.0.0"),
            pending: PendingVersion(version: "2.0.0", attempts: 1),
            highest: "2.0.0"
        ), root: root)
        let selected = try IOSRuntimeBootstrap(storageRootURL: root).start(
            bundledArchiveURL: fixture("android-e2e-v1"),
            request: request()
        )
        XCTAssertEqual(selected.trialAttempt, 2)
        XCTAssertEqual(selected.registryGeneration, 9)
        let outcomes = try coordinator(root: root, bundled: "android-e2e-v1")
        let outcome = try outcomes.recordExplicitFailure(selected)
        guard case let .rolledBack(registry, failed, restored) = outcome else {
            return XCTFail("Expected rollback")
        }
        XCTAssertEqual(failed, "2.0.0")
        XCTAssertEqual(restored, "1.0.0")
        XCTAssertEqual(registry.generation, 10)
        XCTAssertEqual(registry.active, ActiveVersion(version: "1.0.0", healthy: true))
        XCTAssertNil(registry.previous)
        XCTAssertNil(registry.pending)
        XCTAssertEqual(registry.blockedVersions, ["2.0.0"])
        XCTAssertEqual(IOSTrialOutcomeCoordinator.rollbackEvent(
            session: selected,
            outcome: outcome,
            reason: .stabilizationFailed
        ), IOSRollbackEvent(
            capsuleId: capsuleId,
            failedVersion: "2.0.0",
            restoredVersion: "1.0.0",
            reason: "STABILIZATION_FAILED",
            generation: "10"
        ))
        XCTAssertEqual(try outcomes.recordExplicitFailure(selected), outcome)
    }

    func testMissingPreviousUsesDifferentTrustedBundledAsUnhealthyFallback() throws {
        let root = try temporaryDirectory()
        let installer = try CapsuleInstaller(storageRootURL: root)
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v2"), request: request())
        let exhausted = registry(
            generation: 12,
            active: ActiveVersion(version: "2.0.0", healthy: false),
            previous: PreviousVersion(version: "9.0.0"),
            pending: PendingVersion(version: "2.0.0", attempts: 2),
            highest: "9.0.0"
        )
        try publish(exhausted, root: root)
        let selected = session(registry: exhausted)
        let outcome = try coordinator(root: root, bundled: "android-e2e-v1")
            .recordExplicitFailure(selected)
        guard case let .bundledFallback(next, failed, bundled) = outcome else {
            return XCTFail("Expected bundled fallback")
        }
        XCTAssertEqual(failed, "2.0.0")
        XCTAssertEqual(bundled, "1.0.0")
        XCTAssertEqual(next.generation, 13)
        XCTAssertEqual(next.active, ActiveVersion(version: "1.0.0", healthy: false))
        XCTAssertEqual(next.pending, PendingVersion(version: "1.0.0", attempts: 0))
        XCTAssertNil(next.previous)
        XCTAssertEqual(next.blockedVersions, ["2.0.0"])
        XCTAssertEqual(next.highestSeenVersion, "9.0.0")
    }

    func testSameExhaustedBundledIsTerminalAndInvalidFallbackHasStableError() throws {
        let terminalRoot = try temporaryDirectory()
        let installer = try CapsuleInstaller(storageRootURL: terminalRoot)
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v1"), request: request())
        let exhausted = registry(
            generation: 2,
            active: ActiveVersion(version: "1.0.0", healthy: false),
            previous: nil,
            pending: PendingVersion(version: "1.0.0", attempts: 2),
            highest: "1.0.0"
        )
        try publish(exhausted, root: terminalRoot)
        let selected = session(registry: exhausted)
        let outcome = try coordinator(root: terminalRoot, bundled: "android-e2e-v1")
            .recordExplicitFailure(selected)
        XCTAssertEqual(outcome, .terminal(failedVersion: "1.0.0"))
        XCTAssertEqual(try IOSRuntimeBootstrap(storageRootURL: terminalRoot).readRegistry(capsuleId: capsuleId), exhausted)
        XCTAssertEqual(IOSTrialOutcomeCoordinator.rollbackEvent(
            session: selected,
            outcome: outcome,
            reason: .readyTimeout
        ), IOSRollbackEvent(
            capsuleId: capsuleId,
            failedVersion: "1.0.0",
            restoredVersion: nil,
            reason: "NO_RUNNABLE_VERSION",
            generation: "2"
        ))

        let invalidRoot = try temporaryDirectory()
        let invalidInstaller = try CapsuleInstaller(storageRootURL: invalidRoot)
        _ = try invalidInstaller.installBundled(archiveURL: fixture("android-e2e-v2"), request: request())
        let invalidState = registry(
            generation: 7,
            active: ActiveVersion(version: "2.0.0", healthy: false),
            previous: PreviousVersion(version: "9.0.0"),
            pending: PendingVersion(version: "2.0.0", attempts: 2),
            highest: "9.0.0"
        )
        try publish(invalidState, root: invalidRoot)
        assertError(.rollbackTargetUnavailable) {
            try self.coordinator(root: invalidRoot, bundled: "invalid-signature")
                .recordExplicitFailure(self.session(registry: invalidState))
        }
        XCTAssertEqual(try IOSRuntimeBootstrap(storageRootURL: invalidRoot).readRegistry(capsuleId: capsuleId), invalidState)
    }

    func testConcurrentHealthyAndFailureCallbacksCommitOnlyOneTransition() throws {
        let root = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        let selected = try runtime.start(
            bundledArchiveURL: fixture("android-e2e-v1"),
            request: request()
        )
        let outcomes = try coordinator(root: root, bundled: "android-e2e-v1")
        let queue = DispatchQueue(label: "trial-outcome-race", attributes: .concurrent)
        let group = DispatchGroup()
        let results = OutcomeResultBox()
        for healthy in [true, false] {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let value = healthy
                        ? try outcomes.commitHealthy(selected)
                        : try outcomes.recordExplicitFailure(selected)
                    results.appendOutcome(value)
                } catch {
                    results.appendError((error as? WebCapsuleError)?.code ?? .storageIOFailed)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let snapshot = results.snapshot()
        XCTAssertEqual(snapshot.outcomes.count, 1)
        XCTAssertEqual(snapshot.errors, [.sessionMismatch])
        let registry = try XCTUnwrap(runtime.readRegistry(capsuleId: capsuleId))
        switch snapshot.outcomes[0] {
        case .healthy:
            XCTAssertTrue(registry.active.healthy)
            XCTAssertEqual(registry.generation, 2)
        case .pending:
            XCTAssertFalse(registry.active.healthy)
            XCTAssertEqual(registry.generation, 1)
        default:
            XCTFail("Attempt-one race cannot roll back or become terminal")
        }
    }

    private func coordinator(root: URL, bundled: String) throws -> IOSTrialOutcomeCoordinator {
        try IOSTrialOutcomeCoordinator(
            storageRootURL: root,
            bundledArchiveURL: fixture(bundled),
            request: request()
        )
    }

    private func session(registry: CapsuleRegistry) -> SessionDescriptor {
        SessionDescriptor(
            sessionId: "session-\(registry.generation)",
            capsuleId: capsuleId,
            version: registry.active.version,
            entry: "index.html",
            recordSHA256: String(repeating: "a", count: 64),
            registryGeneration: registry.generation,
            createdMonotonicNanoseconds: 1,
            files: [:],
            trialVersion: registry.active.version,
            trialAttempt: registry.pending?.attempts
        )
    }

    private func registry(
        generation: Int64,
        active: ActiveVersion,
        previous: PreviousVersion?,
        pending: PendingVersion?,
        highest: String
    ) -> CapsuleRegistry {
        CapsuleRegistry(
            schemaVersion: 1,
            capsuleId: capsuleId,
            generation: generation,
            active: active,
            previous: previous,
            pending: pending,
            highestSeenVersion: highest,
            blockedVersions: []
        )
    }

    private func publish(_ registry: CapsuleRegistry, root: URL) throws {
        let directory = root.appendingPathComponent("registries", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(CapsuleStorage.encodeStorageKey(capsuleId) + ".json")
        try RegistryCodec.serialize(registry).write(to: destination)
        XCTAssertEqual(Darwin.chmod(destination.path, 0o600), 0)
    }

    private func request() -> CapsuleVerificationRequest {
        CapsuleVerificationRequest(
            expectedCapsuleId: capsuleId,
            runtimeVersion: "1.0.0",
            publicKeys: ["test-only": try! String(
                contentsOf: repositoryRoot.appendingPathComponent("fixtures/keys/test-only-public.pem"),
                encoding: .utf8
            )]
        )
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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("webcapsule-outcomes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
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

private final class OutcomeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [IOSTrialOutcome] = []
    private var errors: [WebCapsuleErrorCode] = []

    func appendOutcome(_ outcome: IOSTrialOutcome) {
        lock.lock(); outcomes.append(outcome); lock.unlock()
    }

    func appendError(_ error: WebCapsuleErrorCode) {
        lock.lock(); errors.append(error); lock.unlock()
    }

    func snapshot() -> (outcomes: [IOSTrialOutcome], errors: [WebCapsuleErrorCode]) {
        lock.lock(); defer { lock.unlock() }
        return (outcomes, errors)
    }
}
