import CryptoKit
import Darwin
import Foundation

public struct CapsuleVerificationRequest: Equatable, Sendable {
    public let expectedCapsuleId: String
    public let runtimeVersion: String
    public let publicKeys: [String: String]

    public init(expectedCapsuleId: String, runtimeVersion: String, publicKeys: [String: String]) {
        self.expectedCapsuleId = expectedCapsuleId
        self.runtimeVersion = runtimeVersion
        self.publicKeys = publicKeys
    }

    fileprivate var manifestRequest: ManifestVerificationRequest {
        ManifestVerificationRequest(
            expectedCapsuleId: expectedCapsuleId,
            runtimeVersion: runtimeVersion,
            publicKeys: publicKeys
        )
    }
}

public struct CapsuleVerificationLimits: Equatable, Sendable {
    public static let v1 = CapsuleVerificationLimits()

    public let archiveBytes: UInt64
    public let manifestBytes: UInt64
    public let signatureBytes: UInt64
    public let contentBytes: UInt64
    public let fileBytes: UInt64
    public let fileCount: Int

    public init(
        archiveBytes: UInt64 = 100 * 1024 * 1024,
        manifestBytes: UInt64 = 5 * 1024 * 1024,
        signatureBytes: UInt64 = 89,
        contentBytes: UInt64 = 250 * 1024 * 1024,
        fileBytes: UInt64 = 50 * 1024 * 1024,
        fileCount: Int = 10_000
    ) {
        self.archiveBytes = archiveBytes
        self.manifestBytes = manifestBytes
        self.signatureBytes = signatureBytes
        self.contentBytes = contentBytes
        self.fileBytes = fileBytes
        self.fileCount = fileCount
    }
}

public struct VerifiedCapsuleFile: Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let size: Int64
    public let mediaType: String
    let stagedURL: URL

    init(path: String, sha256: String, size: Int64, mediaType: String, stagedURL: URL) {
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.mediaType = mediaType
        self.stagedURL = stagedURL
    }
}

/// A transient, fully verified capsule. This is not a durable installation.
/// It is a single-consumption capability: `CapsuleInstaller` consumes it and
/// safely removes only verifier-owned staging inodes. Abandoned instances clean
/// their staging when deallocated.
public final class VerifiedCapsule: @unchecked Sendable {
    public let manifest: CapsuleManifest
    public let canonicalManifest: Data
    public let manifestSHA256: String
    public let files: [VerifiedCapsuleFile]
    let operationDirectory: URL

    private let ownership: VerifiedCapsuleOwnership

    fileprivate init(
        manifest: CapsuleManifest,
        canonicalManifest: Data,
        manifestSHA256: String,
        files: [VerifiedCapsuleFile],
        ownership: VerifiedCapsuleOwnership
    ) {
        self.manifest = manifest
        self.canonicalManifest = canonicalManifest
        self.manifestSHA256 = manifestSHA256
        self.files = files
        operationDirectory = ownership.operation.url
        self.ownership = ownership
    }

    func claimForInstall() throws -> OwnedOperationDirectory {
        try ownership.claim()
    }
}

private final class VerifiedCapsuleOwnership: @unchecked Sendable {
    let operation: OwnedOperationDirectory
    private let lock = NSLock()
    private var consumed = false

    init(operation: OwnedOperationDirectory) {
        self.operation = operation
    }

    func claim() throws -> OwnedOperationDirectory {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Verified capsule was already consumed")
        }
        consumed = true
        return operation
    }

    deinit {
        operation.cleanup()
    }
}

public final class CapsuleVerifier: Sendable {
    private let limits: CapsuleVerificationLimits

    public init(limits: CapsuleVerificationLimits = .v1) {
        self.limits = limits
    }

    public func verify(
        archiveURL: URL,
        stagingRootURL: URL,
        request: CapsuleVerificationRequest
    ) throws -> VerifiedCapsule {
        let manifestRequest = request.manifestRequest
        try SignedManifestVerifier.validate(manifestRequest)
        try validateLimits()
        try validateArchiveArgument(archiveURL)

        let stagingRoot = try ExistingDirectory(url: stagingRootURL)
        let operation = try stagingRoot.createOperation()
        var succeeded = false
        defer {
            if !succeeded {
                operation.cleanup()
            }
        }

        let reader = try StrictZipReader(
            archiveURL: archiveURL,
            archiveSizeLimit: limits.archiveBytes,
            entryCountLimit: limits.fileCount + 2
        )
        let entries = reader.entries
        guard entries.count >= 2, entries.count <= limits.fileCount + 2 else {
            throw WebCapsuleError(code: .limitExceeded, message: "Capsule entry count exceeds its limit")
        }

        let manifestData = try reader.extractData(entries[0], maximumSize: limits.manifestBytes)
        let signatureData = try reader.extractData(entries[1], maximumSize: limits.signatureBytes)
        let signed = try SignedManifestVerifier.verifyValidated(
            manifestData: manifestData,
            signatureData: signatureData,
            request: manifestRequest
        )
        let manifest = signed.manifest

        guard manifest.files.count <= limits.fileCount,
              entries.count == manifest.files.count + 2 else {
            throw WebCapsuleError(code: .invalidOrder, message: "Archive content set does not match manifest")
        }
        let expectedNames = ["capsule.json", "capsule.sig"] + manifest.files.map { "files/\($0.path)" }
        guard entries.map(\.name) == expectedNames else {
            throw WebCapsuleError(code: .invalidOrder, message: "Archive content set or order does not match manifest")
        }

        let timestamp = try DOSTimestamp(createdAt: manifest.createdAt)
        guard entries.allSatisfy({ $0.dosTime == timestamp.time && $0.dosDate == timestamp.date }) else {
            throw WebCapsuleError(code: .invalidTimestamp, message: "ZIP timestamp does not match manifest createdAt")
        }

        var declaredTotal: UInt64 = 0
        for (index, file) in manifest.files.enumerated() {
            let declared = UInt64(file.size)
            guard declared <= limits.fileBytes else {
                throw WebCapsuleError(code: .limitExceeded, message: "Manifest file exceeds verifier limit")
            }
            let (nextTotal, overflow) = declaredTotal.addingReportingOverflow(declared)
            guard !overflow, nextTotal <= limits.contentBytes else {
                throw WebCapsuleError(code: .limitExceeded, message: "Declared content exceeds verifier limit")
            }
            declaredTotal = nextTotal
            guard UInt64(entries[index + 2].uncompressedSize) == declared else {
                throw WebCapsuleError(code: .hashMismatch, message: "ZIP file size does not match manifest")
            }
        }

        var observedTotal: UInt64 = 0
        var verifiedFiles: [VerifiedCapsuleFile] = []
        verifiedFiles.reserveCapacity(manifest.files.count)
        for (index, file) in manifest.files.enumerated() {
            let physicalName = String(format: "%08x.blob", index)
            let aggregateRemaining = limits.contentBytes - observedTotal
            let observed = try reader.extract(
                entries[index + 2],
                toDirectoryDescriptor: operation.descriptor,
                fileName: physicalName,
                maximumSize: min(limits.fileBytes, aggregateRemaining)
            )
            guard let identity = observed.fileIdentity else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Extracted file identity is unavailable")
            }
            operation.recordCreatedFile(physicalName, identity: identity)
            let (nextTotal, overflow) = observedTotal.addingReportingOverflow(observed.size)
            guard !overflow, nextTotal <= limits.contentBytes else {
                throw WebCapsuleError(code: .limitExceeded, message: "Observed content exceeds verifier limit")
            }
            observedTotal = nextTotal
            guard observed.size == UInt64(file.size), observed.sha256 == file.sha256 else {
                throw WebCapsuleError(code: .hashMismatch, message: "Extracted file does not match manifest")
            }
            verifiedFiles.append(VerifiedCapsuleFile(
                path: file.path,
                sha256: file.sha256,
                size: file.size,
                mediaType: file.mediaType,
                stagedURL: operation.url.appendingPathComponent(physicalName, isDirectory: false)
            ))
        }

        guard operation.isReachableAtOriginalURL(), operation.containsOnlyRecordedRegularFiles() else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Operation staging was substituted")
        }
        let manifestDigest = SHA256.hash(data: signed.canonicalManifest)
            .map { String(format: "%02x", $0) }
            .joined()
        succeeded = true
        return VerifiedCapsule(
            manifest: manifest,
            canonicalManifest: signed.canonicalManifest,
            manifestSHA256: manifestDigest,
            files: verifiedFiles,
            ownership: VerifiedCapsuleOwnership(operation: operation)
        )
    }

    private func validateLimits() throws {
        let v1 = CapsuleVerificationLimits.v1
        guard limits.archiveBytes > 0, limits.archiveBytes <= v1.archiveBytes,
              limits.manifestBytes > 0, limits.manifestBytes <= v1.manifestBytes,
              limits.signatureBytes == v1.signatureBytes,
              limits.contentBytes > 0, limits.contentBytes <= v1.contentBytes,
              limits.fileBytes > 0, limits.fileBytes <= v1.fileBytes,
              limits.fileCount >= 0, limits.fileCount <= v1.fileCount else {
            throw WebCapsuleError(code: .invalidArgument, message: "Verification limits exceed the Capsule v1 profile")
        }
    }

    private func validateArchiveArgument(_ archiveURL: URL) throws {
        guard archiveURL.isFileURL else {
            throw WebCapsuleError(code: .invalidArgument, message: "Archive must be a file URL")
        }
        let descriptor = Darwin.open(archiveURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw WebCapsuleError(code: .archiveInvalid, message: "Capsule archive cannot be opened")
        }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 0 else {
            throw WebCapsuleError(code: .archiveInvalid, message: "Capsule archive must be a regular file")
        }
        guard UInt64(attributes.st_size) <= limits.archiveBytes else {
            throw WebCapsuleError(code: .limitExceeded, message: "Capsule archive exceeds its size limit")
        }
    }
}

struct DOSTimestamp {
    let time: UInt16
    let date: UInt16

    init(createdAt: String) throws {
        let bytes = Array(createdAt.utf8)
        func number(_ start: Int, _ length: Int) -> Int {
            bytes[start..<(start + length)].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        }
        guard bytes.count == 20 else {
            throw WebCapsuleError(code: .invalidTimestamp, message: "Manifest timestamp cannot be encoded as ZIP DOS time")
        }
        let year = number(0, 4)
        guard (1980...2107).contains(year) else {
            throw WebCapsuleError(code: .invalidTimestamp, message: "Manifest timestamp is outside ZIP DOS range")
        }
        let month = number(5, 2)
        let day = number(8, 2)
        let hour = number(11, 2)
        let minute = number(14, 2)
        let second = number(17, 2)
        time = UInt16((second >> 1) | (minute << 5) | (hour << 11))
        date = UInt16(day | (month << 5) | ((year - 1980) << 9))
    }
}

final class ExistingDirectory {
    let descriptor: Int32
    let url: URL
    let attributes: stat

    init(url: URL) throws {
        guard url.isFileURL else {
            throw WebCapsuleError(code: .invalidArgument, message: "Staging root must be a file URL")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Staging root must be an existing non-symlink directory")
        }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(descriptor)
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Staging root must be a directory")
        }
        self.descriptor = descriptor
        self.url = url.standardizedFileURL
        self.attributes = attributes
    }

    deinit {
        Darwin.close(descriptor)
    }

    func createOperation() throws -> OwnedOperationDirectory {
        for _ in 0..<16 {
            let name = UUID().uuidString.lowercased()
            if Darwin.mkdirat(descriptor, name, S_IRWXU) == 0 {
                return try OwnedOperationDirectory(root: self, name: name)
            }
            if errno != EEXIST {
                throw WebCapsuleError(code: .storageIOFailed, message: "Operation staging directory cannot be created")
            }
        }
        throw WebCapsuleError(code: .storageIOFailed, message: "Unique operation staging directory cannot be created")
    }
}

final class OwnedOperationDirectory {
    let descriptor: Int32
    let url: URL

    private let rootDescriptor: Int32
    private let rootURL: URL
    private let rootAttributes: stat
    private let name: String
    private let attributes: stat
    private var createdFiles: [(name: String, identity: StrictZipFileIdentity)] = []

    init(root: ExistingDirectory, name: String) throws {
        let descriptor = Darwin.openat(root.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            _ = Darwin.unlinkat(root.descriptor, name, AT_REMOVEDIR)
            throw WebCapsuleError(code: .storageIOFailed, message: "Operation staging directory cannot be opened")
        }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(descriptor)
            _ = Darwin.unlinkat(root.descriptor, name, AT_REMOVEDIR)
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Operation staging is not a directory")
        }
        self.descriptor = descriptor
        rootDescriptor = Darwin.dup(root.descriptor)
        guard rootDescriptor >= 0 else {
            Darwin.close(descriptor)
            _ = Darwin.unlinkat(root.descriptor, name, AT_REMOVEDIR)
            throw WebCapsuleError(code: .storageIOFailed, message: "Staging root descriptor cannot be retained")
        }
        rootURL = root.url
        rootAttributes = root.attributes
        self.name = name
        self.attributes = attributes
        url = root.url.appendingPathComponent(name, isDirectory: true)
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(rootDescriptor)
    }

    func recordCreatedFile(_ fileName: String, identity: StrictZipFileIdentity) {
        createdFiles.append((fileName, identity))
    }

    func isRecordedRegularFile(_ fileName: String, attributes: stat) -> Bool {
        createdFiles.contains {
            $0.name == fileName
                && $0.identity.device == attributes.st_dev
                && $0.identity.inode == attributes.st_ino
                && attributes.st_mode & S_IFMT == S_IFREG
        }
    }

    func isCurrentAtRoot() -> Bool {
        var current = stat()
        return Darwin.fstatat(rootDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_dev == attributes.st_dev
            && current.st_ino == attributes.st_ino
            && current.st_mode & S_IFMT == S_IFDIR
    }

    func isReachableAtOriginalURL() -> Bool {
        var currentRoot = stat()
        return Darwin.lstat(rootURL.path, &currentRoot) == 0
            && currentRoot.st_dev == rootAttributes.st_dev
            && currentRoot.st_ino == rootAttributes.st_ino
            && currentRoot.st_mode & S_IFMT == S_IFDIR
            && isCurrentAtRoot()
    }

    func belongsToRoot(device: dev_t, inode: ino_t) -> Bool {
        rootAttributes.st_dev == device && rootAttributes.st_ino == inode
    }

    func containsOnlyRecordedRegularFiles() -> Bool {
        guard let names = directoryEntryNames(), Set(names) == Set(createdFiles.map(\.name)) else {
            return false
        }
        for file in createdFiles {
            var current = stat()
            guard Darwin.fstatat(descriptor, file.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_mode & S_IFMT == S_IFREG,
                  current.st_dev == file.identity.device,
                  current.st_ino == file.identity.inode else {
                return false
            }
        }
        return true
    }

    func cleanup() {
        for file in createdFiles.reversed() {
            var current = stat()
            if Darwin.fstatat(descriptor, file.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_mode & S_IFMT == S_IFREG,
               current.st_dev == file.identity.device,
               current.st_ino == file.identity.inode {
                _ = Darwin.unlinkat(descriptor, file.name, 0)
            }
        }
        guard isCurrentAtRoot() else { return }
        _ = Darwin.unlinkat(rootDescriptor, name, AT_REMOVEDIR)
    }

    private func directoryEntryNames() -> [String]? {
        let duplicate = Darwin.openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            return nil
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }
}
