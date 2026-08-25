import Foundation

public enum WebCapsuleErrorCode: String, Sendable {
    case invalidArgument = "INVALID_ARGUMENT"
    case invalidJSONValue = "INVALID_JSON_VALUE"
    case duplicateJSONKey = "DUPLICATE_JSON_KEY"
    case invalidManifest = "INVALID_MANIFEST"
    case invalidTimestamp = "INVALID_TIMESTAMP"
    case invalidPolicy = "INVALID_POLICY"
    case invalidSignature = "INVALID_SIGNATURE"
    case invalidOrder = "INVALID_ORDER"
    case unsupportedFormatVersion = "UNSUPPORTED_FORMAT_VERSION"
    case invalidCapsuleID = "INVALID_CAPSULE_ID"
    case invalidKeyID = "INVALID_KEY_ID"
    case invalidVersion = "INVALID_VERSION"
    case invalidHash = "INVALID_HASH"
    case invalidMediaType = "INVALID_MEDIA_TYPE"
    case invalidPath = "INVALID_PATH"
    case duplicatePath = "DUPLICATE_PATH"
    case caseCollision = "CASE_COLLISION"
    case unicodeCollision = "UNICODE_COLLISION"
    case limitExceeded = "LIMIT_EXCEEDED"
    case archiveInvalid = "ARCHIVE_INVALID"
    case invalidArchiveProfile = "INVALID_ARCHIVE_PROFILE"
    case signatureMismatch = "SIGNATURE_MISMATCH"
    case hashMismatch = "HASH_MISMATCH"
    case idMismatch = "ID_MISMATCH"
    case keyIDMismatch = "KEY_ID_MISMATCH"
    case runtimeIncompatible = "RUNTIME_INCOMPATIBLE"
    case invalidPublicKey = "INVALID_PUBLIC_KEY"
    case storageIOFailed = "STORAGE_IO_FAILED"
    case atomicPublishUnsupported = "ATOMIC_PUBLISH_UNSUPPORTED"
    case storageInvariantViolation = "STORAGE_INVARIANT_VIOLATION"
    case unsafeStorageLayout = "UNSAFE_STORAGE_LAYOUT"
    case registryInvalid = "REGISTRY_INVALID"
    case registryRecoveryFailed = "REGISTRY_RECOVERY_FAILED"
    case versionRecordInvalid = "VERSION_RECORD_INVALID"
    case blobMissing = "BLOB_MISSING"
    case installFailed = "INSTALL_FAILED"
    case lockFailed = "LOCK_FAILED"
    case bundledSourceInvalid = "BUNDLED_SOURCE_INVALID"
    case bundledCapsuleUnavailable = "BUNDLED_CAPSULE_UNAVAILABLE"
    case noRunnableVersion = "NO_RUNNABLE_VERSION"
    case sessionMismatch = "SESSION_MISMATCH"
    case resourceDenied = "RESOURCE_DENIED"
    case entryLoadFailed = "ENTRY_LOAD_FAILED"
    case readyMessageInvalid = "READY_MESSAGE_INVALID"
    case readyTimeout = "READY_TIMEOUT"
    case stabilizationFailed = "STABILIZATION_FAILED"
    case trialSessionInProgress = "TRIAL_SESSION_IN_PROGRESS"
    case rollbackTargetUnavailable = "ROLLBACK_TARGET_UNAVAILABLE"
    case rollbackFailed = "ROLLBACK_FAILED"
    case invalidUpdateIndex = "INVALID_UPDATE_INDEX"
    case invalidURL = "INVALID_URL"
    case networkFailed = "NETWORK_FAILED"
    case networkTimeout = "NETWORK_TIMEOUT"
    case httpStatusInvalid = "HTTP_STATUS_INVALID"
    case contentLengthMismatch = "CONTENT_LENGTH_MISMATCH"
    case updateInProgress = "UPDATE_IN_PROGRESS"
    case updateTrialInProgress = "UPDATE_TRIAL_IN_PROGRESS"
    case updateStateChanged = "UPDATE_STATE_CHANGED"
}

public struct WebCapsuleError: Error, Equatable, Sendable, CustomNSError {
    public static let errorDomain = "dev.webcapsule.runtime"

    public let code: WebCapsuleErrorCode
    public let message: String

    public init(code: WebCapsuleErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorCode: Int { 1 }

    public var errorUserInfo: [String: Any] {
        [
            NSLocalizedDescriptionKey: message,
            "WebCapsuleErrorCode": code.rawValue,
        ]
    }
}
