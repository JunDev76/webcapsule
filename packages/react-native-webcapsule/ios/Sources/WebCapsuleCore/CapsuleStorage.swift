import CryptoKit
import Darwin
import Foundation

enum CapsuleInstallFaultPoint: CaseIterable {
    case beforeBlobPublish
    case afterBlobPublish
    case beforeRecordWrite
    case afterRecordWrite
    case afterVersionDirectoryCreate
    case afterVersionPublish
}

enum RegistryWriteFaultPoint: CaseIterable {
    case beforeTempSync
    case afterTempSync
    case beforeReplace
    case afterReplace
}

typealias CapsuleInstallFaultInjector = (CapsuleInstallFaultPoint) throws -> Void
typealias RegistryWriteFaultInjector = (RegistryWriteFaultPoint) throws -> Void

final class CapsuleStorage {
    let stagingURL: URL

    private let root: StorageDirectory
    private let blobContainer: StorageDirectory
    private let blobs: StorageDirectory
    private let versions: StorageDirectory
    private let locks: StorageDirectory
    private let stagingIdentity: StrictZipFileIdentity
    private var pinnedResourceShardIdentities: [String: StrictZipFileIdentity] = [:]
    private let faultInjector: CapsuleInstallFaultInjector
    private let registryFaultInjector: RegistryWriteFaultInjector

    init(
        rootURL: URL,
        faultInjector: @escaping CapsuleInstallFaultInjector = { _ in },
        registryFaultInjector: @escaping RegistryWriteFaultInjector = { _ in },
        createLayout: Bool = true
    ) throws {
        guard rootURL.isFileURL else {
            throw WebCapsuleError(code: .invalidArgument, message: "Storage root must be a file URL")
        }
        root = try StorageDirectory.openExistingRoot(rootURL)
        let openedBlobContainer: StorageDirectory
        let openedBlobs: StorageDirectory
        let openedVersions: StorageDirectory
        let staging: StorageDirectory
        let openedLocks: StorageDirectory
        if createLayout {
            openedBlobContainer = try root.openOrCreateDirectory("blobs")
            openedBlobs = try openedBlobContainer.openOrCreateDirectory("sha256")
            openedVersions = try root.openOrCreateDirectory("versions")
            staging = try root.openOrCreateDirectory("staging")
            openedLocks = try root.openOrCreateDirectory("locks")
        } else {
            do {
                openedBlobContainer = try root.openDirectory("blobs")
                openedBlobs = try openedBlobContainer.openDirectory("sha256")
                openedVersions = try root.openDirectory("versions")
                staging = try root.openDirectory("staging")
                openedLocks = try root.openDirectory("locks")
            } catch {
                throw WebCapsuleError(
                    code: .storageInvariantViolation,
                    message: "Pinned resource storage layout is missing or unsafe"
                )
            }
        }
        blobContainer = openedBlobContainer
        blobs = openedBlobs
        versions = openedVersions
        stagingIdentity = staging.identity
        locks = openedLocks
        stagingURL = staging.url
        self.faultInjector = faultInjector
        self.registryFaultInjector = registryFaultInjector
    }

    func withExclusiveLock<T>(capsuleId: String, _ body: () throws -> T) throws -> T {
        try CapsuleManifestParser.validateCapsuleID(capsuleId)
        let key = Self.encodeStorageKey(capsuleId)
        let processLock = ProcessCapsuleLockPool.shared.lock(for: root.identity, capsuleKey: key)
        processLock.lock()
        defer { processLock.unlock() }
        let lockName = "\(key).lock"
        let descriptor = Darwin.openat(
            locks.descriptor,
            lockName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw WebCapsuleError(code: .lockFailed, message: "Storage install lock cannot be opened")
        }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_nlink == 1,
              attributes.st_uid == Darwin.geteuid(),
              attributes.st_mode & 0o777 == S_IRUSR | S_IWUSR,
              lockPathMatches(name: lockName, descriptor: descriptor) else {
            throw WebCapsuleError(code: .lockFailed, message: "Storage install lock is unsafe")
        }
        var lock = flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        while Darwin.fcntl(descriptor, F_SETLKW, &lock) != 0 {
            if errno == EINTR { continue }
            throw WebCapsuleError(code: .lockFailed, message: "Storage install lock cannot be acquired")
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        }
        guard lockPathMatches(name: lockName, descriptor: descriptor) else {
            throw WebCapsuleError(code: .lockFailed, message: "Storage install lock was substituted while waiting")
        }
        return try body()
    }

    private func lockPathMatches(name: String, descriptor: Int32) -> Bool {
        var opened = stat()
        var current = stat()
        return Darwin.fstat(descriptor, &opened) == 0
            && Darwin.fstatat(locks.descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_mode & S_IFMT == S_IFREG
            && current.st_dev == opened.st_dev
            && current.st_ino == opened.st_ino
    }

    func readRegistry(capsuleId: String) throws -> Data? {
        try CapsuleManifestParser.validateCapsuleID(capsuleId)
        guard root.entryExists("registries") else { return nil }
        let registries: StorageDirectory
        do {
            registries = try root.openDirectory("registries")
        } catch {
            throw WebCapsuleError(code: .registryInvalid, message: "Registry directory is unsafe")
        }
        let name = registryFileName(capsuleId)
        var pathAttributes = stat()
        if Darwin.fstatat(registries.descriptor, name, &pathAttributes, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw WebCapsuleError(code: .registryInvalid, message: "Registry path cannot be inspected")
        }
        guard pathAttributes.st_mode & S_IFMT == S_IFREG,
              pathAttributes.st_uid == Darwin.geteuid(),
              pathAttributes.st_nlink == 1,
              pathAttributes.st_mode & 0o777 == S_IRUSR | S_IWUSR else {
            throw WebCapsuleError(code: .registryInvalid, message: "Registry is not an app-owned 0600 regular file")
        }
        let descriptor = Darwin.openat(registries.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw WebCapsuleError(code: .registryInvalid, message: "Registry cannot be opened safely")
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        var current = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              Darwin.fstatat(registries.descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_dev == current.st_dev,
              opened.st_ino == current.st_ino,
              opened.st_uid == Darwin.geteuid(),
              opened.st_nlink == 1,
              opened.st_mode & 0o777 == S_IRUSR | S_IWUSR else {
            throw WebCapsuleError(code: .registryInvalid, message: "Registry was substituted while opening")
        }
        do {
            return try readAll(descriptor: descriptor, maximum: 1024 * 1024)
        } catch {
            throw WebCapsuleError(code: .registryInvalid, message: "Registry cannot be read")
        }
    }

    func replaceRegistry(capsuleId: String, bytes: Data) throws {
        try CapsuleManifestParser.validateCapsuleID(capsuleId)
        let registries = try root.openOrCreateDirectory("registries")
        let finalName = registryFileName(capsuleId)
        let existingIdentity = try validateRegistryDestinationIfPresent(finalName, in: registries)
        let temporaryName = ".registry-\(Self.encodeStorageKey(capsuleId))-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = Darwin.openat(
            registries.descriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw WebCapsuleError(code: .storageIOFailed, message: "Registry temporary file cannot be created")
        }
        var attributes = stat()
        var identity: StrictZipFileIdentity?
        var replaced = false
        defer {
            Darwin.close(descriptor)
            if !replaced, let identity {
                registries.removeFileIfOwned(temporaryName, identity: identity)
            }
        }
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == Darwin.geteuid(),
              attributes.st_nlink == 1,
              attributes.st_mode & 0o777 == S_IRUSR | S_IWUSR else {
            throw WebCapsuleError(code: .storageIOFailed, message: "Registry temporary file is unsafe")
        }
        identity = StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
        try writeAll(descriptor: descriptor, data: bytes, message: "Registry temporary file cannot be written")
        try registryFaultInjector(.beforeTempSync)
        guard Darwin.fsync(descriptor) == 0 else {
            throw WebCapsuleError(code: .storageIOFailed, message: "Registry temporary file cannot be synced")
        }
        try registryFaultInjector(.afterTempSync)
        guard root.isReachableAtOriginalURL(),
              root.childMatches("registries", identity: registries.identity),
              registries.pathMatches(temporaryName, descriptor: descriptor) else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Registry storage was substituted before publication")
        }
        let currentIdentity = try validateRegistryDestinationIfPresent(finalName, in: registries)
        guard currentIdentity == existingIdentity else {
            throw WebCapsuleError(code: .registryInvalid, message: "Registry destination changed before publication")
        }
        try registryFaultInjector(.beforeReplace)
        if let existingIdentity {
            guard Darwin.renameatx_np(
                registries.descriptor,
                temporaryName,
                registries.descriptor,
                finalName,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw WebCapsuleError(code: .storageIOFailed, message: "Registry atomic exchange failed")
            }
            replaced = true
            guard registries.pathMatches(finalName, descriptor: descriptor),
                  registries.entryIdentity(temporaryName) == existingIdentity else {
                throw WebCapsuleError(code: .unsafeStorageLayout, message: "Registry destination was substituted during exchange")
            }
            registries.removeFileIfOwned(temporaryName, identity: existingIdentity)
            guard !registries.entryExists(temporaryName) else {
                throw WebCapsuleError(code: .storageIOFailed, message: "Replaced registry cannot be unlinked safely")
            }
        } else {
            guard Darwin.renameatx_np(
                registries.descriptor,
                temporaryName,
                registries.descriptor,
                finalName,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw WebCapsuleError(
                    code: errno == EEXIST ? .registryInvalid : .storageIOFailed,
                    message: "Initial registry no-replace publication failed"
                )
            }
            replaced = true
            guard registries.pathMatches(finalName, descriptor: descriptor) else {
                throw WebCapsuleError(code: .unsafeStorageLayout, message: "Published registry inode differs")
            }
        }
        guard Darwin.fsync(registries.descriptor) == 0 else {
            throw WebCapsuleError(code: .storageIOFailed, message: "Registry directory sync failed")
        }
        try registryFaultInjector(.afterReplace)
    }

    func cleanupStagingOperations(capsuleId: String) throws {
        let staging: StorageDirectory
        do {
            staging = try root.openDirectory("staging")
        } catch {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Staging root is unsafe")
        }
        guard staging.identity.device == stagingIdentity.device,
              staging.identity.inode == stagingIdentity.inode else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Staging root identity changed")
        }
        for operationName in try staging.entryNames() {
            guard let uuid = UUID(uuidString: operationName),
                  uuid.uuidString.lowercased() == operationName else {
                throw WebCapsuleError(code: .unsafeStorageLayout, message: "Unexpected staging operation name")
            }
            let operation: StorageDirectory
            do {
                operation = try staging.openDirectory(operationName)
            } catch {
                throw WebCapsuleError(code: .unsafeStorageLayout, message: "Staging operation is not a safe directory")
            }
            let owner = try readStagingOwner(operation)
            if owner != capsuleId { continue }
            for fileName in try operation.entryNames() {
                guard isOwnedStagingFileName(fileName) else {
                    throw WebCapsuleError(code: .unsafeStorageLayout, message: "Unexpected staging operation entry")
                }
                var attributes = stat()
                guard Darwin.fstatat(operation.descriptor, fileName, &attributes, AT_SYMLINK_NOFOLLOW) == 0,
                      attributes.st_mode & S_IFMT == S_IFREG,
                      attributes.st_uid == Darwin.geteuid(),
                      attributes.st_nlink >= 1,
                      [S_IRUSR | S_IWUSR, S_IRUSR | S_IRGRP | S_IROTH].contains(attributes.st_mode & 0o777) else {
                    throw WebCapsuleError(code: .unsafeStorageLayout, message: "Staging operation entry is unsafe")
                }
                operation.removeFileIfOwned(
                    fileName,
                    identity: StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
                )
                guard !operation.entryExists(fileName) else {
                    throw WebCapsuleError(code: .storageIOFailed, message: "Staging operation entry cannot be removed")
                }
            }
            staging.removeEmptyDirectoryIfOwned(operationName, identity: operation.identity)
            guard !staging.entryExists(operationName) else {
                throw WebCapsuleError(code: .storageIOFailed, message: "Staging operation cannot be removed")
            }
        }
    }

    private func readStagingOwner(_ operation: StorageDirectory) throws -> String {
        let descriptor = Darwin.openat(operation.descriptor, ".capsule-owner", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Staging owner marker is missing or unsafe")
        }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == Darwin.geteuid(),
              attributes.st_nlink == 1,
              attributes.st_mode & 0o777 == S_IRUSR | S_IWUSR else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Staging owner marker is unsafe")
        }
        let bytes = try readAll(descriptor: descriptor, maximum: 512)
        guard bytes.last == 0x0A, bytes.dropLast().last != 0x0A,
              let encoded = String(data: Data(bytes.dropLast()), encoding: .utf8),
              !encoded.isEmpty else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Staging owner marker is invalid")
        }
        let owner: String
        do {
            owner = try Self.decodeStorageKey(encoded)
            try CapsuleManifestParser.validateCapsuleID(owner)
        } catch {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Staging owner marker identity is invalid")
        }
        return owner
    }

    private func isOwnedStagingFileName(_ name: String) -> Bool {
        if name == ".capsule-owner" || name == "record.json" { return true }
        let bytes = Array(name.utf8)
        return bytes.count == 13
            && bytes[8...].elementsEqual(Array(".blob".utf8))
            && bytes[..<8].allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    func cleanupRegistryTemps(capsuleId: String) throws {
        guard root.entryExists("registries") else { return }
        let registries: StorageDirectory
        do {
            registries = try root.openDirectory("registries")
        } catch {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Registry directory is unsafe")
        }
        let prefix = ".registry-\(Self.encodeStorageKey(capsuleId))-"
        for name in try registries.entryNames() where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            let uuidText = String(name.dropFirst(prefix.count).dropLast(4))
            guard UUID(uuidString: uuidText) != nil, uuidText == uuidText.lowercased() else {
                throw WebCapsuleError(code: .unsafeStorageLayout, message: "Registry temporary name is not canonical")
            }
            var attributes = stat()
            guard Darwin.fstatat(registries.descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0,
                  attributes.st_mode & S_IFMT == S_IFREG,
                  attributes.st_uid == Darwin.geteuid(),
                  attributes.st_nlink == 1,
                  attributes.st_mode & 0o777 == S_IRUSR | S_IWUSR else {
                throw WebCapsuleError(code: .unsafeStorageLayout, message: "Registry temporary entry is unsafe")
            }
            let identity = StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
            registries.removeFileIfOwned(name, identity: identity)
            guard !registries.entryExists(name) else {
                throw WebCapsuleError(code: .storageIOFailed, message: "Registry temporary file cannot be removed")
            }
        }
    }

    func registryFileName(_ capsuleId: String) -> String {
        "\(Self.encodeStorageKey(capsuleId)).json"
    }

    private func validateRegistryDestinationIfPresent(
        _ name: String,
        in registries: StorageDirectory
    ) throws -> StrictZipFileIdentity? {
        var attributes = stat()
        if Darwin.fstatat(registries.descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw WebCapsuleError(code: .registryInvalid, message: "Registry destination cannot be inspected")
        }
        guard attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == Darwin.geteuid(),
              attributes.st_nlink == 1,
              attributes.st_mode & 0o777 == S_IRUSR | S_IWUSR else {
            throw WebCapsuleError(code: .registryInvalid, message: "Unsafe registry destination cannot be replaced")
        }
        return StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
    }

    func install(_ capsule: VerifiedCapsule) throws -> CapsuleInstallResult {
        let operation = try capsule.claimForInstall()
        defer { operation.cleanup() }
        guard operation.belongsToRoot(device: stagingIdentity.device, inode: stagingIdentity.inode) else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Verified operation belongs to another staging root")
        }
        guard operation.isReachableAtOriginalURL() else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Verified operation staging root was substituted")
        }
        guard operation.containsOnlyRecordedRegularFiles() else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Verified operation contents were substituted")
        }
        try validateVerifiedMetadata(capsule)
        try validateStagedFiles(capsule, operation: operation)
        let record = try VersionRecordCodec.fromVerified(capsule)
        let recordBytes = try VersionRecordCodec.serialize(record)
        let capsuleDirectory = try versions.openOrCreateDirectory(Self.encodeStorageKey(record.capsuleId))
        let versionName = Self.encodeStorageKey(record.version)

        if capsuleDirectory.entryExists(versionName) {
            try verifyExistingVersion(
                parent: capsuleDirectory,
                name: versionName,
                expectedBytes: recordBytes,
                expectedRecord: record,
                conflictingIsInvariant: true
            )
            return CapsuleInstallResult(record: record, installed: false, publishedBlobCount: 0)
        }

        var publishedBlobCount = 0
        for (index, file) in capsule.files.enumerated() {
            try faultInjector(.beforeBlobPublish)
            if try publishBlob(file, index: index, operation: operation) {
                publishedBlobCount += 1
            }
            try faultInjector(.afterBlobPublish)
        }
        try verifyReferencedBlobs(record)

        try faultInjector(.beforeRecordWrite)
        let stagedRecordName = "record.json"
        let recordIdentity = try writeNewSyncedReadOnly(
            directory: operation.descriptor,
            name: stagedRecordName,
            data: recordBytes
        )
        operation.recordCreatedFile(stagedRecordName, identity: recordIdentity)
        try faultInjector(.afterRecordWrite)

        let finalIdentity: StrictZipFileIdentity
        do {
            finalIdentity = try capsuleDirectory.createDirectory(versionName)
        } catch let error as WebCapsuleError where error.code == .storageInvariantViolation {
            if capsuleDirectory.entryExists(versionName) {
                try verifyExistingVersion(
                    parent: capsuleDirectory,
                    name: versionName,
                    expectedBytes: recordBytes,
                    expectedRecord: record,
                    conflictingIsInvariant: true
                )
                return CapsuleInstallResult(record: record, installed: false, publishedBlobCount: publishedBlobCount)
            }
            throw error
        }

        var recordPublished = false
        defer {
            if !recordPublished {
                capsuleDirectory.removeEmptyDirectoryIfOwned(versionName, identity: finalIdentity)
            }
        }
        try faultInjector(.afterVersionDirectoryCreate)
        let finalDirectory = try capsuleDirectory.openDirectory(versionName)
        let stagedRecord = Darwin.openat(
            operation.descriptor,
            stagedRecordName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard stagedRecord >= 0 else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Staged version record is unavailable")
        }
        defer { Darwin.close(stagedRecord) }
        let stagedAttributes = try regularFileAttributes(stagedRecord, expectedSize: UInt64(recordBytes.count))
        guard stagedAttributes.st_uid == Darwin.geteuid(),
              stagedAttributes.st_mode & 0o777 == S_IRUSR | S_IRGRP | S_IROTH,
              operation.isRecordedRegularFile(stagedRecordName, attributes: stagedAttributes),
              try readAll(descriptor: stagedRecord, maximum: recordBytes.count) == recordBytes else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Staged version record changed before publication")
        }
        var currentStagedRecord = stat()
        guard Darwin.fstatat(
            operation.descriptor,
            stagedRecordName,
            &currentStagedRecord,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              currentStagedRecord.st_dev == stagedAttributes.st_dev,
              currentStagedRecord.st_ino == stagedAttributes.st_ino,
              currentStagedRecord.st_mode & S_IFMT == S_IFREG else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Staged version record was substituted")
        }
        guard Darwin.linkat(operation.descriptor, stagedRecordName, finalDirectory.descriptor, "record.json", 0) == 0 else {
            throw WebCapsuleError(
                code: errno == ENOTSUP || errno == EXDEV ? .atomicPublishUnsupported : .storageInvariantViolation,
                message: "Version record create-if-absent publication failed"
            )
        }
        var publishedAttributes = stat()
        guard Darwin.fstatat(
            finalDirectory.descriptor,
            "record.json",
            &publishedAttributes,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Published version record cannot be inspected")
        }
        guard publishedAttributes.st_mode & S_IFMT == S_IFREG,
              publishedAttributes.st_dev == stagedAttributes.st_dev,
              publishedAttributes.st_ino == stagedAttributes.st_ino else {
            finalDirectory.removeFileIfOwned(
                "record.json",
                identity: StrictZipFileIdentity(device: stagedAttributes.st_dev, inode: stagedAttributes.st_ino)
            )
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Published version record inode differs")
        }
        recordPublished = true
        try faultInjector(.afterVersionPublish)
        try verifyExistingVersion(
            parent: capsuleDirectory,
            name: versionName,
            expectedBytes: recordBytes,
            expectedRecord: record,
            conflictingIsInvariant: true
        )
        return CapsuleInstallResult(record: record, installed: true, publishedBlobCount: publishedBlobCount)
    }

    func pinResourceShards(_ files: [SessionFile]) throws {
        var pinned: [String: StrictZipFileIdentity] = [:]
        do {
            guard root.isReachableAtOriginalURL(),
                  root.childMatches("blobs", identity: blobContainer.identity),
                  blobContainer.childMatches("sha256", identity: blobs.identity) else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "CAS root identity changed")
            }
            for shardName in Set(files.map { String($0.sha256.prefix(2)) }) {
                let shard = try blobs.openDirectory(shardName)
                guard blobs.childMatches(shardName, identity: shard.identity) else {
                    throw WebCapsuleError(code: .storageInvariantViolation, message: "CAS shard identity changed")
                }
                pinned[shardName] = shard.identity
            }
            pinnedResourceShardIdentities = pinned
        } catch let error as WebCapsuleError where error.code == .storageInvariantViolation {
            throw error
        } catch {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Pinned CAS layout cannot be validated")
        }
    }

    func openPinnedBlob(_ file: SessionFile) throws -> PinnedBlobStream {
        do {
            guard VersionRecordCodec.isLowercaseSHA256(file.sha256),
                  file.size >= 0,
                  root.isReachableAtOriginalURL(),
                  root.childMatches("blobs", identity: blobContainer.identity),
                  blobContainer.childMatches("sha256", identity: blobs.identity) else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "CAS root identity changed")
            }
            let shardName = String(file.sha256.prefix(2))
            guard let pinnedShardIdentity = pinnedResourceShardIdentities[shardName],
                  blobs.childMatches(shardName, identity: pinnedShardIdentity) else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "CAS shard identity changed")
            }
            let shard = try blobs.openDirectory(shardName)
            guard shard.identity == pinnedShardIdentity,
                  blobs.childMatches(shardName, identity: shard.identity) else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "CAS shard identity changed")
            }
            let descriptor = Darwin.openat(
                shard.descriptor,
                file.sha256,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Pinned CAS blob cannot be opened")
            }
            var transferOwnership = false
            defer { if !transferOwnership { Darwin.close(descriptor) } }
            let attributes = try regularFileAttributes(descriptor, expectedSize: UInt64(file.size))
            guard attributes.st_uid == Darwin.geteuid(),
                  attributes.st_nlink >= 1,
                  attributes.st_mode & 0o777 == S_IRUSR | S_IRGRP | S_IROTH,
                  shard.pathMatches(file.sha256, descriptor: descriptor),
                  root.isReachableAtOriginalURL(),
                  root.childMatches("blobs", identity: blobContainer.identity),
                  blobContainer.childMatches("sha256", identity: blobs.identity),
                  blobs.childMatches(shardName, identity: shard.identity),
                  try hash(descriptor: descriptor) == file.sha256,
                  Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Pinned CAS blob violates immutable storage invariants")
            }
            transferOwnership = true
            return PinnedBlobStream(
                descriptor: descriptor,
                expectedSize: file.size,
                expectedSHA256: file.sha256
            )
        } catch let error as WebCapsuleError where error.code == .storageInvariantViolation {
            throw error
        } catch {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Pinned CAS storage cannot be validated")
        }
    }

    func read(capsuleId: String, version: String) throws -> VersionRecord {
        try CapsuleManifestParser.validateCapsuleID(capsuleId)
        try SemanticVersion.validate(version)
        let capsuleDirectory: StorageDirectory
        do {
            capsuleDirectory = try versions.openDirectory(Self.encodeStorageKey(capsuleId))
        } catch {
            throw WebCapsuleError(code: .versionRecordInvalid, message: "Installed capsule directory is missing or unsafe")
        }
        let versionName = Self.encodeStorageKey(version)
        let directory: StorageDirectory
        do {
            directory = try capsuleDirectory.openDirectory(versionName)
        } catch {
            throw WebCapsuleError(code: .versionRecordInvalid, message: "Installed version directory is missing or unsafe")
        }
        let record = try readStrictRecord(directory)
        guard record.capsuleId == capsuleId, record.version == version else {
            throw WebCapsuleError(code: .versionRecordInvalid, message: "Version path and record identity differ")
        }
        try verifyReferencedBlobs(record)
        return record
    }

    private func validateStagedFiles(_ capsule: VerifiedCapsule, operation: OwnedOperationDirectory) throws {
        for (index, file) in capsule.files.enumerated() {
            let name = String(format: "%08x.blob", index)
            guard file.stagedURL.deletingLastPathComponent().standardizedFileURL == operation.url.standardizedFileURL,
                  file.stagedURL.lastPathComponent == name else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Verified staged file location differs")
            }
            let descriptor = Darwin.openat(operation.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Verified staged blob is unavailable")
            }
            defer { Darwin.close(descriptor) }
            let attributes = try regularFileAttributes(descriptor, expectedSize: UInt64(file.size))
            guard operation.isRecordedRegularFile(name, attributes: attributes) else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Verified staged blob inode differs")
            }
            guard try hash(descriptor: descriptor) == file.sha256 else {
                throw WebCapsuleError(code: .hashMismatch, message: "Staged blob changed after verification")
            }
        }
    }

    private func publishBlob(
        _ file: VerifiedCapsuleFile,
        index: Int,
        operation: OwnedOperationDirectory
    ) throws -> Bool {
        let expectedName = String(format: "%08x.blob", index)
        guard file.stagedURL.deletingLastPathComponent().standardizedFileURL == operation.url.standardizedFileURL,
              file.stagedURL.lastPathComponent == expectedName else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Verified staged file location differs")
        }
        let source = Darwin.openat(operation.descriptor, expectedName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Verified staged blob is unavailable")
        }
        defer { Darwin.close(source) }
        let sourceAttributes = try regularFileAttributes(source, expectedSize: UInt64(file.size))
        guard sourceAttributes.st_uid == Darwin.geteuid(),
              operation.isRecordedRegularFile(expectedName, attributes: sourceAttributes) else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Verified staged blob inode differs")
        }
        guard try hash(descriptor: source) == file.sha256 else {
            throw WebCapsuleError(code: .hashMismatch, message: "Staged blob changed after verification")
        }
        guard Darwin.fchmod(source, S_IRUSR | S_IRGRP | S_IROTH) == 0,
              Darwin.fsync(source) == 0 else {
            throw WebCapsuleError(code: .storageIOFailed, message: "Staged blob cannot be made durable and read-only")
        }
        var current = stat()
        guard Darwin.fstatat(operation.descriptor, expectedName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == sourceAttributes.st_dev,
              current.st_ino == sourceAttributes.st_ino,
              current.st_mode & S_IFMT == S_IFREG else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Staged blob was substituted")
        }

        let shard = try blobs.openOrCreateDirectory(String(file.sha256.prefix(2)))
        if shard.entryExists(file.sha256) {
            try verifyBlob(directory: shard, name: file.sha256, expectedSize: UInt64(file.size), expectedHash: file.sha256)
            return false
        }
        if Darwin.linkat(operation.descriptor, expectedName, shard.descriptor, file.sha256, 0) == 0 {
            var published = stat()
            guard Darwin.fstatat(shard.descriptor, file.sha256, &published, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Published CAS blob cannot be inspected")
            }
            let publishedIdentity = StrictZipFileIdentity(device: published.st_dev, inode: published.st_ino)
            guard published.st_mode & S_IFMT == S_IFREG,
                  publishedIdentity.device == sourceAttributes.st_dev,
                  publishedIdentity.inode == sourceAttributes.st_ino else {
                shard.removeFileIfOwned(
                    file.sha256,
                    identity: StrictZipFileIdentity(device: sourceAttributes.st_dev, inode: sourceAttributes.st_ino)
                )
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Published CAS inode differs from verified staging")
            }
            do {
                try verifyBlob(directory: shard, name: file.sha256, expectedSize: UInt64(file.size), expectedHash: file.sha256)
                return true
            } catch {
                shard.removeFileIfOwned(file.sha256, identity: publishedIdentity)
                throw error
            }
        }
        if errno == EEXIST {
            try verifyBlob(directory: shard, name: file.sha256, expectedSize: UInt64(file.size), expectedHash: file.sha256)
            return false
        }
        throw WebCapsuleError(
            code: errno == ENOTSUP || errno == EXDEV ? .atomicPublishUnsupported : .storageIOFailed,
            message: "Blob create-if-absent publication failed"
        )
    }

    private func verifyReferencedBlobs(_ record: VersionRecord) throws {
        for file in record.files {
            let shard: StorageDirectory
            do {
                shard = try blobs.openDirectory(String(file.sha256.prefix(2)))
            } catch {
                throw WebCapsuleError(code: .blobMissing, message: "Referenced CAS blob is missing")
            }
            do {
                try verifyBlob(directory: shard, name: file.sha256, expectedSize: UInt64(file.size), expectedHash: file.sha256)
            } catch let error as WebCapsuleError where error.code == .blobMissing {
                throw error
            } catch {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Referenced CAS blob violates storage invariants")
            }
        }
    }

    private func verifyBlob(
        directory: StorageDirectory,
        name: String,
        expectedSize: UInt64,
        expectedHash: String
    ) throws {
        let descriptor = Darwin.openat(directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw WebCapsuleError(code: .blobMissing, message: "Referenced CAS blob is missing")
            }
            throw WebCapsuleError(code: .storageInvariantViolation, message: "CAS blob cannot be opened safely")
        }
        defer { Darwin.close(descriptor) }
        let attributes = try regularFileAttributes(descriptor, expectedSize: expectedSize)
        guard attributes.st_mode & 0o777 == S_IRUSR | S_IRGRP | S_IROTH,
              attributes.st_uid == Darwin.geteuid(),
              attributes.st_nlink >= 1,
              try hash(descriptor: descriptor) == expectedHash else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "CAS blob content or mode differs")
        }
    }

    private func verifyExistingVersion(
        parent: StorageDirectory,
        name: String,
        expectedBytes: Data,
        expectedRecord: VersionRecord,
        conflictingIsInvariant: Bool
    ) throws {
        do {
            let directory = try parent.openDirectory(name)
            guard try directory.entryNames() == ["record.json"] else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Published version directory is not exact")
            }
            let descriptor = Darwin.openat(directory.descriptor, "record.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Published record cannot be opened")
            }
            defer { Darwin.close(descriptor) }
            let attributes = try regularFileAttributes(descriptor, expectedSize: nil)
            guard attributes.st_mode & 0o777 == S_IRUSR | S_IRGRP | S_IROTH,
                  attributes.st_uid == Darwin.geteuid() else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Published record is not immutable app-owned storage")
            }
            let bytes = try readAll(descriptor: descriptor, maximum: 5 * 1024 * 1024)
            let parsed = try VersionRecordCodec.parse(bytes)
            guard bytes == expectedBytes, parsed == expectedRecord else {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Published version differs")
            }
            try verifyReferencedBlobs(parsed)
        } catch let error as WebCapsuleError {
            if conflictingIsInvariant, error.code != .storageInvariantViolation {
                throw WebCapsuleError(code: .storageInvariantViolation, message: "Published version is incomplete or invalid")
            }
            throw error
        } catch {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Published version cannot be verified")
        }
    }

    private func readStrictRecord(_ directory: StorageDirectory) throws -> VersionRecord {
        guard try directory.entryNames() == ["record.json"] else {
            throw WebCapsuleError(code: .versionRecordInvalid, message: "Version directory must contain only record.json")
        }
        let descriptor = Darwin.openat(directory.descriptor, "record.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw WebCapsuleError(code: .versionRecordInvalid, message: "Version record cannot be opened safely")
        }
        defer { Darwin.close(descriptor) }
        let attributes = try regularFileAttributes(descriptor, expectedSize: nil)
        guard attributes.st_mode & 0o777 == S_IRUSR | S_IRGRP | S_IROTH,
              attributes.st_uid == Darwin.geteuid() else {
            throw WebCapsuleError(code: .versionRecordInvalid, message: "Version record is not immutable app-owned storage")
        }
        return try VersionRecordCodec.parse(readAll(descriptor: descriptor, maximum: 5 * 1024 * 1024))
    }

    private func validateVerifiedMetadata(_ capsule: VerifiedCapsule) throws {
        guard capsule.files.count == capsule.manifest.files.count,
              capsule.files.enumerated().allSatisfy({ index, file in
                  let manifest = capsule.manifest.files[index]
                  return file.path == manifest.path
                      && file.sha256 == manifest.sha256
                      && file.size == manifest.size
                      && file.mediaType == manifest.mediaType
              }),
              VersionRecordCodec.isLowercaseSHA256(capsule.manifestSHA256) else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Verified capsule metadata differs from manifest")
        }
    }

    static func encodeStorageKey(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func decodeStorageKey(_ value: String) throws -> String {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2), bytes.allSatisfy({
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }) else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Storage key encoding is invalid")
        }
        var decoded = Data()
        decoded.reserveCapacity(bytes.count / 2)
        func nibble(_ byte: UInt8) -> UInt8 {
            (0x30...0x39).contains(byte) ? byte - 0x30 : byte - 0x61 + 10
        }
        for index in stride(from: 0, to: bytes.count, by: 2) {
            decoded.append(nibble(bytes[index]) << 4 | nibble(bytes[index + 1]))
        }
        guard let result = String(data: decoded, encoding: .utf8),
              result.precomposedStringWithCanonicalMapping == result,
              encodeStorageKey(result) == value else {
            throw WebCapsuleError(code: .storageInvariantViolation, message: "Storage key is not canonical UTF-8")
        }
        return result
    }
}

private final class ProcessCapsuleLockPool: @unchecked Sendable {
    static let shared = ProcessCapsuleLockPool()

    private let mutex = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for identity: StrictZipFileIdentity, capsuleKey: String) -> NSLock {
        let key = "\(identity.device):\(identity.inode):\(capsuleKey)"
        mutex.lock()
        defer { mutex.unlock() }
        if let existing = locks[key] { return existing }
        let created = NSLock()
        locks[key] = created
        return created
    }
}

final class StorageDirectory {
    let descriptor: Int32
    let url: URL
    let identity: StrictZipFileIdentity

    private init(descriptor: Int32, url: URL, attributes: stat) {
        self.descriptor = descriptor
        self.url = url
        identity = StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
    }

    deinit { Darwin.close(descriptor) }

    static func openExistingRoot(_ url: URL) throws -> StorageDirectory {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Storage root must be an existing non-symlink directory")
        }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              isSafeOwnedDirectory(attributes) else {
            Darwin.close(descriptor)
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Storage root is not a safe app-owned directory")
        }
        return StorageDirectory(descriptor: descriptor, url: url.standardizedFileURL, attributes: attributes)
    }

    func openOrCreateDirectory(_ name: String) throws -> StorageDirectory {
        validatePhysicalName(name)
        if Darwin.mkdirat(descriptor, name, S_IRWXU) != 0, errno != EEXIST {
            throw WebCapsuleError(code: .storageIOFailed, message: "Storage directory cannot be created")
        }
        return try openDirectory(name)
    }

    func createDirectory(_ name: String) throws -> StrictZipFileIdentity {
        validatePhysicalName(name)
        guard Darwin.mkdirat(descriptor, name, S_IRWXU) == 0 else {
            throw WebCapsuleError(
                code: errno == EEXIST ? .storageInvariantViolation : .storageIOFailed,
                message: "Version directory cannot be created without replacement"
            )
        }
        var attributes = stat()
        guard Darwin.fstatat(descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0,
              isSafeOwnedDirectory(attributes) else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Created directory was substituted or is unsafe")
        }
        return StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
    }

    func openDirectory(_ name: String) throws -> StorageDirectory {
        validatePhysicalName(name)
        let child = Darwin.openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Storage child is missing, unsafe, or not a directory")
        }
        var attributes = stat()
        guard Darwin.fstat(child, &attributes) == 0,
              isSafeOwnedDirectory(attributes) else {
            Darwin.close(child)
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Storage child is not a safe app-owned directory")
        }
        return StorageDirectory(
            descriptor: child,
            url: url.appendingPathComponent(name, isDirectory: true),
            attributes: attributes
        )
    }

    func entryExists(_ name: String) -> Bool {
        var attributes = stat()
        return Darwin.fstatat(descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0
    }

    func entryNames() throws -> [String] {
        let duplicate = Darwin.openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw WebCapsuleError(code: .storageIOFailed, message: "Storage directory cannot be listed")
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    func removeFileIfOwned(_ name: String, identity: StrictZipFileIdentity) {
        var attributes = stat()
        guard Darwin.fstatat(descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_dev == identity.device,
              attributes.st_ino == identity.inode else { return }
        _ = Darwin.unlinkat(descriptor, name, 0)
    }

    func entryIdentity(_ name: String) -> StrictZipFileIdentity? {
        var attributes = stat()
        guard Darwin.fstatat(descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0,
              attributes.st_mode & S_IFMT == S_IFREG else { return nil }
        return StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
    }

    func pathMatches(_ name: String, descriptor openedDescriptor: Int32) -> Bool {
        var opened = stat()
        var current = stat()
        return Darwin.fstat(openedDescriptor, &opened) == 0
            && Darwin.fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_mode & S_IFMT == S_IFREG
            && current.st_dev == opened.st_dev
            && current.st_ino == opened.st_ino
    }

    func childMatches(_ name: String, identity childIdentity: StrictZipFileIdentity) -> Bool {
        var current = stat()
        return Darwin.fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_mode & S_IFMT == S_IFDIR
            && current.st_dev == childIdentity.device
            && current.st_ino == childIdentity.inode
    }

    func isReachableAtOriginalURL() -> Bool {
        var current = stat()
        return Darwin.lstat(url.path, &current) == 0
            && current.st_mode & S_IFMT == S_IFDIR
            && current.st_dev == identity.device
            && current.st_ino == identity.inode
    }

    func removeEmptyDirectoryIfOwned(_ name: String, identity: StrictZipFileIdentity) {
        var attributes = stat()
        guard Darwin.fstatat(descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0,
              attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_dev == identity.device,
              attributes.st_ino == identity.inode else { return }
        _ = Darwin.unlinkat(descriptor, name, AT_REMOVEDIR)
    }

    private func validatePhysicalName(_ name: String) {
        precondition(!name.isEmpty && !name.contains("/") && name != "." && name != "..")
    }
}

private func isSafeOwnedDirectory(_ attributes: stat) -> Bool {
    attributes.st_mode & S_IFMT == S_IFDIR
        && attributes.st_uid == Darwin.geteuid()
        && attributes.st_mode & 0o022 == 0
}

private func regularFileAttributes(_ descriptor: Int32, expectedSize: UInt64?) throws -> stat {
    var attributes = stat()
    guard Darwin.fstat(descriptor, &attributes) == 0,
          attributes.st_mode & S_IFMT == S_IFREG,
          attributes.st_size >= 0,
          expectedSize.map({ UInt64(attributes.st_size) == $0 }) ?? true else {
        throw WebCapsuleError(code: .storageInvariantViolation, message: "Storage file type or size differs")
    }
    return attributes
}

private func hash(descriptor: Int32) throws -> String {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
        throw WebCapsuleError(code: .storageIOFailed, message: "Storage file cannot be rewound")
    }
    var digest = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            throw WebCapsuleError(code: .storageIOFailed, message: "Storage file cannot be read")
        }
        digest.update(data: Data(buffer[0..<count]))
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func readAll(descriptor: Int32, maximum: Int) throws -> Data {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
        throw WebCapsuleError(code: .storageIOFailed, message: "Storage file cannot be rewound")
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { return result }
        if count < 0 {
            if errno == EINTR { continue }
            throw WebCapsuleError(code: .storageIOFailed, message: "Storage file cannot be read")
        }
        guard result.count <= maximum - count else {
            throw WebCapsuleError(code: .versionRecordInvalid, message: "Version record exceeds its size limit")
        }
        result.append(contentsOf: buffer[0..<count])
    }
}

private func writeAll(descriptor: Int32, data: Data, message: String) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw WebCapsuleError(code: .storageIOFailed, message: message)
            }
            offset += written
        }
    }
}

private func writeNewSyncedReadOnly(
    directory: Int32,
    name: String,
    data: Data
) throws -> StrictZipFileIdentity {
    let descriptor = Darwin.openat(
        directory,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
        throw WebCapsuleError(code: .storageIOFailed, message: "Staged record cannot be created")
    }
    var attributes = stat()
    var createdIdentity: StrictZipFileIdentity?
    var succeeded = false
    defer {
        Darwin.close(descriptor)
        if !succeeded, let identity = createdIdentity {
            var current = stat()
            if Darwin.fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_mode & S_IFMT == S_IFREG,
               current.st_dev == identity.device,
               current.st_ino == identity.inode {
                _ = Darwin.unlinkat(directory, name, 0)
            }
        }
    }
    guard Darwin.fstat(descriptor, &attributes) == 0,
          attributes.st_mode & S_IFMT == S_IFREG,
          attributes.st_uid == Darwin.geteuid() else {
        throw WebCapsuleError(code: .storageIOFailed, message: "Staged record cannot be inspected")
    }
    createdIdentity = StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw WebCapsuleError(code: .storageIOFailed, message: "Staged record cannot be written")
            }
            offset += written
        }
    }
    guard Darwin.fsync(descriptor) == 0,
          Darwin.fchmod(descriptor, S_IRUSR | S_IRGRP | S_IROTH) == 0,
          Darwin.fsync(descriptor) == 0 else {
        throw WebCapsuleError(code: .storageIOFailed, message: "Staged record cannot be made durable and read-only")
    }
    succeeded = true
    return StrictZipFileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
}
