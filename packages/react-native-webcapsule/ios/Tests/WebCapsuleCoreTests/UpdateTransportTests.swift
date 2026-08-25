import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import WebCapsuleCore

final class UpdateTransportTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        StubURLProtocol.handler = nil
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testIndexUsesExactNetworkProfileAndAcceptsMatchingLength() throws {
        let body = Data("{}".utf8)
        StubURLProtocol.handler = { request, loader in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            loader.respond(status: 200, headers: ["Content-Length": "2"], body: body)
        }
        XCTAssertEqual(try transport().fetchIndex(indexURL), body)
    }

    func testIndexRejectsStatusLengthMismatchAndSizeLimit() throws {
        StubURLProtocol.handler = { _, loader in
            loader.respond(status: 302, headers: [:], body: Data())
        }
        assertError(.httpStatusInvalid) { try self.transport().fetchIndex(self.indexURL) }

        StubURLProtocol.handler = { _, loader in
            loader.respond(status: 200, headers: ["Content-Length": "3"], body: Data("{}".utf8))
        }
        assertError(.contentLengthMismatch) { try self.transport().fetchIndex(self.indexURL) }

        StubURLProtocol.handler = { _, loader in
            loader.respond(
                status: 200,
                headers: [:],
                body: Data(repeating: 0x20, count: 1024 * 1024 + 1)
            )
        }
        assertError(.limitExceeded) { try self.transport().fetchIndex(self.indexURL) }
    }

    func testCapsuleVerifiesDescriptorSizeAndHashAndCleansFailures() throws {
        let base = try temporaryDirectory()
        let body = Data("capsule".utf8)
        StubURLProtocol.handler = { _, loader in
            loader.respond(
                status: 200,
                headers: ["Content-Length": String(body.count)],
                body: body
            )
        }
        let downloaded = try transport().fetchCapsule(release(body), trustedCacheBaseURL: base)
        XCTAssertEqual(try Data(contentsOf: downloaded.fileURL), body)
        downloaded.cleanup()
        try assertNoOperations(in: base)

        StubURLProtocol.handler = { _, loader in
            loader.respond(status: 200, headers: [:], body: body)
        }
        assertError(.hashMismatch) {
            try self.transport().fetchCapsule(
                self.release(body, sha256: String(repeating: "0", count: 64)),
                trustedCacheBaseURL: base
            )
        }
        try assertNoOperations(in: base)

        StubURLProtocol.handler = { _, loader in
            loader.respond(status: 200, headers: ["Content-Length": "1"], body: body)
        }
        assertError(.contentLengthMismatch) {
            try self.transport().fetchCapsule(self.release(body), trustedCacheBaseURL: base)
        }
        try assertNoOperations(in: base)
    }

    func testNetworkFailuresMapSeparately() throws {
        StubURLProtocol.handler = { _, loader in loader.fail(URLError(.timedOut)) }
        assertError(.networkTimeout) { try self.transport().fetchIndex(self.indexURL) }

        StubURLProtocol.handler = { _, loader in loader.fail(URLError(.cannotConnectToHost)) }
        assertError(.networkFailed) { try self.transport().fetchIndex(self.indexURL) }
    }

    func testAncestorNamespaceSymlinkIsRejected() throws {
        let base = try temporaryDirectory()
        let target = try temporaryDirectory()
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("webcapsule-update"),
            withDestinationURL: target
        )
        let body = Data("capsule".utf8)
        StubURLProtocol.handler = { _, loader in
            loader.respond(status: 200, headers: [:], body: body)
        }
        assertError(.unsafeStorageLayout) {
            try self.transport().fetchCapsule(self.release(body), trustedCacheBaseURL: base)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testRootSwapRaceCleansPinnedOperationWithoutDeletingReplacement() throws {
        let base = try temporaryDirectory()
        let displaced = base.appendingPathComponent("displaced", isDirectory: true)
        let replacementSentinel = Data("replacement".utf8)
        var operationName: String?
        let body = Data("capsule".utf8)
        StubURLProtocol.handler = { _, loader in
            loader.respond(status: 200, headers: [:], body: body)
        }
        let transport = self.transport { point in
            guard point == .afterOperationDirectoryOpened else { return }
            let originalRoot = base.appendingPathComponent("webcapsule-update/v1", isDirectory: true)
            operationName = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(atPath: originalRoot.path).first
            )
            try FileManager.default.moveItem(
                at: base.appendingPathComponent("webcapsule-update"),
                to: displaced
            )
            let replacementOperation = originalRoot.appendingPathComponent(operationName!, isDirectory: true)
            try FileManager.default.createDirectory(
                at: replacementOperation,
                withIntermediateDirectories: true
            )
            try replacementSentinel.write(to: replacementOperation.appendingPathComponent("download.capsule"))
        }

        assertError(.unsafeStorageLayout) {
            try transport.fetchCapsule(self.release(body), trustedCacheBaseURL: base)
        }
        let name = try XCTUnwrap(operationName)
        XCTAssertEqual(
            try Data(contentsOf: base.appendingPathComponent("webcapsule-update/v1/\(name)/download.capsule")),
            replacementSentinel
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: displaced.appendingPathComponent("v1").path
            ).isEmpty
        )
    }

    func testWatchdogUsesTenSecondResponseAndThirtySecondReadIdleContract() {
        XCTAssertEqual(UpdateTimeoutIntervals.production.responseStart, 10)
        XCTAssertEqual(UpdateTimeoutIntervals.production.readIdle, 30)
    }

    func testResponseStartWatchdogTimesOutWithoutResponse() throws {
        StubURLProtocol.handler = { _, _ in }
        assertError(.networkTimeout) {
            try self.transport(
                timeoutIntervals: UpdateTimeoutIntervals(responseStart: 0.05, readIdle: 0.2)
            ).fetchIndex(self.indexURL)
        }
    }

    func testReadIdleWatchdogTimesOutAfterPartialResponse() throws {
        StubURLProtocol.handler = { _, loader in
            loader.sendResponse(status: 200, headers: ["Content-Length": "2"])
            loader.sendData(Data("a".utf8))
        }
        assertError(.networkTimeout) {
            try self.transport(
                timeoutIntervals: UpdateTimeoutIntervals(responseStart: 0.2, readIdle: 0.05)
            ).fetchIndex(self.indexURL)
        }
    }

    func testProgressResetsReadIdleWatchdogBeyondOneIdleInterval() throws {
        StubURLProtocol.handler = { _, loader in
            loader.sendResponse(status: 200, headers: ["Content-Length": "3"])
            for (delay, byte) in [(0.04, "a"), (0.08, "b"), (0.12, "c")] {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    loader.sendData(Data(byte.utf8))
                    if byte == "c" { loader.finish() }
                }
            }
        }

        XCTAssertEqual(
            try transport(
                timeoutIntervals: UpdateTimeoutIntervals(responseStart: 0.2, readIdle: 0.06)
            ).fetchIndex(indexURL),
            Data("abc".utf8)
        )
    }

    private var indexURL: URL { URL(string: "https://example.com/index.json")! }

    private func transport(
        timeoutIntervals: UpdateTimeoutIntervals = .production,
        faultInjector: @escaping UpdateTransportFaultInjector = { _ in }
    ) -> HTTPSUpdateTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return HTTPSUpdateTransport(
            sessionConfiguration: configuration,
            timeoutIntervals: timeoutIntervals,
            faultInjector: faultInjector
        )
    }

    private func transport(
        faultInjector: @escaping UpdateTransportFaultInjector
    ) -> HTTPSUpdateTransport {
        transport(timeoutIntervals: .production, faultInjector: faultInjector)
    }

    private func release(_ body: Data, sha256: String? = nil) -> UpdateRelease {
        UpdateRelease(
            version: "2.0.0",
            url: URL(string: "https://example.com/v2.capsule")!,
            sha256: sha256 ?? SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
            size: Int64(body.count),
            minimumRuntimeVersion: "1.0.0"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("webcapsule-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }

    private func assertNoOperations(in base: URL) throws {
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: base.appendingPathComponent("webcapsule-update/v1").path
            ).isEmpty
        )
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

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, StubURLProtocol) throws -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            try handler(request, self)
        } catch {
            fail(error)
        }
    }

    override func stopLoading() {}

    func respond(status: Int, headers: [String: String], body: Data) {
        sendResponse(status: status, headers: headers)
        if !body.isEmpty { sendData(body) }
        finish()
    }

    func sendResponse(status: Int, headers: [String: String]) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func sendData(_ data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }

    func finish() {
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}
