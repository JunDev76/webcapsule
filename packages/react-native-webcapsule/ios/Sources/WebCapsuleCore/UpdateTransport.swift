import CryptoKit
import Darwin
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DownloadedCapsule: @unchecked Sendable {
    let fileURL: URL
    let operationDirectoryURL: URL
    private let cleanupAction: @Sendable () -> Void

    init(
        fileURL: URL,
        operationDirectoryURL: URL,
        cleanupAction: @escaping @Sendable () -> Void
    ) {
        self.fileURL = fileURL
        self.operationDirectoryURL = operationDirectoryURL
        self.cleanupAction = cleanupAction
    }

    func cleanup() {
        cleanupAction()
    }
}

protocol UpdateTransport: Sendable {
    func fetchIndex(_ url: URL) throws -> Data
    func fetchCapsule(_ release: UpdateRelease, trustedCacheBaseURL: URL) throws -> DownloadedCapsule
}

struct UpdateTimeoutIntervals: Sendable {
    let responseStart: TimeInterval
    let readIdle: TimeInterval

    static let production = UpdateTimeoutIntervals(responseStart: 10, readIdle: 30)
}

protocol UpdateWatchdogToken: AnyObject, Sendable {
    func cancel()
}

protocol UpdateWatchdogScheduling: Sendable {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> UpdateWatchdogToken
}

private final class DispatchUpdateWatchdogToken: UpdateWatchdogToken, @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

private struct DispatchUpdateWatchdogScheduler: UpdateWatchdogScheduling {
    private let queue = DispatchQueue(label: "dev.webcapsule.update-watchdog")

    func schedule(
        after interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> UpdateWatchdogToken {
        let workItem = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + interval, execute: workItem)
        return DispatchUpdateWatchdogToken(workItem: workItem)
    }
}

enum UpdateTransportFaultPoint {
    case afterNamespaceOpened
    case afterOperationDirectoryOpened
}

typealias UpdateTransportFaultInjector = (UpdateTransportFaultPoint) throws -> Void

final class HTTPSUpdateTransport: UpdateTransport, @unchecked Sendable {
    private static let indexLimit: Int64 = 1024 * 1024
    private static let capsuleLimit: Int64 = 100 * 1024 * 1024
    private let sessionConfiguration: URLSessionConfiguration
    private let timeoutIntervals: UpdateTimeoutIntervals
    private let watchdogScheduler: UpdateWatchdogScheduling
    private let faultInjector: UpdateTransportFaultInjector

    init(
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        timeoutIntervals: UpdateTimeoutIntervals = .production,
        watchdogScheduler: UpdateWatchdogScheduling = DispatchUpdateWatchdogScheduler(),
        faultInjector: @escaping UpdateTransportFaultInjector = { _ in }
    ) {
        precondition(timeoutIntervals.responseStart > 0 && timeoutIntervals.readIdle > 0)
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        self.sessionConfiguration = configuration
        self.timeoutIntervals = timeoutIntervals
        self.watchdogScheduler = watchdogScheduler
        self.faultInjector = faultInjector
    }

    func fetchIndex(_ url: URL) throws -> Data {
        _ = try UpdateIndexVerifier.strictHTTPS(url.absoluteString)
        return try perform(
            url: url,
            limit: Self.indexLimit,
            expectedLength: nil,
            destinationFile: nil
        ).data!
    }

    func fetchCapsule(_ release: UpdateRelease, trustedCacheBaseURL: URL) throws -> DownloadedCapsule {
        guard release.size <= Self.capsuleLimit else {
            throw WebCapsuleError(code: .limitExceeded, message: "Release size exceeds capsule limit")
        }
        let namespace = try UpdateTemporaryNamespace(trustedCacheBaseURL: trustedCacheBaseURL)
        try faultInjector(.afterNamespaceOpened)
        let operation = try namespace.createOperation()
        do {
            try faultInjector(.afterOperationDirectoryOpened)
            let destination = try operation.createDownloadFile()
            let result = try perform(
                url: release.url,
                limit: min(release.size, Self.capsuleLimit),
                expectedLength: release.size,
                destinationFile: destination
            )
            guard result.sha256 == release.sha256 else {
                throw WebCapsuleError(code: .hashMismatch, message: "Downloaded capsule SHA-256 differs")
            }
            guard operation.isReachableAtOriginalURL() else {
                throw WebCapsuleError(code: .unsafeStorageLayout, message: "Update temporary root identity changed")
            }
            return DownloadedCapsule(
                fileURL: operation.fileURL,
                operationDirectoryURL: operation.url,
                cleanupAction: { operation.cleanup() }
            )
        } catch {
            operation.cleanup()
            throw error
        }
    }

    private func perform(
        url: URL,
        limit: Int64,
        expectedLength: Int64?,
        destinationFile: UpdateDestinationFile?
    ) throws -> UpdateResponseResult {
        _ = try UpdateIndexVerifier.strictHTTPS(url.absoluteString)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let receiver = UpdateResponseReceiver(
            limit: limit,
            expectedLength: expectedLength,
            destinationFile: destinationFile,
            timeoutIntervals: timeoutIntervals,
            watchdogScheduler: watchdogScheduler
        )
        let session = URLSession(configuration: sessionConfiguration, delegate: receiver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        receiver.startWatchdog(for: task)
        task.resume()
        return try receiver.wait()
    }
}

private final class UpdateTemporaryNamespace {
    private let cacheBase: StorageDirectory
    private let updateNamespace: StorageDirectory
    private let root: StorageDirectory

    init(trustedCacheBaseURL: URL) throws {
        guard trustedCacheBaseURL.isFileURL else {
            throw WebCapsuleError(code: .invalidArgument, message: "Caches base must be a file URL")
        }
        cacheBase = try StorageDirectory.openExistingRoot(trustedCacheBaseURL)
        updateNamespace = try cacheBase.openOrCreateDirectory("webcapsule-update")
        root = try updateNamespace.openOrCreateDirectory("v1")
    }

    func createOperation() throws -> UpdateTemporaryOperation {
        for _ in 0..<16 {
            let name = UUID().uuidString.lowercased()
            if Darwin.mkdirat(root.descriptor, name, S_IRWXU) == 0 {
                do {
                    return try UpdateTemporaryOperation(namespace: self, root: root, name: name)
                } catch {
                    _ = Darwin.unlinkat(root.descriptor, name, AT_REMOVEDIR)
                    throw error
                }
            }
            if errno != EEXIST {
                throw WebCapsuleError(code: .storageIOFailed, message: "Update operation directory cannot be created")
            }
        }
        throw WebCapsuleError(code: .storageIOFailed, message: "Unique update operation directory cannot be created")
    }

    func isReachableAtOriginalURL() -> Bool {
        cacheBase.isReachableAtOriginalURL()
            && cacheBase.childMatches("webcapsule-update", identity: updateNamespace.identity)
            && updateNamespace.childMatches("v1", identity: root.identity)
    }
}

private final class UpdateTemporaryOperation: @unchecked Sendable {
    let url: URL
    let fileURL: URL

    private let namespace: UpdateTemporaryNamespace
    private let root: StorageDirectory
    private let name: String
    private let identity: StrictZipFileIdentity
    private let descriptor: Int32
    private let cleanupLock = NSLock()
    private var fileIdentity: StrictZipFileIdentity?
    private var cleaned = false

    init(namespace: UpdateTemporaryNamespace, root: StorageDirectory, name: String) throws {
        let descriptor = Darwin.openat(
            root.descriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw WebCapsuleError(code: .storageIOFailed, message: "Update operation directory cannot be opened")
        }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_uid == Darwin.geteuid(),
              attributes.st_mode & 0o777 == S_IRWXU,
              root.childMatches(
                  name,
                  identity: StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
              ) else {
            Darwin.close(descriptor)
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Update operation directory is unsafe")
        }
        self.namespace = namespace
        self.root = root
        self.name = name
        identity = StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
        self.descriptor = descriptor
        url = root.url.appendingPathComponent(name, isDirectory: true)
        fileURL = url.appendingPathComponent("download.capsule", isDirectory: false)
    }

    deinit {
        Darwin.close(descriptor)
    }

    func createDownloadFile() throws -> UpdateDestinationFile {
        let fileDescriptor = Darwin.openat(
            descriptor,
            "download.capsule",
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw WebCapsuleError(code: .storageIOFailed, message: "Download file cannot be created")
        }
        var attributes = stat()
        guard Darwin.fstat(fileDescriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == Darwin.geteuid(),
              attributes.st_nlink == 1,
              attributes.st_mode & 0o777 == S_IRUSR | S_IWUSR else {
            Darwin.close(fileDescriptor)
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Download file is unsafe")
        }
        let identity = StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
        var current = stat()
        guard Darwin.fstatat(descriptor, "download.capsule", &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == identity.device,
              current.st_ino == identity.inode else {
            Darwin.close(fileDescriptor)
            removeDownloadFileIfOwned(identity)
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Download file was substituted while opening")
        }
        fileIdentity = identity
        return UpdateDestinationFile(
            handle: FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        )
    }

    func isReachableAtOriginalURL() -> Bool {
        guard namespace.isReachableAtOriginalURL(), root.childMatches(name, identity: identity),
              let fileIdentity else { return false }
        var current = stat()
        return Darwin.fstatat(descriptor, "download.capsule", &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_mode & S_IFMT == S_IFREG
            && current.st_dev == fileIdentity.device
            && current.st_ino == fileIdentity.inode
    }

    func cleanup() {
        cleanupLock.lock()
        guard !cleaned else {
            cleanupLock.unlock()
            return
        }
        cleaned = true
        let createdFile = fileIdentity
        cleanupLock.unlock()

        if let createdFile {
            removeDownloadFileIfOwned(createdFile)
        }
        root.removeEmptyDirectoryIfOwned(name, identity: identity)
    }

    private func removeDownloadFileIfOwned(_ identity: StrictZipFileIdentity) {
        var current = stat()
        guard Darwin.fstatat(descriptor, "download.capsule", &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == identity.device,
              current.st_ino == identity.inode else { return }
        _ = Darwin.unlinkat(descriptor, "download.capsule", 0)
    }
}

private struct UpdateDestinationFile {
    let handle: FileHandle
}

private struct UpdateResponseResult {
    let data: Data?
    let sha256: String?
}

private final class UpdateResponseReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let condition = NSCondition()
    private let limit: Int64
    private let expectedLength: Int64?
    private let timeoutIntervals: UpdateTimeoutIntervals
    private let watchdogScheduler: UpdateWatchdogScheduling
    private var memory = Data()
    private var fileHandle: FileHandle?
    private var hasher = SHA256()
    private var observed: Int64 = 0
    private var declaredLength: Int64?
    private var completed = false
    private var result: Result<UpdateResponseResult, Error>?
    private var responseAccepted = false
    private weak var task: URLSessionTask?
    private var watchdog: UpdateWatchdogToken?

    init(
        limit: Int64,
        expectedLength: Int64?,
        destinationFile: UpdateDestinationFile?,
        timeoutIntervals: UpdateTimeoutIntervals,
        watchdogScheduler: UpdateWatchdogScheduling
    ) {
        self.limit = limit
        self.expectedLength = expectedLength
        fileHandle = destinationFile?.handle
        self.timeoutIntervals = timeoutIntervals
        self.watchdogScheduler = watchdogScheduler
    }

    func startWatchdog(for task: URLSessionTask) {
        condition.lock()
        guard !completed else {
            condition.unlock()
            return
        }
        self.task = task
        replaceWatchdog(after: timeoutIntervals.responseStart)
        condition.unlock()
    }

    func wait() throws -> UpdateResponseResult {
        condition.lock()
        while !completed { condition.wait() }
        let outcome = result
        condition.unlock()
        guard let outcome else {
            throw WebCapsuleError(code: .networkFailed, message: "HTTP request ended without a result")
        }
        return try outcome.get()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let response = response as? HTTPURLResponse else {
                throw WebCapsuleError(code: .networkFailed, message: "Response is not HTTP")
            }
            guard response.statusCode == 200 else {
                throw WebCapsuleError(code: .httpStatusInvalid, message: "HTTP status must be 200")
            }
            let declared = try contentLength(response)
            if let expectedLength {
                if let declared, declared != expectedLength {
                    throw WebCapsuleError(code: .contentLengthMismatch, message: "Capsule Content-Length differs")
                }
            } else if let declared, declared > limit {
                throw WebCapsuleError(code: .limitExceeded, message: "Update index exceeds 1 MiB")
            }
            condition.lock()
            guard !completed else {
                condition.unlock()
                completionHandler(.cancel)
                return
            }
            declaredLength = declared
            responseAccepted = true
            replaceWatchdog(after: timeoutIntervals.readIdle)
            condition.unlock()
            completionHandler(.allow)
        } catch {
            complete(.failure(error))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        guard responseAccepted, !completed else {
            condition.unlock()
            return
        }
        do {
            let (next, overflow) = observed.addingReportingOverflow(Int64(data.count))
            guard !overflow, next <= limit else {
                throw WebCapsuleError(code: .limitExceeded, message: "Response exceeds its byte limit")
            }
            if let fileHandle {
                try fileHandle.write(contentsOf: data)
                hasher.update(data: data)
            } else {
                memory.append(data)
            }
            observed = next
            replaceWatchdog(after: timeoutIntervals.readIdle)
            condition.unlock()
        } catch {
            condition.unlock()
            dataTask.cancel()
            complete(.failure(normalizeWriteError(error)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        guard !completed else {
            condition.unlock()
            return
        }
        if let error {
            finishLocked(.failure(mapNetworkError(error)))
            return
        }
        guard responseAccepted else {
            finishLocked(.failure(WebCapsuleError(code: .networkFailed, message: "HTTP response was not accepted")))
            return
        }
        if let expectedLength, observed != expectedLength {
            finishLocked(.failure(WebCapsuleError(code: .contentLengthMismatch, message: "Capsule byte size differs")))
            return
        }
        if expectedLength == nil, let declaredLength, observed != declaredLength {
            finishLocked(.failure(WebCapsuleError(code: .contentLengthMismatch, message: "Update index Content-Length differs")))
            return
        }
        do {
            try fileHandle?.synchronize()
            try fileHandle?.close()
            fileHandle = nil
            let digest = expectedLength == nil
                ? nil
                : hasher.finalize().map { String(format: "%02x", $0) }.joined()
            finishLocked(.success(UpdateResponseResult(data: expectedLength == nil ? memory : nil, sha256: digest)))
        } catch {
            finishLocked(.failure(WebCapsuleError(code: .storageIOFailed, message: "Download file cannot be synced")))
        }
    }

    private func replaceWatchdog(after interval: TimeInterval) {
        watchdog?.cancel()
        watchdog = watchdogScheduler.schedule(after: interval) { [weak self] in
            self?.watchdogFired()
        }
    }

    private func watchdogFired() {
        let timedOutTask: URLSessionTask?
        condition.lock()
        guard !completed else {
            condition.unlock()
            return
        }
        timedOutTask = task
        finishLocked(.failure(WebCapsuleError(code: .networkTimeout, message: "HTTP request timed out")))
        timedOutTask?.cancel()
    }

    private func contentLength(_ response: HTTPURLResponse) throws -> Int64? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Length") else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.contains(","), let parsed = Int64(value), parsed >= 0 else {
            throw WebCapsuleError(code: .contentLengthMismatch, message: "Invalid or multiple Content-Length")
        }
        return parsed
    }

    private func complete(_ outcome: Result<UpdateResponseResult, Error>) {
        condition.lock()
        guard !completed else {
            condition.unlock()
            return
        }
        finishLocked(outcome)
    }

    private func finishLocked(_ outcome: Result<UpdateResponseResult, Error>) {
        watchdog?.cancel()
        watchdog = nil
        completed = true
        result = outcome
        try? fileHandle?.close()
        fileHandle = nil
        condition.broadcast()
        condition.unlock()
    }

    private func normalizeWriteError(_ error: Error) -> Error {
        if let error = error as? WebCapsuleError { return error }
        return WebCapsuleError(code: .storageIOFailed, message: "Download file cannot be written")
    }

    private func mapNetworkError(_ error: Error) -> Error {
        if let error = error as? WebCapsuleError { return error }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return WebCapsuleError(code: .networkTimeout, message: "HTTP request timed out")
        }
        return WebCapsuleError(code: .networkFailed, message: "HTTP request failed")
    }
}
