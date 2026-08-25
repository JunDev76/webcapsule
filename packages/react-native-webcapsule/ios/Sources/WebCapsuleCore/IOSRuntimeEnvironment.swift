import Darwin
import Foundation

public enum IOSBundleAssetResolver {
    public static func resolve(path: String, resourceRootURL: URL) throws -> URL {
        try WebCapsuleConfigValidator.validateBundledAssetPath(path)
        guard resourceRootURL.isFileURL else {
            throw WebCapsuleError(code: .bundledSourceInvalid, message: "Application bundle resources are unavailable")
        }
        let root = resourceRootURL.standardizedFileURL
        var rootAttributes = stat()
        guard Darwin.lstat(root.path, &rootAttributes) == 0,
              rootAttributes.st_mode & S_IFMT == S_IFDIR else {
            throw WebCapsuleError(code: .bundledSourceInvalid, message: "Application bundle resource root is unsafe")
        }
        let components = path.split(separator: "/")
        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component), isDirectory: index < components.count - 1)
            var attributes = stat()
            guard Darwin.lstat(current.path, &attributes) == 0 else {
                throw WebCapsuleError(code: .bundledCapsuleUnavailable, message: "Bundled capsule asset is unavailable")
            }
            let kind = attributes.st_mode & S_IFMT
            if index < components.count - 1 {
                guard kind == S_IFDIR else {
                    throw WebCapsuleError(code: .bundledSourceInvalid, message: "Bundled capsule parent is not a directory")
                }
            } else {
                guard kind == S_IFREG else {
                    throw WebCapsuleError(code: .bundledSourceInvalid, message: "Bundled capsule asset is not a regular file")
                }
            }
        }
        guard current.standardizedFileURL.path.hasPrefix(root.path + "/") else {
            throw WebCapsuleError(code: .bundledSourceInvalid, message: "Bundled capsule path escapes application resources")
        }
        return current
    }
}

public enum IOSRuntimeStorageRoot {
    public static let relativeComponents = ["webcapsule", "v1"]

    public static func applicationSupportBase(fileManager: FileManager = .default) throws -> URL {
        do {
            return try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw WebCapsuleError(code: .storageIOFailed, message: "Application Support directory is unavailable")
        }
    }

    public static func prepare(
        applicationSupportURL: URL,
        fileManager: FileManager = .default,
        backupExcluder: (URL) throws -> Void = excludeFromBackup
    ) throws -> URL {
        guard applicationSupportURL.isFileURL else {
            throw WebCapsuleError(code: .invalidArgument, message: "Application Support root must be a file URL")
        }
        var current = applicationSupportURL.standardizedFileURL
        try validateBaseDirectory(current)
        for component in relativeComponents {
            current.appendPathComponent(component, isDirectory: true)
            if !fileManager.fileExists(atPath: current.path) {
                do {
                    try fileManager.createDirectory(
                        at: current,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    throw WebCapsuleError(code: .storageIOFailed, message: "Runtime storage directory cannot be created")
                }
            }
            try validateOwnedDirectory(current)
        }
        do {
            try backupExcluder(current)
        } catch let error as WebCapsuleError {
            throw error
        } catch {
            throw WebCapsuleError(code: .storageIOFailed, message: "Runtime storage backup exclusion cannot be applied")
        }
        return current
    }

    public static func excludeFromBackup(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try mutable.setResourceValues(values)
        } catch {
            throw WebCapsuleError(code: .storageIOFailed, message: "Runtime storage backup exclusion cannot be applied")
        }
    }

    private static func validateBaseDirectory(_ url: URL) throws {
        var attributes = stat()
        guard Darwin.lstat(url.path, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_uid == Darwin.geteuid() else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Application Support root is unsafe")
        }
    }

    private static func validateOwnedDirectory(_ url: URL) throws {
        var attributes = stat()
        guard Darwin.lstat(url.path, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_uid == Darwin.geteuid() else {
            throw WebCapsuleError(code: .unsafeStorageLayout, message: "Runtime storage root is not an app-owned directory")
        }
        let permissions = attributes.st_mode & 0o777
        if permissions != S_IRWXU {
            guard Darwin.chmod(url.path, S_IRWXU) == 0 else {
                throw WebCapsuleError(code: .unsafeStorageLayout, message: "Runtime storage permissions cannot be restricted")
            }
        }
    }
}

public struct IOSPreparedRuntimeSession: Sendable {
    public let storageRootURL: URL
    public let session: SessionDescriptor

    init(storageRootURL: URL, session: SessionDescriptor) {
        self.storageRootURL = storageRootURL
        self.session = session
    }
}

public enum IOSRuntimePreparer {
    public static func prepare(
        config: WebCapsuleConfig,
        bundleResourceRootURL: URL,
        applicationSupportURL: URL
    ) throws -> IOSPreparedRuntimeSession {
        try WebCapsuleConfigValidator.validate(config)
        let archive = try IOSBundleAssetResolver.resolve(
            path: config.bundledAssetPath,
            resourceRootURL: bundleResourceRootURL
        )
        let storage = try IOSRuntimeStorageRoot.prepare(applicationSupportURL: applicationSupportURL)
        let runtime = try IOSRuntimeBootstrap(storageRootURL: storage)
        let session = try runtime.start(
            bundledArchiveURL: archive,
            request: CapsuleVerificationRequest(
                expectedCapsuleId: config.capsuleId,
                runtimeVersion: config.runtimeVersion,
                publicKeys: config.publicKeys
            )
        )
        return IOSPreparedRuntimeSession(storageRootURL: storage, session: session)
    }
}
