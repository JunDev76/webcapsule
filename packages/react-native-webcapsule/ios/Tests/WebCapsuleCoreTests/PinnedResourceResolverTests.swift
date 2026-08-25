import CryptoKit
import Darwin
import Foundation
import XCTest
#if canImport(WebKit)
import WebKit
#endif
@testable import WebCapsuleCore

final class PinnedResourceResolverTests: XCTestCase {
    private let fixtureCapsuleID = "com.example.android.e2e"
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.reversed().forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testInstalledSessionServesEveryDeclaredResourceWithExactMetadataAndBytes() throws {
        let root = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        let session = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: fixtureRequest())
        defer { session.releaseTrial() }
        let before = try XCTUnwrap(runtime.readRegistry(capsuleId: fixtureCapsuleID))
        let resolver = try PinnedResourceResolver(storageRootURL: root, session: session)

        XCTAssertEqual(
            resolver.entryURL.absoluteString,
            "webcapsule://com.example.android.e2e/1.0.0/index.html"
        )
        for file in session.files.values {
            let url = try XCTUnwrap(URL(string: PinnedResourceResolver.urlString(
                capsuleId: session.capsuleId,
                version: session.version,
                path: file.path
            )))
            let resource = try resolver.resolve(url)
            let bytes = try readAll(resource)
            XCTAssertEqual(resource.metadata.url, url, file.path)
            XCTAssertEqual(resource.metadata.mediaType, file.mediaType, file.path)
            XCTAssertEqual(resource.metadata.contentLength, file.size, file.path)
            XCTAssertEqual(bytes.count, Int(file.size), file.path)
            XCTAssertEqual(sha256(bytes), file.sha256, file.path)
        }
        XCTAssertEqual(try runtime.readRegistry(capsuleId: fixtureCapsuleID), before)
    }

    func testQueryIsIgnoredForLookupAndFragmentIsRejected() throws {
        let installed = try synthetic(data: Data("payload".utf8), path: "dir/value.bin", mediaType: "application/octet-stream")
        let resolver = try PinnedResourceResolver(storageRootURL: installed.root, session: installed.session)
        let resource = try resolver.resolve(rawURL: "webcapsule://com.example.fixture/1.0.0/dir/value.bin?cache=%2Fanything")
        XCTAssertEqual(try readAll(resource), Data("payload".utf8))
        assertError(.resourceDenied) {
            try resolver.resolve(rawURL: "webcapsule://com.example.fixture/1.0.0/dir/value.bin#fragment")
        }
    }

    func testRejectsEveryNoncanonicalOrUnpinnedURLShapeWithoutFallback() throws {
        let installed = try synthetic(data: Data("payload".utf8), path: "dir/value.bin", mediaType: "application/octet-stream")
        let resolver = try PinnedResourceResolver(storageRootURL: installed.root, session: installed.session)
        let invalid = [
            "https://com.example.fixture/1.0.0/dir/value.bin",
            "WEBCAPSULE://com.example.fixture/1.0.0/dir/value.bin",
            "webcapsule://other.example/1.0.0/dir/value.bin",
            "webcapsule://user@com.example.fixture/1.0.0/dir/value.bin",
            "webcapsule://com.example.fixture:80/1.0.0/dir/value.bin",
            "webcapsule://com.example.fixture/",
            "webcapsule://com.example.fixture/1.0.0",
            "webcapsule://com.example.fixture/1.0.0/",
            "webcapsule://com.example.fixture/2.0.0/dir/value.bin",
            "webcapsule://com.example.fixture/extra/1.0.0/dir/value.bin",
            "webcapsule://%63om.example.fixture/1.0.0/dir/value.bin",
            "webcapsule://com.example.fixture/%31.0.0/dir/value.bin",
            "webcapsule://com.example.fixture/1.0.0/dir/value.bin/extra",
            "webcapsule://com.example.fixture/1.0.0/dir",
            "webcapsule://com.example.fixture/1.0.0/index.html",
            "webcapsule://com.example.fixture/1.0.0/value.bin",
            "webcapsule://com.example.fixture/1.0.0/dir/value",
        ]
        for value in invalid {
            assertError(.resourceDenied, value) { try resolver.resolve(rawURL: value) }
        }
    }

    func testRejectsMalformedDoubleEncodedTraversalControlAndNonNFCPaths() throws {
        let installed = try synthetic(data: Data("payload".utf8), path: "dir/value.bin", mediaType: "application/octet-stream")
        let resolver = try PinnedResourceResolver(storageRootURL: installed.root, session: installed.session)
        let invalid = [
            "webcapsule://com.example.fixture/1.0.0/dir/%",
            "webcapsule://com.example.fixture/1.0.0/dir/%GG",
            "webcapsule://com.example.fixture/1.0.0/dir%2Fvalue.bin",
            "webcapsule://com.example.fixture/1.0.0/dir%5Cvalue.bin",
            "webcapsule://com.example.fixture/1.0.0/dir/%252Fvalue.bin",
            "webcapsule://com.example.fixture/1.0.0/dir/%252e%252e/value.bin",
            "webcapsule://com.example.fixture/1.0.0/dir/../value.bin",
            "webcapsule://com.example.fixture/1.0.0/dir/%00value.bin",
            "webcapsule://com.example.fixture/1.0.0/dir/%1Fvalue.bin",
            "webcapsule://com.example.fixture/1.0.0/dir/cafe%CC%81.bin",
            "webcapsule://com.example.fixture/1.0.0/dir//value.bin",
            "webcapsule://com.example.fixture/1.0.0/dir/./value.bin",
        ]
        for value in invalid {
            assertError(.resourceDenied, value) { try resolver.resolve(rawURL: value) }
        }
    }

    func testUnicodeNFCPathUsesUppercaseUTF8PercentRoundTrip() throws {
        let path = "문서/café.txt"
        let installed = try synthetic(data: Data("unicode".utf8), path: path, mediaType: "text/plain")
        let resolver = try PinnedResourceResolver(storageRootURL: installed.root, session: installed.session)
        let value = PinnedResourceResolver.urlString(
            capsuleId: installed.session.capsuleId,
            version: installed.session.version,
            path: path
        )
        XCTAssertEqual(
            value,
            "webcapsule://com.example.fixture/1.0.0/%EB%AC%B8%EC%84%9C/caf%C3%A9.txt"
        )
        XCTAssertEqual(try readAll(resolver.resolve(rawURL: value)), Data("unicode".utf8))
        assertError(.resourceDenied) {
            try resolver.resolve(rawURL: value.replacingOccurrences(of: "%EB", with: "%eb"))
        }
    }

    func testDeclaredMediaTypeIsUsedWithoutExtensionInference() throws {
        let installed = try synthetic(data: Data([0, 1, 2]), path: "asset.unknown", mediaType: "application/octet-stream")
        let resolver = try PinnedResourceResolver(storageRootURL: installed.root, session: installed.session)
        let resource = try resolver.resolve(rawURL: "webcapsule://com.example.fixture/1.0.0/asset.unknown")
        XCTAssertEqual(resource.metadata.mediaType, "application/octet-stream")
        XCTAssertEqual(resource.metadata.contentLength, 3)
        XCTAssertEqual(try readAll(resource), Data([0, 1, 2]))
    }

    func testOldDescriptorContinuesServingOldVersionAfterActiveTransition() throws {
        let root = try temporaryDirectory()
        let installer = try CapsuleInstaller(storageRootURL: root)
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v1"), request: fixtureRequest())
        _ = try installer.installBundled(archiveURL: fixture("android-e2e-v2"), request: fixtureRequest())
        try publishRegistry(
            registry(
                generation: 0,
                active: ActiveVersion(version: "1.0.0", healthy: true),
                previous: nil,
                pending: nil,
                highest: "2.0.0"
            ),
            root: root
        )
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        let oldSession = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: fixtureRequest())
        let oldResolver = try PinnedResourceResolver(storageRootURL: root, session: oldSession)
        _ = try runtime.compareAndSwap(capsuleId: fixtureCapsuleID, expectedGeneration: 0) { _ in
            self.registry(
                generation: 1,
                active: ActiveVersion(version: "2.0.0", healthy: false),
                previous: PreviousVersion(version: "1.0.0"),
                pending: PendingVersion(version: "2.0.0", attempts: 0),
                highest: "2.0.0"
            )
        }
        let newSession = try runtime.start(bundledArchiveURL: fixture("android-e2e-v1"), request: fixtureRequest())
        defer { newSession.releaseTrial() }
        let newResolver = try PinnedResourceResolver(storageRootURL: root, session: newSession)
        let old = try readAll(oldResolver.resolve(rawURL: "webcapsule://com.example.android.e2e/1.0.0/data.json"))
        let new = try readAll(newResolver.resolve(rawURL: "webcapsule://com.example.android.e2e/2.0.0/data.json"))
        XCTAssertEqual(old, Data("{\"version\":\"1.0.0\"}\n".utf8))
        XCTAssertEqual(new, Data("{\"version\":\"2.0.0\"}\n".utf8))
        assertError(.resourceDenied) {
            try oldResolver.resolve(rawURL: "webcapsule://com.example.android.e2e/2.0.0/data.json")
        }
    }

    func testMissingCorruptSizeModeSymlinkAndDirectoryBlobAreInvariantViolations() throws {
        for mutation in 0..<6 {
            let installed = try synthetic(data: Data("expected".utf8), path: "value.bin", mediaType: "application/octet-stream")
            let resolver = try PinnedResourceResolver(storageRootURL: installed.root, session: installed.session)
            XCTAssertEqual(Darwin.chmod(installed.blob.path, 0o644), 0)
            switch mutation {
            case 0:
                try FileManager.default.removeItem(at: installed.blob)
            case 1:
                try Data("corrupt!".utf8).write(to: installed.blob)
                XCTAssertEqual(Darwin.chmod(installed.blob.path, 0o444), 0)
            case 2:
                try Data("short".utf8).write(to: installed.blob)
                XCTAssertEqual(Darwin.chmod(installed.blob.path, 0o444), 0)
            case 3:
                break
            case 4:
                try FileManager.default.removeItem(at: installed.blob)
                let target = installed.root.appendingPathComponent("target")
                try Data("expected".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: installed.blob, withDestinationURL: target)
            default:
                try FileManager.default.removeItem(at: installed.blob)
                try FileManager.default.createDirectory(at: installed.blob, withIntermediateDirectories: false)
            }
            assertError(.storageInvariantViolation, "mutation \(mutation)") {
                try resolver.resolve(rawURL: "webcapsule://com.example.fixture/1.0.0/value.bin")
            }
        }
    }

    func testRootBlobsAndShardSubstitutionAreRejected() throws {
        for level in 0..<3 {
            let installed = try synthetic(data: Data("expected".utf8), path: "value.bin", mediaType: "application/octet-stream")
            let resolver = try PinnedResourceResolver(storageRootURL: installed.root, session: installed.session)
            let source: URL
            switch level {
            case 0: source = installed.root
            case 1: source = installed.root.appendingPathComponent("blobs")
            default: source = installed.blob.deletingLastPathComponent()
            }
            let moved = source.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent + "-old")
            try FileManager.default.moveItem(at: source, to: moved)
            temporaryDirectories.append(moved)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            assertError(.storageInvariantViolation, "level \(level)") {
                try resolver.resolve(rawURL: "webcapsule://com.example.fixture/1.0.0/value.bin")
            }
        }
    }

    func testPathSwapAfterOpenCannotChangeServedBytes() throws {
        let original = Data("opened-inode".utf8)
        let installed = try synthetic(data: original, path: "value.bin", mediaType: "application/octet-stream")
        let resolver = try PinnedResourceResolver(
            storageRootURL: installed.root,
            session: installed.session,
            afterBlobOpen: {
                try FileManager.default.removeItem(at: installed.blob)
                try Data("replacement!".utf8).write(to: installed.blob)
                guard Darwin.chmod(installed.blob.path, 0o444) == 0 else { throw CocoaError(.fileWriteUnknown) }
            }
        )
        let resource = try resolver.resolve(rawURL: "webcapsule://com.example.fixture/1.0.0/value.bin")
        XCTAssertEqual(try readAll(resource), original)
        XCTAssertEqual(try Data(contentsOf: installed.blob), Data("replacement!".utf8))
    }

    func testMutationDuringStreamingFailsClosed() throws {
        let bytes = Data(repeating: 0x41, count: PinnedResourceTaskCoordinator.maximumChunkSize * 3)
        let installed = try synthetic(data: bytes, path: "large.bin", mediaType: "application/octet-stream")
        let resolver = try PinnedResourceResolver(storageRootURL: installed.root, session: installed.session)
        let resource = try resolver.resolve(rawURL: "webcapsule://com.example.fixture/1.0.0/large.bin")
        XCTAssertEqual(try resource.stream.read(maximumCount: PinnedResourceTaskCoordinator.maximumChunkSize)?.count,
                       PinnedResourceTaskCoordinator.maximumChunkSize)
        XCTAssertEqual(Darwin.chmod(installed.blob.path, 0o644), 0)
        let handle = try FileHandle(forWritingTo: installed.blob)
        try handle.seek(toOffset: UInt64(PinnedResourceTaskCoordinator.maximumChunkSize))
        try handle.write(contentsOf: Data(repeating: 0x42, count: PinnedResourceTaskCoordinator.maximumChunkSize))
        try handle.close()
        XCTAssertEqual(Darwin.chmod(installed.blob.path, 0o444), 0)
        assertError(.storageInvariantViolation) {
            while try resource.stream.read(maximumCount: PinnedResourceTaskCoordinator.maximumChunkSize) != nil {}
            return ()
        }
    }

    func testHandlerRetainsPendingTrialLeaseAcrossResourceTasks() throws {
        let root = try temporaryDirectory()
        let runtime = try IOSRuntimeBootstrap(storageRootURL: root)
        var session: SessionDescriptor? = try runtime.start(
            bundledArchiveURL: fixture("android-e2e-v1"),
            request: fixtureRequest()
        )
        #if canImport(WebKit)
        var handler: WebCapsuleURLSchemeHandler? = try WebCapsuleURLSchemeHandler(
            storageRootURL: root,
            session: try XCTUnwrap(session)
        )
        #else
        var resolver: PinnedResourceResolver? = try PinnedResourceResolver(
            storageRootURL: root,
            session: try XCTUnwrap(session)
        )
        #endif
        session = nil
        assertError(.trialSessionInProgress) {
            try IOSRuntimeBootstrap(storageRootURL: root).start(
                bundledArchiveURL: self.fixture("android-e2e-v1"),
                request: self.fixtureRequest()
            )
        }
        #if canImport(WebKit)
        handler = nil
        XCTAssertNil(handler)
        #else
        resolver = nil
        XCTAssertNil(resolver)
        #endif
        let next = try IOSRuntimeBootstrap(storageRootURL: root).start(
            bundledArchiveURL: fixture("android-e2e-v1"),
            request: fixtureRequest()
        )
        next.releaseTrial()
    }

    func testResolverNeverCreatesMissingStorageLayout() throws {
        let root = try temporaryDirectory()
        let file = SessionFile(
            path: "index.html",
            sha256: String(repeating: "a", count: 64),
            size: 1,
            mediaType: "text/html"
        )
        let session = SessionDescriptor(
            sessionId: "missing-layout",
            capsuleId: "com.example.fixture",
            version: "1.0.0",
            entry: "index.html",
            recordSHA256: String(repeating: "b", count: 64),
            registryGeneration: 0,
            createdMonotonicNanoseconds: 1,
            files: [file.path: file],
            trialVersion: nil,
            trialAttempt: nil
        )

        assertError(.storageInvariantViolation) {
            try PinnedResourceResolver(storageRootURL: root, session: session)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    #if canImport(WebKit)
    func testConfigurationRegistersUsablePinnedCustomSchemeHandler() throws {
        let installed = try synthetic(data: Data("entry".utf8), path: "index.html", mediaType: "text/html")
        let made = try WebCapsuleWebViewConfiguration.make(
            storageRootURL: installed.root,
            session: installed.session
        )
        XCTAssertTrue(made.configuration.urlSchemeHandler(forURLScheme: "webcapsule") === made.handler)
        XCTAssertEqual(made.handler.entryURL.absoluteString,
                       "webcapsule://com.example.fixture/1.0.0/index.html")
    }
    #endif

    private func synthetic(
        data: Data,
        path: String,
        mediaType: String
    ) throws -> (root: URL, session: SessionDescriptor, blob: URL) {
        let root = try temporaryDirectory()
        _ = try CapsuleInstaller(storageRootURL: root)
        let digest = sha256(data)
        let shard = root.appendingPathComponent("blobs/sha256/\(digest.prefix(2))")
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: false)
        let blob = shard.appendingPathComponent(digest)
        try data.write(to: blob)
        XCTAssertEqual(Darwin.chmod(blob.path, 0o444), 0)
        let file = SessionFile(path: path, sha256: digest, size: Int64(data.count), mediaType: mediaType)
        let session = SessionDescriptor(
            sessionId: "session",
            capsuleId: "com.example.fixture",
            version: "1.0.0",
            entry: path,
            recordSHA256: String(repeating: "a", count: 64),
            registryGeneration: 0,
            createdMonotonicNanoseconds: 1,
            files: [path: file],
            trialVersion: nil,
            trialAttempt: nil
        )
        return (root, session, blob)
    }

    private func readAll(_ resource: PinnedResource) throws -> Data {
        var result = Data()
        while let chunk = try resource.stream.read(maximumCount: PinnedResourceTaskCoordinator.maximumChunkSize) {
            XCTAssertLessThanOrEqual(chunk.count, PinnedResourceTaskCoordinator.maximumChunkSize)
            result.append(chunk)
        }
        return result
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fixtureRequest() -> CapsuleVerificationRequest {
        CapsuleVerificationRequest(
            expectedCapsuleId: fixtureCapsuleID,
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
            .appendingPathComponent("webcapsule-resource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
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
            capsuleId: fixtureCapsuleID,
            generation: generation,
            active: active,
            previous: previous,
            pending: pending,
            highestSeenVersion: highest,
            blockedVersions: []
        )
    }

    private func publishRegistry(_ registry: CapsuleRegistry, root: URL) throws {
        let directory = root.appendingPathComponent("registries")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent(CapsuleStorage.encodeStorageKey(fixtureCapsuleID) + ".json")
        try RegistryCodec.serialize(registry).write(to: url)
        XCTAssertEqual(Darwin.chmod(url.path, 0o600), 0)
    }

    private func assertError(
        _ code: WebCapsuleErrorCode,
        _ message: String = "",
        operation: () throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), message, file: file, line: line) { error in
            XCTAssertEqual((error as? WebCapsuleError)?.code, code, "\(message): \(error)", file: file, line: line)
        }
    }
}

final class PinnedResourceTaskCoordinatorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testSuccessOrdersResponseBoundedDataAndFinishExactlyOnce() throws {
        let data = Data(repeating: 0x41, count: PinnedResourceTaskCoordinator.maximumChunkSize * 2 + 17)
        let setup = try resolver(data: data)
        let callbackQueue = DispatchQueue(label: "callback.success")
        let coordinator = PinnedResourceTaskCoordinator(resolver: setup.resolver, callbackQueue: callbackQueue)
        let terminal = expectation(description: "finished")
        let sink = FakeSink(url: setup.url, terminal: terminal)
        coordinator.start(sink)
        wait(for: [terminal], timeout: 5)

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.events.first, "response")
        XCTAssertEqual(snapshot.events.last, "finish")
        XCTAssertEqual(snapshot.events.filter { $0 == "finish" }.count, 1)
        XCTAssertFalse(snapshot.events.contains { $0.hasPrefix("fail:") })
        XCTAssertEqual(snapshot.data, data)
        XCTAssertTrue(snapshot.chunkSizes.allSatisfy { $0 <= PinnedResourceTaskCoordinator.maximumChunkSize })
        XCTAssertEqual(snapshot.response?.expectedContentLength, Int64(data.count))
        XCTAssertEqual(snapshot.response?.mimeType, "application/octet-stream")
    }

    func testDeniedRequestFailsOnlyWithoutContentCallbacks() throws {
        let setup = try resolver(data: Data("data".utf8))
        let terminal = expectation(description: "failed")
        let sink = FakeSink(
            url: try XCTUnwrap(URL(string: "webcapsule://com.example.fixture/1.0.0/undeclared.bin")),
            terminal: terminal
        )
        let coordinator = PinnedResourceTaskCoordinator(resolver: setup.resolver)
        coordinator.start(sink)
        wait(for: [terminal], timeout: 5)
        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.events, ["fail:RESOURCE_DENIED"])
        XCTAssertTrue(snapshot.data.isEmpty)
        XCTAssertNil(snapshot.response)
    }

    func testStopBeforeOpenAndDuplicateStopSuppressAllCallbacks() throws {
        let setup = try resolver(data: Data("data".utf8))
        let work = DispatchQueue(label: "work.suspended")
        work.suspend()
        let callbacks = DispatchQueue(label: "callback.stopped")
        let coordinator = PinnedResourceTaskCoordinator(
            resolver: setup.resolver,
            workQueue: work,
            callbackQueue: callbacks
        )
        let sink = FakeSink(url: setup.url)
        coordinator.start(sink)
        coordinator.stop(sink)
        coordinator.stop(sink)
        work.resume()
        work.sync {}
        callbacks.sync {}
        XCTAssertEqual(sink.snapshot().events, [])
    }

    func testStopMidStreamSuppressesLaterDataAndTerminalCallbacks() throws {
        let data = Data(repeating: 0x41, count: PinnedResourceTaskCoordinator.maximumChunkSize * 3)
        let setup = try resolver(data: data)
        let callbacks = DispatchQueue(label: "callback.midstop")
        let fatalCount = ResourceFatalCount()
        let coordinator = PinnedResourceTaskCoordinator(
            resolver: setup.resolver,
            callbackQueue: callbacks,
            fatalObserver: { _ in fatalCount.increment() }
        )
        let firstData = expectation(description: "first data")
        let sink = FakeSink(url: setup.url)
        sink.onFirstData = { [weak coordinator, weak sink] in
            guard let coordinator, let sink else { return }
            coordinator.stop(sink)
            firstData.fulfill()
        }
        coordinator.start(sink)
        wait(for: [firstData], timeout: 5)
        callbacks.sync {}
        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.events, ["response", "data"])
        XCTAssertEqual(snapshot.data.count, PinnedResourceTaskCoordinator.maximumChunkSize)
        XCTAssertEqual(fatalCount.value, 0)
    }

    func testConcurrentTasksCompleteIndependently() throws {
        let data = Data(repeating: 0x43, count: PinnedResourceTaskCoordinator.maximumChunkSize + 3)
        let setup = try resolver(data: data)
        let coordinator = PinnedResourceTaskCoordinator(
            resolver: setup.resolver,
            workQueue: DispatchQueue(label: "work.concurrent", attributes: .concurrent),
            callbackQueue: DispatchQueue(label: "callback.concurrent")
        )
        let expectations = (0..<8).map { expectation(description: "task-\($0)") }
        let sinks = expectations.map { FakeSink(url: setup.url, terminal: $0) }
        sinks.forEach(coordinator.start)
        wait(for: expectations, timeout: 10)
        for sink in sinks {
            let snapshot = sink.snapshot()
            XCTAssertEqual(snapshot.data, data)
            XCTAssertEqual(snapshot.events.last, "finish")
        }
    }

    func testDuplicateStartTerminatesOnceWithoutStartingContent() throws {
        let setup = try resolver(data: Data("data".utf8))
        let work = DispatchQueue(label: "work.duplicate")
        work.suspend()
        let terminal = expectation(description: "duplicate failed")
        let callbacks = DispatchQueue(label: "callback.duplicate")
        let coordinator = PinnedResourceTaskCoordinator(
            resolver: setup.resolver,
            workQueue: work,
            callbackQueue: callbacks
        )
        let sink = FakeSink(url: setup.url, terminal: terminal)
        coordinator.start(sink)
        coordinator.start(sink)
        wait(for: [terminal], timeout: 5)
        work.resume()
        work.sync {}
        callbacks.sync {}
        XCTAssertEqual(sink.snapshot().events, ["fail:RESOURCE_DENIED"])
    }

    private func resolver(data: Data) throws -> (resolver: PinnedResourceResolver, url: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webcapsule-task-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        temporaryDirectories.append(root)
        _ = try CapsuleInstaller(storageRootURL: root)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let shard = root.appendingPathComponent("blobs/sha256/\(digest.prefix(2))")
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: false)
        let blob = shard.appendingPathComponent(digest)
        try data.write(to: blob)
        XCTAssertEqual(Darwin.chmod(blob.path, 0o444), 0)
        let path = "content.bin"
        let file = SessionFile(path: path, sha256: digest, size: Int64(data.count), mediaType: "application/octet-stream")
        let session = SessionDescriptor(
            sessionId: "task-session",
            capsuleId: "com.example.fixture",
            version: "1.0.0",
            entry: path,
            recordSHA256: String(repeating: "a", count: 64),
            registryGeneration: 0,
            createdMonotonicNanoseconds: 1,
            files: [path: file],
            trialVersion: nil,
            trialAttempt: nil
        )
        let resolver = try PinnedResourceResolver(storageRootURL: root, session: session)
        return (resolver, try XCTUnwrap(URL(string: "webcapsule://com.example.fixture/1.0.0/content.bin")))
    }
}

private final class ResourceFatalCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class FakeSink: PinnedResourceTaskSink {
    struct Snapshot {
        let events: [String]
        let data: Data
        let chunkSizes: [Int]
        let response: URLResponse?
    }

    let requestURL: URL?
    var onFirstData: (() -> Void)?

    private let lock = NSLock()
    private let terminal: XCTestExpectation?
    private var events: [String] = []
    private var data = Data()
    private var chunkSizes: [Int] = []
    private var response: URLResponse?
    private var receivedFirstData = false

    init(url: URL?, terminal: XCTestExpectation? = nil) {
        requestURL = url
        self.terminal = terminal
    }

    func didReceive(_ response: URLResponse) {
        lock.lock()
        events.append("response")
        self.response = response
        lock.unlock()
    }

    func didReceive(_ data: Data) {
        lock.lock()
        events.append("data")
        self.data.append(data)
        chunkSizes.append(data.count)
        let first = !receivedFirstData
        receivedFirstData = true
        lock.unlock()
        if first { onFirstData?() }
    }

    func didFinish() {
        lock.lock()
        events.append("finish")
        lock.unlock()
        terminal?.fulfill()
    }

    func didFail(_ error: Error) {
        lock.lock()
        let code = (error as? WebCapsuleError)?.code.rawValue ?? "UNKNOWN"
        events.append("fail:\(code)")
        lock.unlock()
        terminal?.fulfill()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(events: events, data: data, chunkSizes: chunkSizes, response: response)
    }
}
