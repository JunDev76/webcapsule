import CryptoKit
import Darwin
import Foundation
import XCTest
#if canImport(WebKit)
import WebKit
#endif
@testable import WebCapsuleCore

final class IOSRuntimeEnvironmentTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.reversed().forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testResolvesNestedBundleRelativeRegularFile() throws {
        let root = try temporaryDirectory()
        let nested = root.appendingPathComponent("assets/webcapsule", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let archive = nested.appendingPathComponent("guide.capsule")
        try Data("archive".utf8).write(to: archive)

        XCTAssertEqual(
            try IOSBundleAssetResolver.resolve(
                path: "assets/webcapsule/guide.capsule",
                resourceRootURL: root
            ),
            archive
        )
    }

    func testRejectsMissingTraversalURLAbsoluteAndSymlinkBundleAssets() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory().appendingPathComponent("outside.capsule")
        try Data("outside".utf8).write(to: outside)
        let link = root.appendingPathComponent("linked.capsule")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        for path in [
            "missing.capsule", "../outside.capsule", "/tmp/a.capsule",
            "file://a.capsule", "https://example.invalid/a.capsule", "a\\b.capsule",
            "linked.capsule",
        ] {
            XCTAssertThrowsError(try IOSBundleAssetResolver.resolve(path: path, resourceRootURL: root))
        }
    }

    func testPreparesApplicationSupportWebCapsuleV1WithModeAndBackupExclusion() throws {
        let support = try temporaryDirectory()
        var excluded: URL?
        let root = try IOSRuntimeStorageRoot.prepare(
            applicationSupportURL: support,
            backupExcluder: { excluded = $0 }
        )
        XCTAssertEqual(root, support.appendingPathComponent("webcapsule/v1", isDirectory: true))
        XCTAssertEqual(excluded, root)
        XCTAssertEqual(try mode(root), 0o700)
        XCTAssertEqual(try mode(root.deletingLastPathComponent()), 0o700)
    }

    func testRejectsSymlinkStorageComponent() throws {
        let support = try temporaryDirectory()
        let target = try temporaryDirectory()
        try FileManager.default.createSymbolicLink(
            at: support.appendingPathComponent("webcapsule"),
            withDestinationURL: target
        )
        assertError(.unsafeStorageLayout) {
            try IOSRuntimeStorageRoot.prepare(applicationSupportURL: support, backupExcluder: { _ in })
        }
    }

    func testPreparerConnectsNestedBundleAssetToApplicationSupportPinnedSession() throws {
        let bundle = try temporaryDirectory()
        let support = try temporaryDirectory()
        let nested = bundle.appendingPathComponent("assets/capsules", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let archive = nested.appendingPathComponent("bundled.capsule")
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("fixtures/capsules/android-e2e-v1.capsule"),
            to: archive
        )
        let publicKey = try String(
            contentsOf: repositoryRoot.appendingPathComponent("fixtures/keys/test-only-public.pem"),
            encoding: .utf8
        )
        let prepared = try IOSRuntimePreparer.prepare(
            config: WebCapsuleConfig(
                capsuleId: "com.example.android.e2e",
                bundledAssetPath: "assets/capsules/bundled.capsule",
                publicKeys: ["test-only": publicKey],
                runtimeVersion: "1.0.0"
            ),
            bundleResourceRootURL: bundle,
            applicationSupportURL: support
        )
        defer { prepared.session.releaseTrial() }

        XCTAssertEqual(prepared.storageRootURL, support.appendingPathComponent("webcapsule/v1"))
        XCTAssertEqual(prepared.session.capsuleId, "com.example.android.e2e")
        XCTAssertEqual(prepared.session.version, "1.0.0")
        XCTAssertEqual(prepared.session.entry, "index.html")
        XCTAssertEqual(prepared.session.trialAttempt, 1)
        XCTAssertEqual(
            try PinnedResourceResolver(
                storageRootURL: prepared.storageRootURL,
                session: prepared.session
            ).entryURL.absoluteString,
            "webcapsule://com.example.android.e2e/1.0.0/index.html"
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("webcapsule-view-environment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
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
            XCTAssertEqual((error as? WebCapsuleError)?.code, code, file: file, line: line)
        }
    }
}

final class IOSWebCapsuleLifecycleControllerTests: XCTestCase {
    func testPreparesOffMainAndDeliversReadyOnCallbackQueueOnce() throws {
        let work = DispatchQueue(label: "test.bootstrap")
        let callbacks = DispatchQueue(label: "test.callbacks")
        let ready = expectation(description: "ready")
        let preparedOnMain = LockedValue(true)
        let callbackOnExpectedQueue = LockedValue(false)
        let key = DispatchSpecificKey<Bool>()
        callbacks.setSpecific(key: key, value: true)
        let controller = IOSWebCapsuleLifecycleController(
            workQueue: work,
            callbackQueue: callbacks,
            prepare: { config in
                preparedOnMain.set(Thread.isMainThread)
                return self.prepared(config: config)
            }
        )
        XCTAssertTrue(controller.apply(config: config("a"), onReady: { _ in
            callbackOnExpectedQueue.set(DispatchQueue.getSpecific(key: key) == true)
            ready.fulfill()
        }, onError: { error in XCTFail("unexpected \(error)") }))
        wait(for: [ready], timeout: 5)
        XCTAssertFalse(preparedOnMain.get())
        XCTAssertTrue(callbackOnExpectedQueue.get())
        controller.invalidate()
    }

    func testEquivalentPropsAreIdempotent() {
        let work = DispatchQueue(label: "test.idempotent")
        let callbacks = DispatchQueue(label: "test.idempotent.callbacks")
        let ready = expectation(description: "ready")
        let count = LockedValue(0)
        let controller = IOSWebCapsuleLifecycleController(
            workQueue: work,
            callbackQueue: callbacks,
            prepare: { config in count.mutate { $0 += 1 }; return self.prepared(config: config) }
        )
        let value = config("same")
        XCTAssertTrue(controller.apply(config: value, onReady: { _ in ready.fulfill() }, onError: { _ in }))
        XCTAssertFalse(controller.apply(config: value, onReady: { _ in XCTFail("duplicate") }, onError: { _ in }))
        wait(for: [ready], timeout: 5)
        XCTAssertEqual(count.get(), 1)
        controller.invalidate()
    }

    func testReplacementSuppressesStaleCompletionAndKeepsNewPinnedSession() {
        let work = DispatchQueue(label: "test.replace")
        work.suspend()
        let callbacks = DispatchQueue(label: "test.replace.callbacks")
        let ready = expectation(description: "new ready")
        let versions = LockedValue<[String]>([])
        let controller = IOSWebCapsuleLifecycleController(
            workQueue: work,
            callbackQueue: callbacks,
            prepare: { self.prepared(config: $0) }
        )
        XCTAssertTrue(controller.apply(config: config("old"), onReady: { value in
            versions.mutate { $0.append(value.session.version) }
        }, onError: { _ in XCTFail("stale error") }))
        XCTAssertTrue(controller.apply(config: config("new"), onReady: { value in
            versions.mutate { $0.append(value.session.version) }
            ready.fulfill()
        }, onError: { _ in XCTFail("unexpected error") }))
        work.resume()
        wait(for: [ready], timeout: 5)
        callbacks.sync {}
        XCTAssertEqual(versions.get(), ["2.0.0"])
        controller.invalidate()
    }

    func testInvalidationSuppressesSuccessAndFailure() {
        let work = DispatchQueue(label: "test.invalidate")
        work.suspend()
        let callbacks = DispatchQueue(label: "test.invalidate.callbacks")
        let noCallback = expectation(description: "no callback")
        noCallback.isInverted = true
        let controller = IOSWebCapsuleLifecycleController(
            workQueue: work,
            callbackQueue: callbacks,
            prepare: { self.prepared(config: $0) }
        )
        _ = controller.apply(config: config("cancelled"), onReady: { _ in noCallback.fulfill() }, onError: { _ in noCallback.fulfill() })
        controller.invalidate()
        work.resume()
        wait(for: [noCallback], timeout: 0.2)
    }

    func testBootstrapErrorPreservesExactCodeAndEmitsOnce() {
        let errorReceived = expectation(description: "error")
        let callbacks = DispatchQueue(label: "test.error.callbacks")
        let controller = IOSWebCapsuleLifecycleController(
            callbackQueue: callbacks,
            prepare: { _ in throw WebCapsuleError(code: .archiveInvalid, message: "invalid archive") }
        )
        let observed = LockedValue<WebCapsuleError?>(nil)
        _ = controller.apply(config: config("failure"), onReady: { _ in XCTFail("unexpected ready") }, onError: {
            observed.set($0)
            errorReceived.fulfill()
        })
        wait(for: [errorReceived], timeout: 5)
        XCTAssertEqual(observed.get(), WebCapsuleError(code: .archiveInvalid, message: "invalid archive"))
        controller.invalidate()
    }

    private func config(_ version: String) -> WebCapsuleConfig {
        WebCapsuleConfig(
            capsuleId: "com.example.fixture",
            bundledAssetPath: "webcapsule/\(version).capsule",
            publicKeys: ["release": "pem"],
            runtimeVersion: version == "new" ? "2.0.0" : "1.0.0"
        )
    }

    private func prepared(config: WebCapsuleConfig) -> IOSPreparedRuntimeSession {
        let version = config.runtimeVersion
        let file = SessionFile(
            path: "index.html",
            sha256: String(repeating: "a", count: 64),
            size: 0,
            mediaType: "text/html"
        )
        return IOSPreparedRuntimeSession(
            storageRootURL: FileManager.default.temporaryDirectory,
            session: SessionDescriptor(
                sessionId: version,
                capsuleId: config.capsuleId,
                version: version,
                entry: file.path,
                recordSHA256: String(repeating: "b", count: 64),
                registryGeneration: 0,
                createdMonotonicNanoseconds: 1,
                files: [file.path: file],
                trialVersion: nil,
                trialAttempt: nil
            )
        )
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
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

#if canImport(WebKit)
final class IOSWebViewSecurityTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testReactNativeContractConstantsMatchTypeScriptBoundary() {
        XCTAssertEqual(IOSWebCapsuleContract.componentName, "WebCapsuleView")
        XCTAssertEqual(
            [IOSWebCapsuleContract.capsuleIDProp, IOSWebCapsuleContract.bundledAssetPathProp,
             IOSWebCapsuleContract.publicKeysProp, IOSWebCapsuleContract.runtimeVersionProp],
            ["capsuleId", "bundledAssetPath", "publicKeys", "runtimeVersion"]
        )
        XCTAssertEqual(
            [IOSWebCapsuleContract.loadEvent, IOSWebCapsuleContract.errorEvent,
             IOSWebCapsuleContract.rollbackEvent],
            ["onLoad", "onError", "onRollback"]
        )
    }

    func testNetworkRuleBlocksEveryHTTPAndWebSocketScheme() throws {
        let data = try XCTUnwrap(WebCapsuleNetworkRulePolicy.source.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rules.count, 4)
        let filters = try rules.map { rule -> String in
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            XCTAssertNil(trigger["unless-domain"])
            XCTAssertEqual((rule["action"] as? [String: String])?["type"], "block")
            return try XCTUnwrap(trigger["url-filter"] as? String)
        }
        XCTAssertEqual(filters, ["^http://", "^https://", "^ws://", "^wss://"])
    }

    func testNavigationAllowsOnlyExactPinnedEntryAndSameDocumentFragment() throws {
        let entry = try XCTUnwrap(URL(string: "webcapsule://com.example.fixture/1.0.0/index.html"))
        XCTAssertTrue(WebCapsuleNavigationPolicy.allowsTopLevelNavigation(candidate: entry, entryURL: entry))
        XCTAssertTrue(WebCapsuleNavigationPolicy.allowsTopLevelNavigation(
            candidate: URL(string: entry.absoluteString + "#section"), entryURL: entry
        ))
        for denied in [
            "webcapsule://com.example.fixture/1.0.0/other.html",
            "webcapsule://com.example.fixture/2.0.0/index.html",
            "webcapsule://other.example/1.0.0/index.html",
            "webcapsule://com.example.fixture/1.0.0/index.html?query=1",
            "https://example.invalid/", "file:///tmp/index.html", "data:text/html,x", "javascript:alert(1)",
        ] {
            XCTAssertFalse(WebCapsuleNavigationPolicy.allowsTopLevelNavigation(
                candidate: URL(string: denied), entryURL: entry
            ), denied)
        }
    }

    func testSubframesRemainInsidePinnedCapsuleAndVersion() {
        XCTAssertTrue(WebCapsuleNavigationPolicy.allowsPinnedSubframeNavigation(
            candidate: URL(string: "webcapsule://com.example.fixture/1.0.0/frame.html"),
            capsuleId: "com.example.fixture", version: "1.0.0"
        ))
        for denied in [
            "webcapsule://com.example.fixture/2.0.0/frame.html",
            "webcapsule://other.example/1.0.0/frame.html",
            "https://example.invalid/frame.html", "file:///tmp/frame.html",
        ] {
            XCTAssertFalse(WebCapsuleNavigationPolicy.allowsPinnedSubframeNavigation(
                candidate: URL(string: denied), capsuleId: "com.example.fixture", version: "1.0.0"
            ))
        }
    }

    func testFactoryCompilesNetworkRulesBeforeCreatingRestrictedPinnedWebView() throws {
        let installed = try installedEntry()
        let configured = expectation(description: "configured")
        SecureWebCapsuleWebViewFactory.make(
            frame: .zero,
            storageRootURL: installed.root,
            session: installed.session
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            switch result {
            case let .failure(error): XCTFail("unexpected configuration failure: \(error)")
            case let .success(made):
                XCTAssertTrue(made.webView.configuration.urlSchemeHandler(
                    forURLScheme: PinnedResourceResolver.scheme
                ) === made.handler)
                XCTAssertFalse(made.webView.configuration.websiteDataStore.isPersistent)
                XCTAssertTrue(made.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
                XCTAssertFalse(made.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
                XCTAssertFalse(made.webView.configuration.allowsAirPlayForMediaPlayback)
                XCTAssertEqual(made.webView.configuration.mediaTypesRequiringUserActionForPlayback, .all)
                XCTAssertFalse(made.webView.allowsBackForwardNavigationGestures)
                XCTAssertFalse(made.webView.allowsLinkPreview)
                XCTAssertEqual(made.handler.entryURL.absoluteString,
                               "webcapsule://com.example.fixture/1.0.0/index.html")
                made.handler.invalidate()
            }
            configured.fulfill()
        }
        wait(for: [configured], timeout: 10)
    }

    func testReadyBridgeInstallsMainFrameDocumentStartScriptAndRejectsNativeObjects() throws {
        let installed = try installedEntry()
        let controller = WKUserContentController()
        let received = LockedValue<[(String, ReadyMessageSource)]>([])
        let bridge = WebCapsuleReadyBridge(
            controller: controller,
            session: installed.session
        ) { body, source in
            received.mutate { $0.append((body, source)) }
        }
        XCTAssertEqual(controller.userScripts.count, 1)
        let script = try XCTUnwrap(controller.userScripts.first)
        XCTAssertEqual(script.injectionTime, .atDocumentStart)
        XCTAssertTrue(script.isForMainFrameOnly)
        XCTAssertEqual(
            script.source,
            WebCapsuleReadyBridgeContract.bootstrapScript(session: installed.session)
        )

        let source = ReadyMessageSource(
            isMainFrame: true,
            scheme: "webcapsule",
            host: installed.session.capsuleId,
            port: 0,
            documentURL: URL(string: "webcapsule://com.example.fixture/1.0.0/index.html")
        )
        bridge.receive(body: ["type": "ready"], source: source)
        XCTAssertEqual(received.get().map(\.0), [""])
        bridge.receive(body: "{\"type\":\"ready\"}", source: source)
        XCTAssertEqual(received.get().map(\.0), ["", "{\"type\":\"ready\"}"])

        bridge.invalidate()
        XCTAssertTrue(controller.userScripts.isEmpty)
        bridge.receive(body: "late", source: source)
        XCTAssertEqual(received.get().map(\.0), ["", "{\"type\":\"ready\"}"])
    }

    func testFactoryHealthBridgeUsesExactSessionAndSecureTeardown() throws {
        let installed = try installedEntry()
        let configured = expectation(description: "configured health bridge")
        let messages = LockedValue<[String]>([])
        SecureWebCapsuleWebViewFactory.makeWithHealth(
            frame: .zero,
            storageRootURL: installed.root,
            session: installed.session,
            receiveReady: { body, _ in messages.mutate { $0.append(body) } },
            fatalObserver: { _ in }
        ) { result in
            switch result {
            case let .failure(error):
                XCTFail("unexpected configuration failure: \(error)")
            case let .success(made):
                XCTAssertEqual(made.webView.configuration.userContentController.userScripts.count, 1)
                XCTAssertTrue(made.webView.configuration.userContentController.userScripts[0].isForMainFrameOnly)
                made.readyBridge.receive(body: "ready", source: ReadyMessageSource(
                    isMainFrame: true,
                    scheme: "webcapsule",
                    host: installed.session.capsuleId,
                    port: 0,
                    documentURL: made.handler.entryURL
                ))
                XCTAssertEqual(messages.get(), ["ready"])
                made.invalidate()
                made.readyBridge.receive(body: "late", source: ReadyMessageSource(
                    isMainFrame: true,
                    scheme: "webcapsule",
                    host: installed.session.capsuleId,
                    port: 0,
                    documentURL: made.handler.entryURL
                ))
                XCTAssertEqual(messages.get(), ["ready"])
            }
            configured.fulfill()
        }
        wait(for: [configured], timeout: 10)
    }

    func testFactoryRuleCompilationFailureReturnsStableErrorWithoutWebView() throws {
        let installed = try installedEntry()
        let failed = expectation(description: "failed")
        SecureWebCapsuleWebViewFactory.make(
            frame: .zero,
            storageRootURL: installed.root,
            session: installed.session,
            compiler: FailingRuleCompiler()
        ) { result in
            switch result {
            case .success: XCTFail("WebView must not be created when network rules fail")
            case let .failure(error): XCTAssertEqual(error.code, .storageIOFailed)
            }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5)
    }

    func testDelegateFailureIsStableEntryLoadFailedAndEmittedOnce() throws {
        let entry = try XCTUnwrap(URL(string: "webcapsule://com.example.fixture/1.0.0/index.html"))
        let delegate = WebCapsuleWebViewDelegate(
            entryURL: entry, capsuleId: "com.example.fixture", version: "1.0.0"
        )
        var errors: [WebCapsuleError] = []
        delegate.didFailEntry = { errors.append($0) }
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        delegate.webView(webView, didFailProvisionalNavigation: nil, withError: CocoaError(.fileReadUnknown))
        delegate.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(errors, [WebCapsuleError(code: .entryLoadFailed, message: "Pinned entry failed to load")])
    }

    private func installedEntry() throws -> (root: URL, session: SessionDescriptor) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webcapsule-secure-view-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        temporaryDirectories.append(root)
        _ = try CapsuleInstaller(storageRootURL: root)
        let data = Data("entry".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let shard = root.appendingPathComponent("blobs/sha256/\(digest.prefix(2))", isDirectory: true)
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: false)
        let blob = shard.appendingPathComponent(digest)
        try data.write(to: blob)
        XCTAssertEqual(Darwin.chmod(blob.path, 0o444), 0)
        let file = SessionFile(
            path: "index.html",
            sha256: digest,
            size: Int64(data.count),
            mediaType: "text/html"
        )
        return (root, SessionDescriptor(
            sessionId: "secure-view",
            capsuleId: "com.example.fixture",
            version: "1.0.0",
            entry: file.path,
            recordSHA256: String(repeating: "b", count: 64),
            registryGeneration: 0,
            createdMonotonicNanoseconds: 1,
            files: [file.path: file],
            trialVersion: nil,
            trialAttempt: nil
        ))
    }
}

private final class FailingRuleCompiler: WebCapsuleContentRuleCompiling {
    func compile(
        identifier: String,
        source: String,
        completion: @escaping (Result<WKContentRuleList, Error>) -> Void
    ) {
        completion(.failure(WebCapsuleError(
            code: .storageIOFailed,
            message: "Network rule compilation failed"
        )))
    }
}
#endif
