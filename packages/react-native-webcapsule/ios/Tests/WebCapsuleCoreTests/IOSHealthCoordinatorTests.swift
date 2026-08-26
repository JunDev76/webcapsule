import Foundation
import XCTest
@testable import WebCapsuleCore

final class ReadyMessageParserTests: XCTestCase {
    func testAcceptsOnlyExactReadyJSONContract() throws {
        XCTAssertEqual(try ReadyMessageParser.parse(validReadyJSON()), ReadyMessage(
            type: "ready",
            protocolVersion: 1,
            sessionId: "session-1",
            capsuleId: "com.example.app",
            version: "1.0.0"
        ))
        let valid = validReadyJSON()
        for value in [
            "{}",
            valid.replacingOccurrences(of: "\"version\":\"1.0.0\"", with: "\"extra\":true,\"version\":\"1.0.0\""),
            valid.replacingOccurrences(of: "\"type\":\"ready\"", with: "\"type\":\"ready\",\"type\":\"ready\""),
            valid.replacingOccurrences(of: "\"sessionId\":\"session-1\"", with: "\"sessionId\":{\"x\":1,\"x\":2}"),
            valid.replacingOccurrences(of: "\"protocolVersion\":1", with: "\"protocolVersion\":\"1\""),
            valid.replacingOccurrences(of: "\"type\":\"ready\"", with: "\"type\":\"other\""),
            valid.replacingOccurrences(of: "\"protocolVersion\":1", with: "\"protocolVersion\":2"),
            "not-json",
        ] {
            assertHealthError(.readyMessageInvalid) { try ReadyMessageParser.parse(value) }
        }
    }

    func testBootstrapScriptContainsOnlyFrozenPublicSessionIdentity() {
        let script = WebCapsuleReadyBridgeContract.bootstrapScript(session: healthSession())
        XCTAssertEqual(
            script,
            "Object.defineProperty(globalThis,'__WEBCAPSULE_SESSION__',{value:Object.freeze({\"capsuleId\":\"com.example.app\",\"protocolVersion\":1,\"sessionId\":\"session-1\",\"type\":\"ready\",\"version\":\"1.0.0\"}),writable:false,configurable:false,enumerable:false});Object.defineProperty(globalThis,'WebCapsuleBridge',{value:Object.freeze({postMessage:function(value){globalThis.webkit.messageHandlers.WebCapsuleBridge.postMessage(value);}}),writable:false,configurable:false,enumerable:false});"
        )
        XCTAssertTrue(script.contains("WebCapsuleBridge.postMessage(value)"))
        XCTAssertFalse(script.contains("sha256"))
        XCTAssertFalse(script.contains("record"))
        XCTAssertFalse(script.contains("storage"))
        XCTAssertEqual(WebCapsuleReadyBridgeContract.channelName, "WebCapsuleBridge")
    }
}

final class IOSHealthCoordinatorTests: XCTestCase {
    func testMatchingReadyAfterEntryStabilizesAtExactBoundaryAndSucceedsOnce() {
        let scheduler = FakeHealthScheduler(now: 100)
        let commits = HealthTestBox(0)
        let successes = HealthTestBox(0)
        let failures = HealthTestBox<[WebCapsuleError]>([])
        let coordinator = makeCoordinator(
            scheduler: scheduler,
            commit: { commits.mutate { $0 += 1 } },
            success: { successes.mutate { $0 += 1 } },
            failure: { error in failures.mutate { $0.append(error) } }
        )
        coordinator.entryLoaded()
        XCTAssertEqual(successes.get(), 0, "entry load alone is not healthy")
        coordinator.ready(body: validReadyJSON(), source: validReadySource())
        scheduler.advance(by: IOSHealthCoordinator.stabilizationNanoseconds - 1)
        XCTAssertEqual(commits.get(), 0)
        XCTAssertEqual(successes.get(), 0)
        scheduler.advance(by: 1)
        XCTAssertEqual(commits.get(), 1)
        XCTAssertEqual(successes.get(), 1)
        XCTAssertTrue(failures.get().isEmpty)
        scheduler.advance(by: 30_000_000_000)
        XCTAssertEqual(commits.get(), 1)
        XCTAssertEqual(successes.get(), 1)
    }

    func testReadyBeforeEntryStabilizesFromTheLaterLatch() {
        let scheduler = FakeHealthScheduler(now: 100)
        let commits = HealthTestBox(0)
        let successes = HealthTestBox(0)
        let failures = HealthTestBox<[WebCapsuleError]>([])
        let coordinator = makeCoordinator(
            scheduler: scheduler,
            commit: { commits.mutate { $0 += 1 } },
            success: { successes.mutate { $0 += 1 } },
            failure: { error in failures.mutate { $0.append(error) } }
        )
        // didFinish is not observable from page scripts, so ready may arrive first.
        coordinator.ready(body: validReadyJSON(), source: validReadySource())
        scheduler.advance(by: IOSHealthCoordinator.stabilizationNanoseconds)
        XCTAssertEqual(successes.get(), 0, "ready alone is not healthy")
        XCTAssertTrue(failures.get().isEmpty, "an early ready is not a failure")

        coordinator.entryLoaded()
        scheduler.advance(by: IOSHealthCoordinator.stabilizationNanoseconds - 1)
        XCTAssertEqual(commits.get(), 0, "stabilization is timed from the later latch")
        scheduler.advance(by: 1)
        XCTAssertEqual(commits.get(), 1)
        XCTAssertEqual(successes.get(), 1)
        XCTAssertTrue(failures.get().isEmpty)
    }

    func testEntryFailureAfterEarlyReadyStillFails() {
        let scheduler = FakeHealthScheduler(now: 100)
        let successes = HealthTestBox(0)
        let failures = HealthTestBox<[WebCapsuleError]>([])
        let coordinator = makeCoordinator(
            scheduler: scheduler,
            success: { successes.mutate { $0 += 1 } },
            failure: { error in failures.mutate { $0.append(error) } }
        )
        coordinator.ready(body: validReadyJSON(), source: validReadySource())
        coordinator.entryFailed("entry failed")
        scheduler.advance(by: 30_000_000_000)
        XCTAssertEqual(failures.get().map(\.code), [.entryLoadFailed])
        XCTAssertEqual(successes.get(), 0)
    }

    func testDeadlineIsExactlyFifteenSecondsFromSessionCreation() {
        let scheduler = FakeHealthScheduler(now: 100)
        let failures = HealthTestBox<[WebCapsuleError]>([])
        let coordinator = makeCoordinator(scheduler: scheduler) { error in failures.mutate { $0.append(error) } }
        scheduler.advance(by: IOSHealthCoordinator.readyTimeoutNanoseconds - 1)
        XCTAssertTrue(failures.get().isEmpty)
        scheduler.advance(by: 1)
        XCTAssertEqual(failures.get().map(\.code), [.readyTimeout])
        withExtendedLifetime(coordinator) {}

        let expired = FakeHealthScheduler(now: 100 + IOSHealthCoordinator.readyTimeoutNanoseconds)
        let immediate = HealthTestBox<[WebCapsuleError]>([])
        _ = makeCoordinator(scheduler: expired) { error in immediate.mutate { $0.append(error) } }
        XCTAssertEqual(immediate.get().map(\.code), [.readyTimeout])

        let delayedTimer = FakeHealthScheduler(now: 100)
        let boundary = HealthTestBox<[WebCapsuleError]>([])
        let boundaryCoordinator = makeCoordinator(scheduler: delayedTimer) { error in
            boundary.mutate { $0.append(error) }
        }
        boundaryCoordinator.entryLoaded()
        delayedTimer.setNowWithoutRunningTasks(100 + IOSHealthCoordinator.readyTimeoutNanoseconds)
        boundaryCoordinator.ready(body: validReadyJSON(), source: validReadySource())
        XCTAssertEqual(boundary.get().map(\.code), [.readyTimeout])
    }

    func testDuplicateReadyAndFatalDuringStabilizationFailOnce() {
        let earlyScheduler = FakeHealthScheduler(now: 100)
        let early = HealthTestBox<[WebCapsuleError]>([])
        let beforeEntry = makeCoordinator(scheduler: earlyScheduler) { error in early.mutate { $0.append(error) } }
        beforeEntry.ready(body: validReadyJSON(), source: validReadySource())
        beforeEntry.ready(body: validReadyJSON(), source: validReadySource())
        XCTAssertEqual(early.get().map(\.code), [.readyMessageInvalid], "a second ready is still a duplicate")

        let duplicateScheduler = FakeHealthScheduler(now: 100)
        let duplicate = HealthTestBox<[WebCapsuleError]>([])
        let duplicateReady = makeCoordinator(scheduler: duplicateScheduler) { error in duplicate.mutate { $0.append(error) } }
        duplicateReady.entryLoaded()
        duplicateReady.ready(body: validReadyJSON(), source: validReadySource())
        duplicateReady.ready(body: validReadyJSON(), source: validReadySource())
        duplicateScheduler.advance(by: IOSHealthCoordinator.stabilizationNanoseconds)
        XCTAssertEqual(duplicate.get().map(\.code), [.readyMessageInvalid])

        let fatalScheduler = FakeHealthScheduler(now: 100)
        let fatal = HealthTestBox<[WebCapsuleError]>([])
        let stabilizing = makeCoordinator(scheduler: fatalScheduler) { error in fatal.mutate { $0.append(error) } }
        stabilizing.entryLoaded()
        stabilizing.ready(body: validReadyJSON(), source: validReadySource())
        stabilizing.fatal("renderer exited")
        fatalScheduler.advance(by: IOSHealthCoordinator.stabilizationNanoseconds)
        XCTAssertEqual(fatal.get().map(\.code), [.stabilizationFailed])
    }

    func testSourceAndIdentityEnforcementUseStableErrors() {
        for source in [
            ReadyMessageSource(isMainFrame: false, scheme: "webcapsule", host: "com.example.app", port: 0, documentURL: healthEntryURL()),
            ReadyMessageSource(isMainFrame: true, scheme: "https", host: "com.example.app", port: 0, documentURL: healthEntryURL()),
            ReadyMessageSource(isMainFrame: true, scheme: "webcapsule", host: "other.example", port: 0, documentURL: healthEntryURL()),
            ReadyMessageSource(isMainFrame: true, scheme: "webcapsule", host: "com.example.app", port: 443, documentURL: healthEntryURL()),
            ReadyMessageSource(isMainFrame: true, scheme: "webcapsule", host: "com.example.app", port: 0, documentURL: URL(string: "webcapsule://com.example.app/1.0.0/other.html")),
        ] {
            let scheduler = FakeHealthScheduler(now: 100)
            let failures = HealthTestBox<[WebCapsuleError]>([])
            let coordinator = makeCoordinator(scheduler: scheduler) { error in failures.mutate { $0.append(error) } }
            coordinator.entryLoaded()
            coordinator.ready(body: validReadyJSON(), source: source)
            XCTAssertEqual(failures.get().map(\.code), [.readyMessageInvalid])
        }

        for (old, new) in [("session-1", "other-session"), ("com.example.app", "com.other.app"), ("1.0.0", "2.0.0")] {
            let scheduler = FakeHealthScheduler(now: 100)
            let failures = HealthTestBox<[WebCapsuleError]>([])
            let coordinator = makeCoordinator(scheduler: scheduler) { error in failures.mutate { $0.append(error) } }
            coordinator.entryLoaded()
            coordinator.ready(
                body: validReadyJSON().replacingOccurrences(of: old, with: new),
                source: validReadySource()
            )
            XCTAssertEqual(failures.get().map(\.code), [.sessionMismatch])
        }
    }

    func testEntryFailureCancellationAndBackgroundHaveExactSemantics() {
        let scheduler = FakeHealthScheduler(now: 100)
        let failures = HealthTestBox<[WebCapsuleError]>([])
        let coordinator = makeCoordinator(scheduler: scheduler) { error in failures.mutate { $0.append(error) } }
        coordinator.entryFailed("entry failed")
        coordinator.fatal("later")
        scheduler.advance(by: 30_000_000_000)
        XCTAssertEqual(failures.get().map(\.code), [.entryLoadFailed])

        let cancelledScheduler = FakeHealthScheduler(now: 100)
        let cancelledFailures = HealthTestBox<[WebCapsuleError]>([])
        let success = HealthTestBox(false)
        let cancelled = makeCoordinator(
            scheduler: cancelledScheduler,
            success: { success.set(true) },
            failure: { error in cancelledFailures.mutate { $0.append(error) } }
        )
        cancelled.entryLoaded()
        cancelled.ready(body: validReadyJSON(), source: validReadySource())
        cancelled.close()
        cancelledScheduler.advance(by: 30_000_000_000)
        XCTAssertFalse(success.get())
        XCTAssertTrue(cancelledFailures.get().isEmpty)

        // Backgrounding has no failure input. Monotonic time still reaches the deadline.
        let backgroundScheduler = FakeHealthScheduler(now: 100)
        let background = HealthTestBox<[WebCapsuleError]>([])
        let backgroundCoordinator = makeCoordinator(scheduler: backgroundScheduler) { error in background.mutate { $0.append(error) } }
        backgroundScheduler.advance(by: IOSHealthCoordinator.readyTimeoutNanoseconds)
        XCTAssertEqual(background.get().map(\.code), [.readyTimeout])
        withExtendedLifetime(backgroundCoordinator) {}
    }

    private func makeCoordinator(
        scheduler: FakeHealthScheduler,
        commit: @escaping @Sendable () throws -> Void = {},
        success: @escaping @Sendable () -> Void = {},
        failure: @escaping @Sendable (WebCapsuleError) -> Void
    ) -> IOSHealthCoordinator {
        IOSHealthCoordinator(
            session: healthSession(),
            entryURL: healthEntryURL(),
            scheduler: scheduler,
            commit: commit,
            success: success,
            failure: failure
        )
    }
}

private final class HealthTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
}

private final class FakeHealthScheduler: IOSHealthScheduling, @unchecked Sendable {
    private final class Token {
        let deadline: UInt64
        let action: @Sendable () -> Void
        var cancelled = false

        init(deadline: UInt64, action: @escaping @Sendable () -> Void) {
            self.deadline = deadline
            self.action = action
        }
    }

    var nowNanoseconds: UInt64
    private var tasks: [Token] = []

    init(now: UInt64) { nowNanoseconds = now }

    func schedule(afterNanoseconds: UInt64, _ action: @escaping @Sendable () -> Void) -> AnyObject {
        let token = Token(deadline: nowNanoseconds + afterNanoseconds, action: action)
        tasks.append(token)
        return token
    }

    func cancel(_ token: AnyObject) { (token as? Token)?.cancelled = true }

    func setNowWithoutRunningTasks(_ value: UInt64) {
        nowNanoseconds = value
    }

    func advance(by interval: UInt64) {
        nowNanoseconds += interval
        while let next = tasks
            .filter({ !$0.cancelled && $0.deadline <= nowNanoseconds })
            .min(by: { $0.deadline < $1.deadline }) {
            next.cancelled = true
            next.action()
        }
    }
}

private func healthSession() -> SessionDescriptor {
    SessionDescriptor(
        sessionId: "session-1",
        capsuleId: "com.example.app",
        version: "1.0.0",
        entry: "index.html",
        recordSHA256: String(repeating: "a", count: 64),
        registryGeneration: 1,
        createdMonotonicNanoseconds: 100,
        files: [:],
        trialVersion: "1.0.0",
        trialAttempt: 1
    )
}

private func healthEntryURL() -> URL {
    URL(string: "webcapsule://com.example.app/1.0.0/index.html")!
}

private func validReadySource() -> ReadyMessageSource {
    ReadyMessageSource(
        isMainFrame: true,
        scheme: "webcapsule",
        host: "com.example.app",
        port: 0,
        documentURL: healthEntryURL()
    )
}

private func validReadyJSON() -> String {
    "{\"type\":\"ready\",\"protocolVersion\":1,\"sessionId\":\"session-1\",\"capsuleId\":\"com.example.app\",\"version\":\"1.0.0\"}"
}

private func assertHealthError(
    _ code: WebCapsuleErrorCode,
    operation: () throws -> Any,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
        XCTAssertEqual((error as? WebCapsuleError)?.code, code, file: file, line: line)
    }
}
